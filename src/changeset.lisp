(in-package #:clecto)

;;; Changeset: immutable value that flows through validation plugs.
;;; All operations return a fresh changeset — the data never mutates.

(defstruct changeset
  (schema   nil :type (or null symbol))
  (data     nil :type list)   ; plist: existing record
  (changes  nil :type list)   ; plist: proposed changes
  (errors   nil :type list)   ; alist: ((field . message) ...)
  (valid-p  t   :type boolean))

(defun copy-cs (cs &rest overrides)
  (let ((c (copy-changeset cs)))
    (loop for (slot val) on overrides by #'cddr do
      (ecase slot
        (:schema   (setf (changeset-schema c) val))
        (:data     (setf (changeset-data c) val))
        (:changes  (setf (changeset-changes c) val))
        (:errors   (setf (changeset-errors c) val))
        (:valid-p  (setf (changeset-valid-p c) val))))
    c))

(defun cs-data    (cs) (changeset-data cs))
(defun cs-changes (cs) (changeset-changes cs))
(defun cs-errors  (cs) (changeset-errors cs))
(defun cs-valid-p (cs) (changeset-valid-p cs))
(defun cs-schema  (cs) (changeset-schema cs))

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
                   (type (and f (field-type f))))
              (if type
                  (multiple-value-bind (cast ok) (cast-value value type)
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

(defun validate-length (cs field &key min max (message "has invalid length"))
  (let ((v (get-field cs field)))
    (if (and (stringp v)
             (or (null min) (>= (length v) min))
             (or (null max) (<= (length v) max)))
        cs
        (add-error cs field message))))
