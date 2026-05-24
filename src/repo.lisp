(in-package #:clecto)

;;; Repo: the side-effect boundary. Holds an adapter; delegates to it.

(defstruct (repo (:constructor %make-repo))
  (adapter nil :type adapter))

(defun make-repo (adapter)
  "Wrap ADAPTER in a repo. The repo is the only API surface that touches I/O."
  (%make-repo :adapter adapter))

;;; --- SELECTs ---

(defun repo-all (repo query)
  "Run QUERY, return all rows as plists."
  (let ((adapter (repo-adapter repo)))
    (multiple-value-bind (sql params) (select-sql adapter query)
      (with-telemetry (adapter sql params)
        (adapter-execute adapter sql params)))))

(defun repo-one (repo query)
  "Return the first row (or NIL). LIMIT 1 is applied if not set."
  (let ((q (if (query-limit query) query (limit query 1))))
    (first (repo-all repo q))))

(defun repo-get (repo schema-name id)
  "Fetch by primary key."
  (let* ((schema (find-schema schema-name))
         (pk     (schema-primary-key schema)))
    (repo-one repo
              (where (from (intern-table schema)) (list '= pk id)))))

(defun repo-get-by (repo schema-name filters &key allowed-keys)
  "Fetch the first row of SCHEMA-NAME matching FILTERS (a plist of
field/value pairs).

FILTERS keys are gated against the schema's declared fields before
being compiled into a WHERE clause. Any key that isn't a declared
field signals an error — a defense against mass-assignment-style
bugs where an attacker-controlled plist (e.g. raw HTTP query params)
gets threaded into the filter map and is used to probe arbitrary
columns like :password-hash.

Pass ALLOWED-KEYS to narrow further: a caller-supplied list of
field keywords that the filter is restricted to. Useful when a
single endpoint exposes only a subset of the schema:

  (repo-get-by repo 'user attrs :allowed-keys '(:email :public-id))

When ALLOWED-KEYS is unset, every declared field on the schema is
acceptable."
  (let* ((schema (find-schema schema-name))
         (declared (mapcar #'field-name (schema-fields schema)))
         (whitelist (or allowed-keys declared))
         (table (intern-table schema))
         (q (from table)))
    (loop for (k v) on filters by #'cddr
          do (unless (member k whitelist)
               (error "repo-get-by: ~a is not in the allowed filter ~
                       keys for schema ~a (declared: ~a)"
                      k schema-name declared))
             (setf q (where q (list '= k v))))
    (repo-one repo q)))

(defun repo-exists-p (repo query)
  "Return T if any row matches QUERY."
  (not (null (repo-one repo query))))

(defun intern-table (schema)
  (alexandria:make-keyword (string-upcase (schema-table schema))))

;;; --- mutations: take a changeset, return (values record-or-nil cs) ---

(defun drop-virtual (schema values)
  "Remove virtual fields (declared with :virtual t) so they never reach SQL."
  (let ((virtual (loop for f in (schema-fields schema)
                       when (field-virtual-p f) collect (field-name f))))
    (if virtual
        (apply #'alexandria:remove-from-plist values virtual)
        values)))

(defun encode-embeds (schema values)
  "Serialize embedded changeset(s) under embed fields to JSON strings."
  (let ((embeds (remove-if-not
                 (lambda (a)
                   (member (association-kind a) '(:embeds-one :embeds-many)))
                 (schema-assocs schema))))
    (if (null embeds) values
        (let ((out (copy-list values)))
          (dolist (a embeds)
            (let* ((key (association-name a))
                   (v   (getf out key)))
              (when v
                (setf (getf out key)
                      (case (association-kind a)
                        (:embeds-one  (jonathan:to-json (apply-changes v)))
                        (:embeds-many (jonathan:to-json
                                       (mapcar #'apply-changes v))))))))
          out))))

(defun stamp-insert (schema values)
  "If SCHEMA opts into :timestamps, set inserted-at and updated-at."
  (if (schema-timestamps-p schema)
      (let ((now (now-naive-datetime)))
        (list* :inserted-at now :updated-at now
               (alexandria:remove-from-plist values :inserted-at :updated-at)))
      values))

(defun stamp-update (schema changes)
  (if (schema-timestamps-p schema)
      (list* :updated-at (now-naive-datetime)
             (alexandria:remove-from-plist changes :updated-at))
      changes))

(defun prepare-row (schema values action)
  "Apply the persistence pipeline for ACTION (:insert or :update):
strip changeset metadata -> add timestamps -> tag boolean false values
with the :FALSE sentinel based on field type -> drop virtual fields ->
encode embeds. Returns a fresh plist ready for SQL."
  (encode-embeds
   schema
   (drop-virtual
    schema
    (encode-booleans
     schema
     (ecase action
       (:insert (stamp-insert schema (strip-cs-metadata values)))
       (:update (stamp-update schema (strip-cs-metadata values))))))))

(defun strip-cs-metadata (values)
  "Drop changeset-side metadata (e.g. :__schema__) so it can't accidentally
become a SQL column."
  (alexandria:remove-from-plist values :__schema__))

(defun encode-booleans (schema values)
  "For each boolean field present in VALUES with the value NIL, swap NIL
for the :FALSE sentinel so adapter encoders can distinguish 'boolean
false' from 'SQL NULL'. Non-boolean fields are untouched, so a stray
:FALSE elsewhere is never auto-translated."
  (let ((bool-fields (loop for f in (schema-fields schema)
                           when (eq (field-type f) :boolean)
                           collect (field-name f))))
    (if (null bool-fields)
        values
        (loop for (k v) on values by #'cddr
              collect k
              collect (if (and (member k bool-fields) (null v)) :false v)))))

(defun query-where-expr (q)
  "Collapse a query's accumulated wheres into a single expression (or NIL)."
  (let ((ws (query-wheres q)))
    (cond ((null ws) nil)
          ((null (cdr ws)) (car ws))
          (t (cons 'and ws)))))

(defun catch-constraint-error (adapter cs thunk)
  "Run THUNK. If it signals a DB error matching a constraint declared on
CS, return (values nil cs-with-error). Otherwise wrap the original
condition in CLECTO:DB-ERROR so the raw, possibly-row-leaking message
isn't surfaced by default error handling."
  (handler-case (funcall thunk)
    (clecto:db-error (e) (error e))   ; already wrapped — pass through
    (error (e)
      (multiple-value-bind (field message)
          (adapter-translate-constraint-error adapter e (cs-constraints cs))
        (if field
            (values nil (add-error cs field message))
            (error 'db-error :original e))))))

(defun do-insert-returning (adapter sql params on-conflict)
  "PG-style: ask the DB for the inserted row in one round trip. Returns
the row plist, or NIL when :on-conflict :nothing matched no row."
  (with-telemetry (adapter sql params)
    (or (first (adapter-execute adapter sql params))
        (unless (eq on-conflict :nothing)
          (error "RETURNING produced no row")))))

(defun do-insert-last-id (adapter sql params schema values)
  "SQLite-style: execute, take last_insert_rowid from the multi-value
return, build the inserted row by overlaying the new PK on VALUES."
  (with-telemetry (adapter sql params)
    (multiple-value-bind (changes last-id)
        (adapter-execute-returning adapter sql params)
      (declare (ignore changes))
      (let ((pk (schema-primary-key schema)))
        (list* pk (or (getf values pk) last-id) values)))))

(defun repo-insert (repo cs &key on-conflict conflict-target)
  "Insert from changeset. Returns (values record nil) on success or
(values nil cs) on validation or constraint failure.

ON-CONFLICT and CONFLICT-TARGET enable upsert; see INSERT-SQL."
  (if (not (cs-valid-p cs))
      (values nil cs)
      (catch-constraint-error
       (repo-adapter repo) cs
       (lambda ()
         (let* ((adapter (repo-adapter repo))
                (schema  (find-schema (cs-schema cs)))
                (table   (intern-table schema))
                (values  (prepare-row schema (apply-changes cs) :insert))
                (target  (or conflict-target
                             (and on-conflict (schema-primary-key schema))))
                (use-returning (adapter-supports-returning-p adapter)))
           (multiple-value-bind (sql params)
               (insert-sql adapter table values
                           :on-conflict on-conflict
                           :conflict-target target
                           :returning (when use-returning t))
             (let ((record (if use-returning
                               (do-insert-returning adapter sql params on-conflict)
                               (do-insert-last-id adapter sql params schema values))))
               (values record nil))))))))

(defun repo-update (repo cs)
  "Update the row identified by the changeset's data (must include PK)."
  (if (not (cs-valid-p cs))
      (values nil cs)
      (catch-constraint-error
       (repo-adapter repo) cs
       (lambda ()
         (let* ((schema  (find-schema (cs-schema cs)))
                (table   (intern-table schema))
                (pk      (schema-primary-key schema))
                (id      (getf (cs-data cs) pk))
                (changes (prepare-row schema (cs-changes cs) :update)))
           (unless id (error "repo-update: data is missing primary key ~a" pk))
           (multiple-value-bind (sql params)
               (update-sql (repo-adapter repo) table changes (list '= pk id))
             (with-telemetry ((repo-adapter repo) sql params)
               (adapter-execute-returning (repo-adapter repo) sql params))
             (values (apply-changes (copy-cs cs :changes changes)) nil)))))))

(defvar *repo-insert-all-row-cap* 1000
  "Maximum rows accepted by a single REPO-INSERT-ALL call. Keeps a single
malformed call from exhausting memory or hitting Postgres' 65535-parameter
limit. Callers with legitimately larger batches should chunk explicitly.")

(defun repo-insert-all (repo schema-name rows)
  "Bulk insert ROWS (a list of plists). Auto-stamps timestamps when enabled.
Returns the number of rows inserted. Caps at *repo-insert-all-row-cap*."
  (when rows
    (when (> (length rows) *repo-insert-all-row-cap*)
      (error "repo-insert-all: ~d rows exceeds cap of ~d. Chunk the input."
             (length rows) *repo-insert-all-row-cap*))
    (let* ((schema (find-schema schema-name))
           (table  (intern-table schema))
           (stamped (mapcar (lambda (r) (stamp-insert schema r)) rows)))
      (multiple-value-bind (sql params)
          (insert-all-sql (repo-adapter repo) table stamped)
        (with-telemetry ((repo-adapter repo) sql params)
          (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))))

(defun tautological-where-p (expr)
  "T when EXPR is a where-clause that matches every row regardless
of input. Used by the bulk mutation guards to refuse a query that
*looks* filtered but is actually a no-op like (where q t) or
(where q '(= 1 1)).

The check is conservative — it only flags the obvious tautologies.
A clever caller can still smuggle T past us with (or t ...) or
(:fragment \"1=1\"); the guard is a safety net for accidents,
not a sandbox."
  (or (eq expr t)
      (and (consp expr)
           (let ((op (and (symbolp (first expr))
                          (string-upcase (symbol-name (first expr))))))
             (and (equal op "=")
                  (equal (second expr) (third expr)))))))

(defun query-has-real-where-p (query)
  "T when QUERY has at least one where clause that isn't a
tautology. Used by the bulk mutation guards."
  (and (query-wheres query)
       (some (lambda (e) (not (tautological-where-p e)))
             (query-wheres query))))

(defun repo-update-all (repo query set-plist &key all)
  "Bulk UPDATE rows matching QUERY with SET-PLIST. Returns rows affected.

A QUERY with no WHERE clause — or one whose only clauses are
tautologies like (where q t) or (where q '(= 1 1)) — would update
every row in the table. That's almost always a bug introduced by a
missing WHERE-IF or a placeholder filter that never got replaced.
Refuses unless ALL is non-nil — pass :ALL T to confirm you really
mean every row."
  (unless (or all (query-has-real-where-p query))
    (error "repo-update-all refuses to touch every row.~@
            Add a non-tautological WHERE or pass :all t."))
  (multiple-value-bind (sql params)
      (update-sql (repo-adapter repo) (query-table query)
                  set-plist (query-where-expr query))
    (with-telemetry ((repo-adapter repo) sql params)
      (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))

(defun repo-delete-all (repo query &key all)
  "Bulk DELETE rows matching QUERY. Returns rows affected. See
REPO-UPDATE-ALL for the no-WHERE / tautology safety guard."
  (unless (or all (query-has-real-where-p query))
    (error "repo-delete-all refuses to delete every row.~@
            Add a non-tautological WHERE or pass :all t."))
  (multiple-value-bind (sql params)
      (delete-sql (repo-adapter repo) (query-table query)
                  (query-where-expr query))
    (with-telemetry ((repo-adapter repo) sql params)
      (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))

(defun repo-delete (repo schema-name id)
  (let* ((schema (find-schema schema-name))
         (table  (intern-table schema))
         (pk     (schema-primary-key schema)))
    (multiple-value-bind (sql params)
        (delete-sql (repo-adapter repo) table (list '= pk id))
      (with-telemetry ((repo-adapter repo) sql params)
        (adapter-execute-returning (repo-adapter repo) sql params)))))

;;; --- preloading associations ---

(defun single-plist-p (x)
  "Heuristic: a single plist starts with a keyword. A list-of-plists starts
with a list."
  (and (consp x) (keywordp (car x))))

(defun group-by-key (records key)
  (let ((h (make-hash-table :test 'equal)))
    (dolist (r records)
      (push r (gethash (getf r key) h)))
    (maphash (lambda (k v) (setf (gethash k h) (nreverse v))) h)
    h))

(defun replace-key (plist key value)
  (list* key value (alexandria:remove-from-plist plist key)))

(defun preload-by-ids (repo records local-key target-table target-key
                       &key (group-mode :many))
  "Generic preload step: collect LOCAL-KEY from RECORDS, query
TARGET-TABLE WHERE TARGET-KEY IN ids, return (values children-by-id).
GROUP-MODE is :many (list of children per id) or :one (single child).
Returns a hash table keyed by the local-key value."
  (let* ((ids (remove-duplicates
               (remove nil (mapcar (lambda (r) (getf r local-key)) records))
               :test #'equal))
         (children (when ids
                     (repo-all repo
                               (where (from target-table)
                                      (list 'in target-key ids))))))
    (ecase group-mode
      (:many (group-by-key children target-key))
      (:one  (let ((h (make-hash-table :test 'equal)))
               (dolist (c children) (setf (gethash (getf c target-key) h) c))
               h)))))

(defun preload-one (repo parent-schema a records)
  (let* ((target (find-schema (association-target a)))
         (target-table (intern-table target))
         (assoc-key (association-name a)))
    (case (association-kind a)
      (:has-many
       (let ((grouped (preload-by-ids repo records
                                      (schema-primary-key parent-schema)
                                      target-table
                                      (association-foreign-key a))))
         (mapcar (lambda (r)
                   (replace-key r assoc-key
                                (gethash (getf r (schema-primary-key parent-schema))
                                         grouped)))
                 records)))
      (:has-one
       (let ((grouped (preload-by-ids repo records
                                      (schema-primary-key parent-schema)
                                      target-table
                                      (association-foreign-key a))))
         (mapcar (lambda (r)
                   (replace-key r assoc-key
                                (first
                                 (gethash (getf r (schema-primary-key parent-schema))
                                          grouped))))
                 records)))
      (:belongs-to
       (let ((index (preload-by-ids repo records
                                    (association-foreign-key a)
                                    target-table
                                    (schema-primary-key target)
                                    :group-mode :one)))
         (mapcar (lambda (r)
                   (replace-key r assoc-key
                                (gethash (getf r (association-foreign-key a))
                                         index)))
                 records)))
      (t (error "Unknown association kind: ~a" (association-kind a))))))

(defun repo-preload (repo schema-name records assocs)
  "Preload one or more associations. RECORDS may be a single plist or a list
of plists. ASSOCS is an association name (keyword) or a list of them.
Returns RECORDS with each association attached under its declared name."
  (let* ((schema (find-schema schema-name))
         (single-p (single-plist-p records))
         (record-list (if single-p (list records) records))
         (names (alexandria:ensure-list assocs))
         (result record-list))
    (dolist (n names)
      (let ((a (schema-assoc schema n)))
        (unless a
          (error "Schema ~a has no association ~a" schema-name n))
        (setf result (preload-one repo schema a result))))
    (if single-p (first result) result)))

;;; --- transactions ---

(defun call-with-transaction (repo thunk)
  "Run THUNK inside a transaction. If THUNK signals a CLECTO:ROLLBACK
condition or any other error, the transaction is rolled back. Otherwise
it commits. Nesting uses savepoints."
  (let ((adapter (repo-adapter repo))
        (committed nil))
    (adapter-begin adapter)
    (unwind-protect
         (handler-case
             (let ((result (funcall thunk)))
               (adapter-commit adapter)
               (setf committed t)
               result)
           (rollback ()
             (adapter-rollback adapter)
             (setf committed t)
             nil))
      (unless committed
        (adapter-rollback adapter)))))

(defmacro repo-transaction ((repo) &body body)
  "Run BODY inside a transaction on REPO.

  (repo-transaction (*repo*)
    (repo-insert *repo* cs1)
    (repo-insert *repo* cs2))

Signal CLECTO:ROLLBACK from within BODY to abort cleanly. Any other
condition also rolls back and is re-raised."
  `(call-with-transaction ,repo (lambda () ,@body)))

(defun rollback ()
  "Abort the enclosing repo-transaction."
  (signal 'rollback))

;;; --- escape hatch for raw SQL / migrations ---

(defun repo-execute (repo sql &optional params)
  "Run raw SQL with optional positional PARAMS.

This is an UNPARAMETERISED ESCAPE HATCH — the SQL string is passed
to the adapter unchanged. It's intended for DDL during demos and
tests, one-off admin queries, and bootstrapping when an external
migration tool isn't yet wired up.

USE PARAMS FOR EVERY DYNAMIC VALUE. The first argument is fixed
SQL; the second carries the values:

  GOOD:
    (repo-execute repo
                  \"SELECT * FROM users WHERE id = ?\"
                  (list user-id))

  BAD (SQL injection):
    (repo-execute repo
                  (format nil \"SELECT * FROM users WHERE id = ~a\"
                          user-id))

There is no smart string parser between this function and the
adapter — anything you concatenate into SQL is executed verbatim.
Never thread user input into the SQL string itself; bind it via
PARAMS."
  (let ((adapter (repo-adapter repo)))
    (with-telemetry (adapter sql params)
      (adapter-execute adapter sql params))))
