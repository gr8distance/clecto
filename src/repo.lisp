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

(defun repo-get-by (repo schema-name filters)
  "Fetch the first row matching FILTERS (a plist of field/value pairs)."
  (let* ((schema  (find-schema schema-name))
         (table   (intern-table schema))
         (clauses (loop for (k v) on filters by #'cddr collect (list '= k v)))
         (q       (reduce (lambda (q expr) (where q expr))
                          clauses
                          :initial-value (from table))))
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
             (let ((record
                     (with-telemetry (adapter sql params)
                       (cond
                         (use-returning
                          ;; Adapter returns the inserted row (PG style).
                          ;; If :on-conflict :nothing matched, RETURNING is
                          ;; empty — treat as a benign no-op insert.
                          (or (first (adapter-execute adapter sql params))
                              (when (eq on-conflict :nothing)
                                (return-from repo-insert (values nil nil)))
                              (error "RETURNING produced no row")))
                         (t
                          ;; SQLite path: returning multi-values gives us
                          ;; the last id atomically, no extra round-trip.
                          (multiple-value-bind (changes last-id)
                              (adapter-execute-returning adapter sql params)
                            (declare (ignore changes))
                            (let* ((pk (schema-primary-key schema))
                                   (id (or (getf values pk) last-id)))
                              (list* pk id values))))))))
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

(defun repo-update-all (repo query set-plist &key all)
  "Bulk UPDATE rows matching QUERY with SET-PLIST. Returns rows affected.

A QUERY with no WHERE clause would update every row in the table; that
is almost always a bug introduced by a missing WHERE-IF. Refuses unless
ALL is non-nil — pass :ALL T to confirm you really mean every row."
  (unless (or all (query-wheres query))
    (error "repo-update-all refuses to touch every row.~@
            Add a WHERE or pass :all t."))
  (multiple-value-bind (sql params)
      (update-sql (repo-adapter repo) (query-table query)
                  set-plist (query-where-expr query))
    (with-telemetry ((repo-adapter repo) sql params)
      (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))

(defun repo-delete-all (repo query &key all)
  "Bulk DELETE rows matching QUERY. Returns rows affected. See
REPO-UPDATE-ALL for the no-WHERE safety guard."
  (unless (or all (query-wheres query))
    (error "repo-delete-all refuses to delete every row.~@
            Add a WHERE or pass :all t."))
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

(defun preload-has-many (repo parent-schema a records &key only-one)
  (let* ((pk (schema-primary-key parent-schema))
         (fk (association-foreign-key a))
         (target (find-schema (association-target a)))
         (ids (remove-duplicates (mapcar (lambda (r) (getf r pk)) records)
                                 :test #'equal))
         (children (when ids
                     (repo-all repo
                               (where (from (intern-table target))
                                      (list 'in fk ids)))))
         (grouped (group-by-key children fk)))
    (mapcar (lambda (r)
              (let* ((matches (gethash (getf r pk) grouped))
                     (value (if only-one (first matches) (or matches nil))))
                (replace-key r (association-name a) value)))
            records)))

(defun preload-belongs-to (repo parent-schema a records)
  (declare (ignore parent-schema))
  (let* ((fk (association-foreign-key a))
         (target (find-schema (association-target a)))
         (target-pk (schema-primary-key target))
         (fks (remove-duplicates
               (remove nil (mapcar (lambda (r) (getf r fk)) records))
               :test #'equal))
         (parents (when fks
                    (repo-all repo
                              (where (from (intern-table target))
                                     (list 'in target-pk fks)))))
         (index (make-hash-table :test 'equal)))
    (dolist (p parents)
      (setf (gethash (getf p target-pk) index) p))
    (mapcar (lambda (r)
              (replace-key r (association-name a) (gethash (getf r fk) index)))
            records)))

(defun preload-one (repo parent-schema a records)
  (case (association-kind a)
    (:has-many   (preload-has-many   repo parent-schema a records))
    (:has-one    (preload-has-many   repo parent-schema a records :only-one t))
    (:belongs-to (preload-belongs-to repo parent-schema a records))
    (t (error "Unknown association kind: ~a" (association-kind a)))))

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
  (let ((adapter (repo-adapter repo)))
    (with-telemetry (adapter sql params)
      (adapter-execute adapter sql params))))
