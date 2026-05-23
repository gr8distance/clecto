(in-package #:clecto)

;;; Schemas are pure data: a registry mapping name -> schema plist.
;;; No CLOS objects with mutable slots — just describe shape.

(defstruct field
  (name    nil :type keyword)
  (type    nil :type keyword)   ; :integer :string :float :boolean :utc-datetime
  (options nil :type list))     ; plist: :primary-key :default :null ...

(defstruct schema
  (name         nil :type symbol)
  (table        nil :type string)
  (fields       nil :type list)    ; list of FIELD
  (assocs       nil :type list)    ; list of ASSOC
  (primary-key  :id :type keyword))

(defstruct association
  (name        nil :type keyword)
  (kind        nil :type keyword)   ; :has-many :has-one :belongs-to
  (target      nil :type symbol)    ; target schema name
  (foreign-key nil :type keyword))

(defparameter *association-kinds* '(:has-many :has-one :belongs-to))

(defun association-spec-p (spec)
  (and (consp spec)
       (consp (rest spec))
       (member (second spec) *association-kinds*)))

(defun schema-assoc (schema name)
  (find name (schema-assocs schema) :key #'association-name))

(defvar *schemas* (make-hash-table :test 'eq)
  "Global registry of schemas keyed by name symbol.")

(defun register-schema (schema)
  (setf (gethash (schema-name schema) *schemas*) schema)
  schema)

(defun find-schema (name)
  (or (gethash name *schemas*)
      (error "Unknown schema: ~a" name)))

(defun schema-field (schema field-name)
  (find field-name (schema-fields schema) :key #'field-name))

(defun parse-field-spec (spec)
  "Spec form: (NAME TYPE &rest OPTIONS).
e.g. (:email :string :required t)"
  (destructuring-bind (name type &rest options) spec
    (make-field :name name :type type :options options)))

(defmacro defschema (name table &body specs)
  "Define a schema. Each spec is either a field or an association:

  (defschema user \"users\"
    (:id    :integer :primary-key t)         ; field
    (:email :string)                          ; field
    (:posts :has-many post :foreign-key :user-id))   ; association

Supported association kinds: :has-many, :has-one, :belongs-to."
  (let* ((field-specs (remove-if #'association-spec-p specs))
         (assoc-specs (remove-if-not #'association-spec-p specs))
         (fields (mapcar (lambda (s)
                           `(make-field :name ,(first s)
                                        :type ,(second s)
                                        :options (list ,@(cddr s))))
                         field-specs))
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
       :primary-key
       (or ,(some (lambda (s)
                    (when (getf (cddr s) :primary-key)
                      (first s)))
                  field-specs)
           :id)))))

;;; --- type casting ---

(defun cast-value (value type)
  "Coerce VALUE to TYPE. Return (values cast-value ok-p).
String inputs (e.g. from form params) are parsed."
  (cond
    ((null value) (values nil t))
    ((eq type :integer)
     (typecase value
       (integer (values value t))
       (string  (let ((n (ignore-errors (parse-integer value :junk-allowed nil))))
                  (if n (values n t) (values nil nil))))
       (t (values nil nil))))
    ((eq type :float)
     (typecase value
       (number (values (coerce value 'double-float) t))
       (string (let ((n (ignore-errors (read-from-string value))))
                 (if (numberp n) (values (coerce n 'double-float) t) (values nil nil))))
       (t (values nil nil))))
    ((eq type :string)
     (typecase value
       (string (values value t))
       (t      (values (princ-to-string value) t))))
    ((eq type :boolean)
     (cond ((member value '(t :true "true" "t" 1) :test #'equal) (values t t))
           ((member value '(nil :false "false" "f" 0) :test #'equal) (values nil t))
           (t (values nil nil))))
    ((eq type :utc-datetime)
     (typecase value
       (string (values value t))   ; store as ISO string; richer support later
       (t      (values nil nil))))
    (t (values value t))))
