(in-package #:clecto)

;;; Postgres adapter via postmodern + cl-postgres.
;;;
;;; Untested against a live server in CI (no PG available locally), but
;;; written against the documented postmodern API. Integration tests live
;;; alongside the user's app.

(defclass postgres-adapter (adapter)
  ((connection :initarg :connection :reader pg-connection)
   (txn-depth  :initform 0          :accessor pg-txn-depth)
   (conn-lock  :initform (bordeaux-threads:make-recursive-lock
                          "clecto-pg-conn")
               :reader pg-conn-lock)))

(defun make-postgres-adapter (database user password host
                              &key (port 5432) (use-ssl :yes) pooled-p)
  "Connect to a Postgres database via postmodern. POOLED-P uses
postmodern's connection pool keyed by connection spec.

USE-SSL defaults to :YES (require TLS — connection fails if the server
won't negotiate it). This is the fail-secure default: postmodern's
:TRY mode silently falls back to plaintext when a network MITM strips
the TLS upgrade, which would leak credentials and row data over the
wire.

Pass :NO **only** for connections that never leave a trusted boundary
— typically a Unix socket on the same host. Anything that traverses
even a single switch needs :YES."
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

(defun postgres-encode-param (value)
  "Coerce values for cl-postgres bind:
  T       -> \"t\"   (boolean true in text protocol)
  :FALSE  -> \"f\"   (boolean false; distinguishes from NIL/NULL)
  NIL     -> :null   (cl-postgres sentinel for SQL NULL)
  keyword -> downcased name string"
  (cond
    ((eq value t)      "t")
    ((eq value :false) "f")
    ((null value)      :null)
    ((keywordp value)  (string-downcase (symbol-name value)))
    ((symbolp value)   (string-downcase (symbol-name value)))
    (t value)))

(defun pg-row-to-plist (alist)
  (loop for (k . v) in alist
        append (list (lispify-column (string k)) v)))

(defmethod adapter-execute ((a postgres-adapter) sql params)
  (bordeaux-threads:with-recursive-lock-held ((pg-conn-lock a))
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
                   conn sql 'cl-postgres:alist-row-reader))))))

(defmethod adapter-execute-returning ((a postgres-adapter) sql params)
  "PG: execute and return the count of affected rows. No useful last-id
because every PG insert that needs one uses RETURNING via the repo path."
  (bordeaux-threads:with-recursive-lock-held ((pg-conn-lock a))
    (let ((conn (pg-connection a))
          (encoded (mapcar #'postgres-encode-param params)))
      (if encoded
          (cl-postgres:exec-prepared
           conn (cl-postgres:prepare-query conn "" sql) encoded
           'cl-postgres:ignore-row-reader)
          (cl-postgres:exec-query
           conn sql 'cl-postgres:ignore-row-reader)))))

;;; --- transactions ---

(defmethod adapter-begin ((a postgres-adapter))
  (bordeaux-threads:with-recursive-lock-held ((pg-conn-lock a))
    (let ((d (pg-txn-depth a)))
      (if (zerop d)
          (cl-postgres:exec-query (pg-connection a) "BEGIN"
                                  'cl-postgres:ignore-row-reader)
          (cl-postgres:exec-query (pg-connection a)
                                  (format nil "SAVEPOINT sp_~a" d)
                                  'cl-postgres:ignore-row-reader))
      (incf (pg-txn-depth a)))))

(defmethod adapter-commit ((a postgres-adapter))
  (bordeaux-threads:with-recursive-lock-held ((pg-conn-lock a))
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
  (bordeaux-threads:with-recursive-lock-held ((pg-conn-lock a))
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

(defun extract-quoted-name (msg)
  "Return the first double-quoted identifier in MSG, or NIL.
PG always wraps constraint names in double quotes, so we can pull the
exact name out instead of doing a fuzzy substring match that could
accidentally hit a similarly-named constraint."
  (when msg
    (let ((open (position #\" msg)))
      (when open
        (let ((close (position #\" msg :start (1+ open))))
          (when close (subseq msg (1+ open) close)))))))

(defun find-constraint-match (constraints kind condition)
  "Find a matching CONSTRAINT and return (values field message).
Strategy (most specific first):
  1. :name equals the quoted constraint name from the PG error
  2. :column appears as a whole identifier in the message"
  (let* ((msg (and condition (princ-to-string condition)))
         (quoted (extract-quoted-name msg))
         (hit (find-if (lambda (k)
                         (and (eq (constraint-kind k) kind)
                              (or (and (constraint-name k) quoted
                                       (string= (constraint-name k) quoted))
                                  (and (constraint-column k) msg
                                       (identifier-word-match-p
                                        (string-downcase
                                         (sqlify-column (constraint-column k)))
                                        msg)))))
                       constraints)))
    (when hit (values (constraint-field hit) (constraint-message hit)))))

;; identifier-word-match-p and identifier-char-p live in adapter.lisp now.
