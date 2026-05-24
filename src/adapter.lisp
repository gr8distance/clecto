(in-package #:clecto)

;;; The adapter protocol: a thin set of generic functions that describe
;;; how to dispatch SQL to a particular database. Adapter instances are
;;; just values — any state (a connection) is held as a slot, never as
;;; module-global mutation.

(defclass adapter () ()
  (:documentation "Base class for all DB adapters."))

(defgeneric adapter-execute (adapter sql params)
  (:documentation
   "Execute SQL with positional PARAMS. Return a list of plists (one per row).
PARAMS is a list of values in the order their placeholders appear."))

(defgeneric adapter-execute-returning (adapter sql params)
  (:documentation
   "Execute SQL that mutates and return (values rows-affected last-insert-id).
For RETURNING-style adapters this can be specialized to return rows instead."))

(defvar *lispify-cache* (make-hash-table :test 'equal))
(defvar *lispify-cache-lock* (bordeaux-threads:make-lock "clecto-lispify"))
(defvar *lispify-cache-cap* 4096
  "Maximum entries kept in *lispify-cache*. Past the cap we stop caching
and just compute the keyword each time — bounded memory regardless of
whatever distinct column aliases the DB emits.")

(defun lispify-column (name)
  "DB column name -> keyword: \"user_id\" -> :USER-ID. Cached and bounded
to keep keyword interning under control on hot query paths."
  (let ((s (string name)))
    (bordeaux-threads:with-lock-held (*lispify-cache-lock*)
      (or (gethash s *lispify-cache*)
          (let ((kw (alexandria:make-keyword
                     (string-upcase (substitute #\- #\_ s)))))
            (when (< (hash-table-count *lispify-cache*) *lispify-cache-cap*)
              (setf (gethash s *lispify-cache*) kw))
            kw)))))

(defun sqlify-column (name)
  "Keyword -> DB column name: :user-id -> \"user_id\"."
  (substitute #\_ #\- (string-downcase (string name))))

(defun split-qualified (name)
  "Return (values qualifier base) for :users.id, or (values nil base)."
  (let* ((s (sqlify-column name))
         (dot (position #\. s)))
    (if dot
        (values (subseq s 0 dot) (subseq s (1+ dot)))
        (values nil s))))

(defun identifier-char-p (c)
  (or (alphanumericp c) (char= c #\_)))

(defun identifier-word-match-p (needle haystack)
  "T iff NEEDLE appears in HAYSTACK with non-identifier chars (or string
boundaries) on both sides. Lets us match \"email\" without also
matching it inside \"customer_email\". An empty NEEDLE never matches."
  (when (plusp (length needle))
    (let ((pos (search needle haystack)))
      (when pos
        (and (or (zerop pos)
                 (not (identifier-char-p (char haystack (1- pos)))))
             (let ((end (+ pos (length needle))))
               (or (= end (length haystack))
                   (not (identifier-char-p (char haystack end))))))))))

(defun escape-identifier-body (s)
  "Escape the inside of a double-quoted SQL identifier: \"\"\"\" doubles the
quote, NUL is rejected outright."
  (when (find #\Nul s)
    (error "Identifier contains NUL byte: ~s" s))
  (if (find #\" s)
      (with-output-to-string (out)
        (loop for c across s do
          (if (char= c #\") (write-string "\"\"" out) (write-char c out))))
      s))

(defgeneric adapter-quote-identifier (adapter name)
  (:documentation "Quote a column/table identifier per the dialect.
Handles qualified names like :users.id -> \"users\".\"id\".")
  (:method ((a adapter) name)
    (multiple-value-bind (q c) (split-qualified name)
      (if q (format nil "\"~a\".\"~a\""
                    (escape-identifier-body q)
                    (escape-identifier-body c))
            (format nil "\"~a\"" (escape-identifier-body c))))))

(defgeneric adapter-placeholder (adapter index)
  (:documentation "Render the Nth (1-based) parameter placeholder.")
  (:method ((a adapter) index)
    (declare (ignore index))
    "?"))

(defgeneric adapter-supports-returning-p (adapter)
  (:documentation
   "T if the adapter prefers `INSERT ... RETURNING ...` to recover an
auto-generated PK (and other server-defaulted columns). The repo uses
this to choose between RETURNING and a last-insert-id roundtrip.")
  (:method ((a adapter)) nil))

(defgeneric adapter-begin (adapter)
  (:documentation "Open a transaction. Idempotent across nesting via savepoints."))

(defgeneric adapter-commit (adapter)
  (:documentation "Commit the most recent BEGIN or RELEASE a savepoint."))

(defgeneric adapter-rollback (adapter)
  (:documentation "Roll back the most recent BEGIN or ROLLBACK TO savepoint."))

(define-condition rollback () ()
  (:documentation
   "Signaled to abort a repo-transaction. The transaction body sees no
condition; any returned value is discarded and the txn is rolled back."))

(defparameter *db-error-include-sql* t
  "Controls whether the DB-ERROR default reporter includes the offending
SQL string. Defaults to T (helpful in development; the SQL pinpoints
which query blew up). Set to NIL in production environments where the
SQL string itself is sensitive — table / column names of internal
audit tables, schema layout, etc.

The :sql slot is still preserved on the condition either way — only
the default report's textual output is affected. A custom error
renderer can choose to read DB-ERROR-SQL or not.")

(define-condition db-error (error)
  ((original :initarg :original :reader db-error-original)
   (sql      :initarg :sql      :initform nil :reader db-error-sql))
  (:report (lambda (c stream)
             (format stream "Database error.~@[ SQL: ~a~]"
                     (and *db-error-include-sql* (db-error-sql c)))))
  (:documentation
   "Generic wrapper raised when the underlying adapter signals a DB error
that no declared constraint matched. The original condition is preserved
under DB-ERROR-ORIGINAL — but its (potentially row-leaking) message is
NOT printed by the default reporter, so it stays out of error pages and
logs unless explicitly extracted.

The SQL string that triggered the failure is preserved on DB-ERROR-SQL
and printed by the default reporter when *DB-ERROR-INCLUDE-SQL* is
non-NIL (the development-friendly default). Bind it to NIL in
production to keep table / column names out of generic 500 responses."))

(defgeneric adapter-translate-constraint-error (adapter condition constraints)
  (:documentation
   "Inspect a DB error condition against CONSTRAINTS (a list of CONSTRAINT
records). Return (values field message) when the error matches, or NIL.
The default never matches; each adapter specializes for its dialect.")
  (:method ((a adapter) c constraints)
    (declare (ignore c constraints))
    nil))
