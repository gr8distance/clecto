(in-package #:clecto)

;;; Schemas are pure data: a registry mapping name -> schema plist.
;;; No CLOS objects with mutable slots — just describe shape.

(defstruct field
  (name    nil :type keyword)
  (type    nil :type keyword)
  (options nil :type list))   ; plist: :primary-key :default :null ...

(defstruct schema
  (name            nil :type symbol)
  (table           nil :type string)
  (fields          nil :type list)
  (assocs          nil :type list)
  (primary-key     :id :type keyword)
  (timestamps-p    nil :type boolean))

(defstruct association
  (name        nil :type keyword)
  (kind        nil :type keyword)
  (target      nil :type symbol)
  (foreign-key nil :type (or null keyword)))

(defparameter *association-kinds*
  '(:has-many :has-one :belongs-to :embeds-one :embeds-many))

(defun association-spec-p (spec)
  (and (consp spec)
       (consp (rest spec))
       (member (second spec) *association-kinds*)))

(defun timestamps-spec-p (spec)
  (or (eq spec :timestamps)
      (and (consp spec) (eq (first spec) :timestamps))))

(defun field-spec-p (spec)
  (and (consp spec)
       (not (association-spec-p spec))
       (not (timestamps-spec-p spec))))

(defun schema-assoc (schema name)
  (find name (schema-assocs schema) :key #'association-name))

(defvar *schemas* (make-hash-table :test 'eq))

(defun register-schema (schema)
  (setf (gethash (schema-name schema) *schemas*) schema)
  schema)

(defun find-schema (name)
  (or (gethash name *schemas*)
      (error "Unknown schema: ~a" name)))

(defun schema-field (schema field-name)
  (find field-name (schema-fields schema) :key #'field-name))

(defmacro defschema (name table &body specs)
  "Define a schema:

  (defschema user \"users\"
    (:id    :integer :primary-key t)         ; field
    (:email :string)                          ; field
    (:posts :has-many post :foreign-key :user-id)  ; association
    (:timestamps))                            ; auto inserted-at/updated-at

Field types: :integer :float :string :boolean :utc-datetime :naive-datetime
             :date :decimal :binary-id
Association kinds: :has-many :has-one :belongs-to"
  (let* ((field-specs (remove-if-not #'field-spec-p specs))
         (assoc-specs (remove-if-not #'association-spec-p specs))
         (timestamps-p (some #'timestamps-spec-p specs))
         (effective-fields
           (if timestamps-p
               (append field-specs
                       '((:inserted-at :naive-datetime)
                         (:updated-at  :naive-datetime)))
               field-specs))
         (fields (mapcar (lambda (s)
                           `(make-field :name ,(first s)
                                        :type ,(second s)
                                        :options (list ,@(cddr s))))
                         effective-fields))
         (assocs (mapcar (lambda (s)
                           `(make-association
                             :name ,(first s)
                             :kind ,(second s)
                             :target ',(third s)
                             :foreign-key ,(getf (cdddr s) :foreign-key)))
                         assoc-specs)))
    `(register-schema
      (make-schema
       :name ',name
       :table ,table
       :fields (list ,@fields)
       :assocs (list ,@assocs)
       :timestamps-p ,timestamps-p
       :primary-key
       (or ,(some (lambda (s)
                    (when (getf (cddr s) :primary-key)
                      (first s)))
                  field-specs)
           :id)))))

;;; --- type casting ---

(defun now-naive-datetime ()
  "Current LOCAL time as 'YYYY-MM-DD HH:MM:SS' (no timezone). Matches
Ecto's :naive_datetime convention; pair with :inserted-at/:updated-at."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d" y mo d h m s)))

(defun now-utc-datetime ()
  "Current UTC time as 'YYYY-MM-DD HH:MM:SSZ'. Use this for :utc-datetime
fields and any cross-system audit timestamps."
  (multiple-value-bind (s m h d mo y)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0dZ" y mo d h m s)))

(define-condition secure-random-unavailable (error)
  ((reason :initarg :reason :reader secure-random-reason))
  (:report (lambda (c stream)
             (format stream
                     "OS CSPRNG (/dev/urandom) is unavailable: ~a.~@
                      generate-uuid and generate-secure-token require ~
                      a working CSPRNG; do NOT fall back to anything else."
                     (secure-random-reason c)))))

(defun read-secure-bytes (n)
  "Read N bytes from the OS CSPRNG (/dev/urandom). Signals
SECURE-RANDOM-UNAVAILABLE if the device can't be opened — do NOT catch
this and silently fall back to a PRNG."
  (handler-case
      (with-open-file (s "/dev/urandom"
                         :direction :input
                         :element-type '(unsigned-byte 8)
                         :if-does-not-exist :error)
        (loop repeat n collect (read-byte s)))
    (file-error (e) (error 'secure-random-unavailable :reason e))
    (stream-error (e) (error 'secure-random-unavailable :reason e))))

(defun generate-uuid ()
  "RFC 4122 v4 UUID. Bytes come from the OS CSPRNG so the result is safe
for session tokens, password-reset links, and other security-sensitive
identifiers."
  (let ((b (read-secure-bytes 16)))
    (setf (nth 6 b) (logior #x40 (logand (nth 6 b) #x0f)))  ; version 4
    (setf (nth 8 b) (logior #x80 (logand (nth 8 b) #x3f)))  ; variant 1
    (format nil "~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}"
            (subseq b 0 4) (subseq b 4 6) (subseq b 6 8)
            (subseq b 8 10) (subseq b 10 16))))

(defun generate-secure-token (&key (byte-length 32))
  "Random URL-safe-ish hex token from the OS CSPRNG. Default 32 bytes
(256 bits). Use for session IDs, CSRF tokens, password-reset codes."
  (format nil "~{~2,'0x~}" (read-secure-bytes byte-length)))

(defun field-virtual-p (field)
  (getf (field-options field) :virtual))

(defparameter *numeric-string-cap* 64
  "Maximum length of a string accepted by SAFE-PARSE-NUMBER /
SAFE-PARSE-RATIONAL / :integer casting. Caps the cost of an attacker
sending megabyte-long digit strings that would build huge bignums.")

(defparameter *numeric-exponent-cap* 1000
  "Maximum |exponent| accepted in scientific notation. (expt 10 1000) is
already a very large bignum; anything beyond is a DoS in disguise.")

(defun safe-parse-number (s)
  "Parse a base-10 numeric literal directly from S without invoking the
Lisp reader. Accepts integers, decimals, and scientific notation. Returns
(values number ok-p)."
  (let* ((s (string-trim '(#\Space #\Tab) s))
         (len (length s)))
    (when (or (zerop len) (> len *numeric-string-cap*))
      (return-from safe-parse-number (values nil nil)))
    (block out
      (let ((i 0) (sign 1) (int 0) (frac 0) (frac-div 1)
            (exp 0) (exp-sign 1)
            (saw-int nil) (saw-frac nil) (saw-e nil))
        (when (or (char= (char s 0) #\+) (char= (char s 0) #\-))
          (when (char= (char s 0) #\-) (setf sign -1))
          (incf i))
        (loop while (and (< i len) (digit-char-p (char s i))) do
          (setf int (+ (* int 10) (digit-char-p (char s i)))
                saw-int t)
          (incf i))
        (when (and (< i len) (char= (char s i) #\.))
          (incf i)
          (loop while (and (< i len) (digit-char-p (char s i))) do
            (setf frac (+ (* frac 10) (digit-char-p (char s i)))
                  frac-div (* frac-div 10)
                  saw-frac t)
            (incf i)))
        (unless (or saw-int saw-frac) (return-from out (values nil nil)))
        (when (and (< i len) (or (char= (char s i) #\e) (char= (char s i) #\E)))
          (setf saw-e t)
          (incf i)
          (when (and (< i len) (or (char= (char s i) #\+) (char= (char s i) #\-)))
            (when (char= (char s i) #\-) (setf exp-sign -1))
            (incf i))
          (let ((saw-exp-digit nil))
            (loop while (and (< i len) (digit-char-p (char s i))) do
              (setf exp (+ (* exp 10) (digit-char-p (char s i)))
                    saw-exp-digit t)
              (incf i))
            (unless saw-exp-digit (return-from out (values nil nil)))))
        (unless (= i len) (return-from out (values nil nil)))
        (when (> exp *numeric-exponent-cap*)
          (return-from out (values nil nil)))
        (let ((mag (+ int (/ frac frac-div))))
          (when (= exp-sign -1) (setf exp (- exp)))
          (setf mag (* sign mag (expt 10 exp)))
          (cond
            ((or saw-frac saw-e) (values (coerce mag 'double-float) t))
            (t (values mag t))))))))

(defun safe-parse-rational (s)
  "Like SAFE-PARSE-NUMBER but also accepts \"n/m\" rationals."
  (let ((slash (position #\/ s)))
    (if slash
        (multiple-value-bind (num ok1) (safe-parse-number (subseq s 0 slash))
          (multiple-value-bind (den ok2) (safe-parse-number (subseq s (1+ slash)))
            (if (and ok1 ok2 (not (zerop den)))
                (values (/ num den) t)
                (values nil nil))))
        (safe-parse-number s))))

(defun cast-value (value type &optional options)
  "Coerce VALUE to TYPE. Return (values cast-value ok-p)."
  (when (null value) (return-from cast-value (values nil t)))
  (case type
    (:integer
     (typecase value
       (integer (values value t))
       (string
        (if (> (length value) *numeric-string-cap*)
            (values nil nil)
            (let ((n (ignore-errors (parse-integer value :junk-allowed nil))))
              (if n (values n t) (values nil nil)))))
       (t (values nil nil))))
    (:float
     (typecase value
       (number (values (coerce value 'double-float) t))
       (string (multiple-value-bind (n ok) (safe-parse-number value)
                 (if ok (values (coerce n 'double-float) t) (values nil nil))))
       (t (values nil nil))))
    (:decimal
     (typecase value
       (rational (values value t))
       (number   (values value t))
       (string   (safe-parse-rational value))
       (t (values nil nil))))
    (:string
     (typecase value
       (string (values value t))
       (t      (values (princ-to-string value) t))))
    (:boolean
     ;; Cast keeps boolean values as plain T/NIL — the :FALSE sentinel
     ;; needed by adapters is only introduced later in PREPARE-ROW, where
     ;; we have field-type context.
     (cond ((member value '(t :true "true" "t" 1) :test #'equal) (values t t))
           ((member value '(nil :false "false" "f" 0) :test #'equal)
            (values nil t))
           (t (values nil nil))))
    ((:utc-datetime :naive-datetime :date :binary-id)
     (typecase value
       (string (values value t))
       (t      (values nil nil))))
    (:enum
     (let ((allowed (getf options :values)))
       (cond
         ((null allowed) (values value t))
         ((member value allowed :test #'equal) (values value t))
         ((stringp value)
          (let ((hit (find-if (lambda (a) (string-equal value (string a)))
                              allowed)))
            (if hit (values hit t) (values nil nil))))
         (t (values nil nil)))))
    (t (values value t))))
