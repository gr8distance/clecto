(in-package #:clecto)

;;; SQLite adapter via cl-sqlite.

(defclass sqlite-adapter (adapter)
  ((db   :initarg :db   :reader sqlite-db)
   (path :initarg :path :reader sqlite-path)))

(defun make-sqlite-adapter (path)
  "Open a SQLite database at PATH (\":memory:\" works)."
  (make-instance 'sqlite-adapter
                 :path path
                 :db (sqlite:connect path)))

(defun sqlite-close (adapter)
  (sqlite:disconnect (sqlite-db adapter)))

(defmethod adapter-quote-identifier ((a sqlite-adapter) name)
  (format nil "\"~a\"" (string-downcase (string name))))

(defmethod adapter-placeholder ((a sqlite-adapter) index)
  (declare (ignore index))
  "?")

(defmethod adapter-last-insert-id ((a sqlite-adapter))
  (sqlite:last-insert-rowid (sqlite-db a)))

(defmethod adapter-execute ((a sqlite-adapter) sql params)
  "Run SQL and return rows as plists keyed by lowercased-keyword column names."
  (let* ((db (sqlite-db a))
         (stmt (sqlite:prepare-statement db sql)))
    (unwind-protect
         (progn
           (loop for p in params for i from 1
                 do (sqlite:bind-parameter stmt i p))
           (let* ((names (sqlite:statement-column-names stmt))
                  (keys (mapcar (lambda (n)
                                  (alexandria:make-keyword (string-upcase n)))
                                names)))
             (loop while (sqlite:step-statement stmt)
                   collect (loop for k in keys for i from 0
                                 append (list k (sqlite:statement-column-value stmt i))))))
      (sqlite:finalize-statement stmt))))

(defmethod adapter-execute-returning ((a sqlite-adapter) sql params)
  "Execute a mutating statement. Returns (values changes last-insert-id)."
  (apply #'sqlite:execute-non-query (sqlite-db a) sql params)
  (values (sqlite:execute-single (sqlite-db a) "SELECT changes()")
          (sqlite:last-insert-rowid (sqlite-db a))))
