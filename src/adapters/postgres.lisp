(in-package #:clecto)

;;; Postgres adapter via postmodern + cl-postgres.
;;;
;;; Untested against a live server in CI (no PG available locally), but
;;; written against the documented postmodern API. Integration tests live
;;; alongside the user's app.

(defclass postgres-adapter (adapter)
  ((connection :initarg :connection :reader pg-connection)
   (txn-depth  :initform 0          :accessor pg-txn-depth)
   (txn-lock   :initform (bordeaux-threads:make-lock "clecto-pg-txn")
               :reader pg-txn-lock)))

(defun make-postgres-adapter (database user password host
                              &key (port 5432) (use-ssl :no) pooled-p)
  "Connect to a Postgres database via postmodern. POOLED-P uses
postmodern's connection pool keyed by connection spec."
  (make-instance 'postgres-adapter
                 :connection (postmodern:connect database user password host
                                                 :port port
                                                 :use-ssl use-ssl
                                                 :pooled-p pooled-p)))

(defun postgres-close (adapter)
  (postmodern:disconnect (pg-connection adapter)))

(defmethod adapter-placeholder ((a postgres-adapter) index)
  (format nil "$~a" index))

(defmethod adapter-supports-returning-p ((a postgres-adapter)) t)

(defmethod adapter-quote-identifier ((a postgres-adapter) name)
  ;; PG also uses standard ANSI "..."
  (multiple-value-bind (q c) (split-qualified name)
    (if q (format nil "\"~a\".\"~a\""
                  (escape-identifier-body q)
                  (escape-identifier-body c))
          (format nil "\"~a\"" (escape-identifier-body c)))))

(defun postgres-encode-param (value)
  "Coerce values postmodern can't bind directly: keywords -> strings."
  (cond
    ((eq value t)     "t")
    ((null value)     :null)
    ((keywordp value) (string-downcase (symbol-name value)))
    ((symbolp value)  (string-downcase (symbol-name value)))
    (t value)))

(defun pg-row-to-plist (alist)
  (loop for (k . v) in alist
        append (list (lispify-column (string k)) v)))

(defmethod adapter-execute ((a postgres-adapter) sql params)
  (let ((conn (pg-connection a))
        (encoded (mapcar #'postgres-encode-param params)))
    (mapcar #'pg-row-to-plist
            (if encoded
                (cl-postgres:exec-prepared
                 conn
                 (cl-postgres:prepare-query conn "" sql)
                 encoded
                 'cl-postgres:alist-row-reader)
                (cl-postgres:exec-query
                 conn sql 'cl-postgres:alist-row-reader)))))

(defmethod adapter-execute-returning ((a postgres-adapter) sql params)
  "PG: execute and return the count of affected rows. No useful last-id
because every PG insert that needs one uses RETURNING via the repo path."
  (let ((conn (pg-connection a))
        (encoded (mapcar #'postgres-encode-param params)))
    (if encoded
        (cl-postgres:exec-prepared
         conn (cl-postgres:prepare-query conn "" sql) encoded
         'cl-postgres:ignore-row-reader)
        (cl-postgres:exec-query
         conn sql 'cl-postgres:ignore-row-reader))))

(defmethod adapter-last-insert-id ((a postgres-adapter))
  (declare (ignore a))
  (error "Postgres adapter uses RETURNING; last-insert-id is not supported."))

;;; --- transactions ---

(defmethod adapter-begin ((a postgres-adapter))
  (bordeaux-threads:with-lock-held ((pg-txn-lock a))
    (let ((d (pg-txn-depth a)))
      (if (zerop d)
          (cl-postgres:exec-query (pg-connection a) "BEGIN"
                                  'cl-postgres:ignore-row-reader)
          (cl-postgres:exec-query (pg-connection a)
                                  (format nil "SAVEPOINT sp_~a" d)
                                  'cl-postgres:ignore-row-reader))
      (incf (pg-txn-depth a)))))

(defmethod adapter-commit ((a postgres-adapter))
  (bordeaux-threads:with-lock-held ((pg-txn-lock a))
    (when (zerop (pg-txn-depth a))
      (error "adapter-commit: no open transaction"))
    (decf (pg-txn-depth a))
    (if (zerop (pg-txn-depth a))
        (cl-postgres:exec-query (pg-connection a) "COMMIT"
                                'cl-postgres:ignore-row-reader)
        (cl-postgres:exec-query
         (pg-connection a)
         (format nil "RELEASE SAVEPOINT sp_~a" (pg-txn-depth a))
         'cl-postgres:ignore-row-reader))))

(defmethod adapter-rollback ((a postgres-adapter))
  (bordeaux-threads:with-lock-held ((pg-txn-lock a))
    (when (zerop (pg-txn-depth a))
      (error "adapter-rollback: no open transaction"))
    (decf (pg-txn-depth a))
    (if (zerop (pg-txn-depth a))
        (cl-postgres:exec-query (pg-connection a) "ROLLBACK"
                                'cl-postgres:ignore-row-reader)
        (let ((sp (format nil "sp_~a" (pg-txn-depth a))))
          (cl-postgres:exec-query (pg-connection a)
                                  (format nil "ROLLBACK TO SAVEPOINT ~a" sp)
                                  'cl-postgres:ignore-row-reader)
          (cl-postgres:exec-query (pg-connection a)
                                  (format nil "RELEASE SAVEPOINT ~a" sp)
                                  'cl-postgres:ignore-row-reader)))))

;;; --- constraint error translation ---
;;;
;;; PG raises cl-postgres-error:unique-violation, foreign-key-violation,
;;; etc. The constraint name is in the condition. Match against the
;;; declared CONSTRAINT records by :name option (preferred) or :column
;;; (fallback).

(defmethod adapter-translate-constraint-error ((a postgres-adapter) c constraints)
  (typecase c
    (cl-postgres-error:unique-violation
     (find-constraint-match constraints :unique c))
    (cl-postgres-error:foreign-key-violation
     (find-constraint-match constraints :foreign-key c))
    (cl-postgres-error:check-violation
     (find-constraint-match constraints :check c))
    (t nil)))

(defun find-constraint-match (constraints kind condition)
  "Find a matching CONSTRAINT and return (values field message).
PG error messages quote the constraint name (e.g. \"users_email_key\");
we match by explicit :name first, then fall back to column-substring match."
  (let* ((msg (and condition (princ-to-string condition)))
         (hit (find-if (lambda (k)
                         (and (eq (constraint-kind k) kind)
                              (or
                               ;; explicit :name match (preferred)
                               (and (constraint-name k) msg
                                    (search (constraint-name k) msg))
                               ;; column-substring fallback
                               (and (constraint-column k) msg
                                    (search (string-downcase
                                             (string (constraint-column k)))
                                            msg)))))
                       constraints)))
    (when hit (values (constraint-field hit) (constraint-message hit)))))
