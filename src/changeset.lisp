(in-package #:clecto)

;;; Changeset: immutable value that flows through validation plugs.
;;; All operations return a fresh changeset — the data never mutates.

(defstruct (changeset
            (:conc-name cs-)
            (:predicate changeset-p))
  (schema      nil :type (or null symbol))
  (data        nil :type list)
  (changes     nil :type list)
  (errors      nil :type list)
  (constraints nil :type list)
  (action      nil :type symbol) ; nil, :insert, :update, :delete, :ignore
  (valid-p     t   :type boolean))

(defstruct constraint
  (kind    nil :type keyword)   ; :unique :foreign-key :check
  (column  nil)                 ; column name for matching (string or keyword)
  (name    nil)                 ; DB-side constraint name (PG / explicit)
  (field   nil :type keyword)   ; cs field to attach the error to
  (message nil :type string))

(define-copier copy-cs
  :copier copy-changeset
  :accessor-prefix cs-
  :slots (schema data changes errors constraints action valid-p))

(defun cast (data-or-schema attrs allowed)
  "Begin a changeset. DATA-OR-SCHEMA is either a schema symbol (insert)
or a plist of existing data (update). ATTRS is a plist of incoming values.
ALLOWED is a list of field keywords to accept."
  (multiple-value-bind (schema-name data)
      (etypecase data-or-schema
        (symbol (values data-or-schema nil))
        (cons   (values (getf data-or-schema :__schema__) data-or-schema)))
    (let ((schema (and schema-name (find-schema schema-name)))
          (changes nil)
          (errors nil))
      (dolist (field allowed)
        (multiple-value-bind (present-p value)
            (plist-has attrs field)
          (when present-p
            (let* ((f (and schema (schema-field schema field)))
                   (type (and f (field-type f)))
                   (opts (and f (field-options f))))
              (if type
                  (multiple-value-bind (cast ok) (cast-value value type opts)
                    (if ok
                        (setf changes (list* field cast changes))
                        (push (cons field (format nil "is invalid")) errors)))
                  (setf changes (list* field value changes)))))))
      (make-changeset :schema schema-name
                      :data data
                      :changes changes
                      :errors errors
                      :valid-p (null errors)))))

(defun plist-has (plist key)
  "Return (values present-p value)."
  (loop for (k v) on plist by #'cddr
        when (eq k key) do (return (values t v))
          finally (return (values nil nil))))

(defun put-change (cs field value)
  (copy-cs cs :changes (list* field value
                              (alexandria:remove-from-plist (cs-changes cs) field))))

(defun get-change (cs field &optional default)
  (multiple-value-bind (p v) (plist-has (cs-changes cs) field)
    (if p v default)))

(defun get-field (cs field &optional default)
  "Effective value: change overrides data."
  (multiple-value-bind (p v) (plist-has (cs-changes cs) field)
    (if p v (getf (cs-data cs) field default))))

(defun cast-embed (cs field attrs cast-fn)
  "Cast a nested attribute under FIELD using CAST-FN. CAST-FN is called as
\(cast-fn child-attrs) -> changeset. For :embeds-many, ATTRS[FIELD] should
be a list of plists. The resulting child changeset (or list of them) is
attached to CS under FIELD."
  (let* ((schema (and (cs-schema cs) (find-schema (cs-schema cs))))
         (a      (and schema (schema-assoc schema field)))
         (kind   (and a (association-kind a)))
         (input  (getf attrs field))
         (child  (case kind
                   (:embeds-one  (funcall cast-fn input))
                   (:embeds-many (mapcar cast-fn input))
                   (t (error "cast-embed: ~a is not an embed on ~a"
                             field (cs-schema cs)))))
         (cs2    (put-change cs field child))
         (bad    (case kind
                   (:embeds-one  (not (cs-valid-p child)))
                   (:embeds-many (some (lambda (c) (not (cs-valid-p c))) child)))))
    (if bad
        (add-error cs2 field "has invalid children")
        cs2)))

(defun cast-assoc (cs field attrs cast-fn)
  "Like CAST-EMBED but for has-many/has-one/belongs-to associations.
Stores child changesets on CS; the repo does NOT auto-persist them in v0.2."
  (let* ((schema (and (cs-schema cs) (find-schema (cs-schema cs))))
         (a      (and schema (schema-assoc schema field)))
         (kind   (and a (association-kind a)))
         (input  (getf attrs field))
         (child  (case kind
                   ((:has-one :belongs-to) (funcall cast-fn input))
                   (:has-many              (mapcar cast-fn input))
                   (t (error "cast-assoc: ~a is not a row assoc on ~a"
                             field (cs-schema cs)))))
         (cs2    (put-change cs field child))
         (bad    (case kind
                   ((:has-one :belongs-to) (not (cs-valid-p child)))
                   (:has-many (some (lambda (c) (not (cs-valid-p c))) child)))))
    (if bad
        (add-error cs2 field "has invalid children")
        cs2)))

(defun add-error (cs field message)
  (copy-cs cs
           :errors (cons (cons field message) (cs-errors cs))
           :valid-p nil))

(defun apply-changes (cs)
  "Merge changes into data and return the resulting plist (for inserts/updates).
Does not consult valid-p; caller decides."
  (let ((out (copy-list (cs-data cs))))
    (loop for (k v) on (cs-changes cs) by #'cddr do
      (setf (getf out k) v))
    out))

;;; --- validators (all are (cs ...) -> cs) ---

(defun validate-required (cs fields)
  (reduce (lambda (acc f)
            (let ((v (get-field acc f)))
              (if (or (null v) (equal v ""))
                  (add-error acc f "can't be blank")
                  acc)))
          fields
          :initial-value cs))

(defun validate-format (cs field substring &key (message "has invalid format"))
  "Crude format check: SUBSTRING must appear in the field value.
Sufficient for email-ish '@' checks without pulling in a regex lib."
  (let ((v (get-field cs field)))
    (if (and (stringp v) (search substring v))
        cs
        (add-error cs field message))))

(defun validate-number (cs field &key < <= > >= = (message "is out of range"))
  (let ((v (get-field cs field)))
    (if (and (numberp v)
             (or (null <)  (cl:<  v <))
             (or (null <=) (cl:<= v <=))
             (or (null >)  (cl:>  v >))
             (or (null >=) (cl:>= v >=))
             (or (null =)  (cl:=  v =)))
        cs
        (add-error cs field message))))

(defun traverse-errors (cs &optional (fn (lambda (field msg)
                                           (declare (ignore field))
                                           msg)))
  "Walk CS errors and return an alist keyed by field, each value a list of
mapped messages. FN is (field message) -> mapped-value."
  (let ((grouped (make-hash-table :test 'eq))
        (order nil))
    (dolist (pair (cs-errors cs))
      (let ((field (car pair))
            (msg   (cdr pair)))
        (unless (gethash field grouped) (push field order))
        (push (funcall fn field msg) (gethash field grouped))))
    (mapcar (lambda (field) (cons field (nreverse (gethash field grouped))))
            (nreverse order))))

(defun apply-action (cs action)
  "If CS is valid, return (values data nil). Otherwise tag CS with ACTION
and return (values nil cs). Mirrors Ecto.Changeset.apply_action/2.
ACTION is typically :insert, :update, or :delete."
  (if (cs-valid-p cs)
      (values (apply-changes cs) nil)
      (values nil (copy-cs cs :action action))))

(defun unique-constraint (cs field
                          &key (message "has already been taken") column name)
  "Declare that a UNIQUE violation on COLUMN (defaults to FIELD) should
appear as an error on FIELD when the next repo-insert/update fails.
NAME is the DB-side constraint name (e.g. \"users_email_key\"); useful
when the column name doesn't match the index name."
  (copy-cs cs
           :constraints
           (cons (make-constraint :kind :unique
                                  :column (or column field)
                                  :name name
                                  :field field
                                  :message message)
                 (cs-constraints cs))))

(defun foreign-key-constraint (cs field
                               &key (message "does not exist") name)
  (copy-cs cs
           :constraints
           (cons (make-constraint :kind :foreign-key
                                  :name name
                                  :field field
                                  :message message)
                 (cs-constraints cs))))

(defun check-constraint (cs field
                         &key (message "is invalid") name)
  "DB-level CHECK constraints (PG)."
  (copy-cs cs
           :constraints
           (cons (make-constraint :kind :check
                                  :name name
                                  :field field
                                  :message message)
                 (cs-constraints cs))))

(defun validate-inclusion (cs field allowed &key (message "is not included in the list"))
  (let ((v (get-field cs field)))
    (if (member v allowed :test #'equal) cs (add-error cs field message))))

(defun validate-exclusion (cs field disallowed &key (message "is reserved"))
  (let ((v (get-field cs field)))
    (if (member v disallowed :test #'equal) (add-error cs field message) cs)))

(defun validate-subset (cs field allowed &key (message "has an unsupported value"))
  (let ((v (get-field cs field)))
    (if (and (listp v) (every (lambda (x) (member x allowed :test #'equal)) v))
        cs
        (add-error cs field message))))

(defun validate-confirmation (cs field &key (message "does not match"))
  "Check that :<field>-confirmation equals :<field> in the changes."
  (let* ((confirm-key (alexandria:make-keyword
                       (concatenate 'string (symbol-name field) "-CONFIRMATION")))
         (a (get-field cs field))
         (b (get-change cs confirm-key)))
    (if (equal a b) cs (add-error cs confirm-key message))))

(defun validate-acceptance (cs field &key (message "must be accepted"))
  "Useful for 'I accept the terms' checkboxes."
  (if (get-field cs field) cs (add-error cs field message)))

(defun validate-length (cs field &key min max (message "has invalid length"))
  (let ((v (get-field cs field)))
    (if (and (stringp v)
             (or (null min) (>= (length v) min))
             (or (null max) (<= (length v) max)))
        cs
        (add-error cs field message))))
