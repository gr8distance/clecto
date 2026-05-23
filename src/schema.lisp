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
  (foreign-key nil :type keyword))

(defparameter *association-kinds* '(:has-many :has-one :belongs-to))

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
  "Current local time as 'YYYY-MM-DD HH:MM:SS'."
  (multiple-value-bind (s m h d mo y) (decode-universal-time (get-universal-time))
    (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d" y mo d h m s)))

(defun generate-uuid ()
  "RFC 4122 v4-ish UUID using SBCL's RNG. Not cryptographic-grade."
  (flet ((rb () (random 256)))
    (let ((b (loop repeat 16 collect (rb))))
      ;; set version 4 and variant bits
      (setf (nth 6 b) (logior #x40 (logand (nth 6 b) #x0f)))
      (setf (nth 8 b) (logior #x80 (logand (nth 8 b) #x3f)))
      (format nil "~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}-~{~2,'0x~}"
              (subseq b 0 4) (subseq b 4 6) (subseq b 6 8)
              (subseq b 8 10) (subseq b 10 16)))))

(defun cast-value (value type)
  "Coerce VALUE to TYPE. Return (values cast-value ok-p)."
  (cond
    ((null value) (values nil t))
    ((eq type :integer)
     (typecase value
       (integer (values value t))
       (string (let ((n (ignore-errors (parse-integer value :junk-allowed nil))))
                 (if n (values n t) (values nil nil))))
       (t (values nil nil))))
    ((eq type :float)
     (typecase value
       (number (values (coerce value 'double-float) t))
       (string (let ((n (ignore-errors (read-from-string value))))
                 (if (numberp n) (values (coerce n 'double-float) t) (values nil nil))))
       (t (values nil nil))))
    ((eq type :decimal)
     ;; Decimal: keep precise representation as string OR rational.
     ;; Accept either form; defer formatting to the adapter.
     (typecase value
       (rational (values value t))
       (number   (values value t))
       (string   (let ((n (ignore-errors (read-from-string value))))
                   (if (numberp n) (values n t) (values nil nil))))
       (t (values nil nil))))
    ((eq type :string)
     (typecase value
       (string (values value t))
       (t      (values (princ-to-string value) t))))
    ((eq type :boolean)
     (cond ((member value '(t :true "true" "t" 1) :test #'equal) (values t t))
           ((member value '(nil :false "false" "f" 0) :test #'equal) (values nil t))
           (t (values nil nil))))
    ((or (eq type :utc-datetime)
         (eq type :naive-datetime)
         (eq type :date)
         (eq type :binary-id))
     ;; Stored as text in the DB. Lightweight pass-through.
     (typecase value
       (string (values value t))
       (t      (values nil nil))))
    (t (values value t))))
