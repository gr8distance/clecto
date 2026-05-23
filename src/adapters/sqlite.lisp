(in-package #:clecto)

;;; SQLite adapter via cl-sqlite.

(defclass sqlite-adapter (adapter)
  ((db        :initarg :db   :reader sqlite-db)
   (path      :initarg :path :reader sqlite-path)
   (txn-depth :initform 0    :accessor sqlite-txn-depth)
   (conn-lock :initform (bordeaux-threads:make-recursive-lock
                         "clecto-sqlite-conn")
              :reader sqlite-conn-lock
              :documentation
              "Recursive lock around every connection-touching method.
Allows nested transactions on the same thread; serializes access from
different threads so prepare/step/finalize don't interleave.")))

(defun make-sqlite-adapter (path)
  "Open a SQLite database at PATH (\":memory:\" works)."
  (make-instance 'sqlite-adapter
                 :path path
                 :db (sqlite:connect path)))

(defun sqlite-close (adapter)
  (sqlite:disconnect (sqlite-db adapter)))

(defmethod adapter-quote-identifier ((a sqlite-adapter) name)
  (multiple-value-bind (q c) (split-qualified name)
    (if q (format nil "\"~a\".\"~a\""
                  (escape-identifier-body q)
                  (escape-identifier-body c))
          (format nil "\"~a\"" (escape-identifier-body c)))))

(defmethod adapter-placeholder ((a sqlite-adapter) index)
  (declare (ignore index))
  "?")

(defmethod adapter-last-insert-id ((a sqlite-adapter))
  (sqlite:last-insert-rowid (sqlite-db a)))

(defmethod adapter-translate-constraint-error ((a sqlite-adapter) c constraints)
  (let ((msg (if (typep c 'sqlite:sqlite-error)
                 (princ-to-string (sqlite:sqlite-error-message c))
                 (princ-to-string c))))
    (cond
      ((search "UNIQUE constraint failed" msg)
       (let ((column (sqlite-parse-unique-column msg)))
         (let ((hit (find-if (lambda (k)
                               (and (eq (constraint-kind k) :unique)
                                    (or (null column)
                                        (string= (sqlify-column
                                                  (constraint-column k))
                                                 column))))
                             constraints)))
           (when hit (values (constraint-field hit)
                             (constraint-message hit))))))
      ((search "FOREIGN KEY constraint failed" msg)
       (let ((hit (find :foreign-key constraints :key #'constraint-kind)))
         (when hit (values (constraint-field hit)
                           (constraint-message hit))))))))

(defun sqlite-parse-unique-column (msg)
  "Pull the column name from 'UNIQUE constraint failed: users.email'."
  (let ((pos (search "failed: " msg)))
    (when pos
      (let* ((rest (subseq msg (+ pos (length "failed: "))))
             (dot  (position #\. rest))
             (end  (or (position #\, rest) (length rest))))
        (when dot (subseq rest (1+ dot) end))))))

(defmethod adapter-execute ((a sqlite-adapter) sql params)
  "Run SQL and return rows as plists keyed by lowercased-keyword column names."
  (bordeaux-threads:with-recursive-lock-held ((sqlite-conn-lock a))
    (let* ((db (sqlite-db a))
           (stmt (sqlite:prepare-statement db sql)))
      (unwind-protect
           (progn
             (loop for p in params for i from 1
                   do (sqlite:bind-parameter stmt i (sqlite-encode-param p)))
             (let* ((names (sqlite:statement-column-names stmt))
                    (keys (mapcar #'lispify-column names)))
               (loop while (sqlite:step-statement stmt)
                     collect (loop for k in keys for i from 0
                                   append (list k (sqlite:statement-column-value stmt i))))))
        (sqlite:finalize-statement stmt)))))

(defmethod adapter-begin ((a sqlite-adapter))
  (bordeaux-threads:with-recursive-lock-held ((sqlite-conn-lock a))
    (let ((d (sqlite-txn-depth a)))
      (if (zerop d)
          (sqlite:execute-non-query (sqlite-db a) "BEGIN")
          (sqlite:execute-non-query (sqlite-db a)
                                    (format nil "SAVEPOINT sp_~a" d)))
      (incf (sqlite-txn-depth a)))))

(defmethod adapter-commit ((a sqlite-adapter))
  (bordeaux-threads:with-recursive-lock-held ((sqlite-conn-lock a))
    (when (zerop (sqlite-txn-depth a))
      (error "adapter-commit: no open transaction"))
    (decf (sqlite-txn-depth a))
    (if (zerop (sqlite-txn-depth a))
        (sqlite:execute-non-query (sqlite-db a) "COMMIT")
        (sqlite:execute-non-query
         (sqlite-db a)
         (format nil "RELEASE SAVEPOINT sp_~a" (sqlite-txn-depth a))))))

(defmethod adapter-rollback ((a sqlite-adapter))
  (bordeaux-threads:with-recursive-lock-held ((sqlite-conn-lock a))
    (when (zerop (sqlite-txn-depth a))
      (error "adapter-rollback: no open transaction"))
    (decf (sqlite-txn-depth a))
    (if (zerop (sqlite-txn-depth a))
        (sqlite:execute-non-query (sqlite-db a) "ROLLBACK")
        (let ((sp (format nil "sp_~a" (sqlite-txn-depth a))))
          (sqlite:execute-non-query (sqlite-db a) (format nil "ROLLBACK TO SAVEPOINT ~a" sp))
          (sqlite:execute-non-query (sqlite-db a) (format nil "RELEASE SAVEPOINT ~a" sp))))))

(defmethod adapter-execute-returning ((a sqlite-adapter) sql params)
  "Execute a mutating statement. Returns (values changes last-insert-id)."
  (bordeaux-threads:with-recursive-lock-held ((sqlite-conn-lock a))
    (apply #'sqlite:execute-non-query (sqlite-db a) sql
           (mapcar #'sqlite-encode-param params))
    (values (sqlite:execute-single (sqlite-db a) "SELECT changes()")
            (sqlite:last-insert-rowid (sqlite-db a)))))

(defun sqlite-encode-param (value)
  "Coerce values SQLite can't natively bind:
  T       -> 1
  :FALSE  -> 0  (explicit boolean false; NIL still becomes SQL NULL)
  keyword -> downcased string (enum values, etc.)"
  (cond
    ((eq value t)      1)
    ((eq value :false) 0)
    ((null value)      nil)        ; SQL NULL
    ((keywordp value)  (string-downcase (symbol-name value)))
    ((symbolp value)   (string-downcase (symbol-name value)))
    (t value)))
