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
  (multiple-value-bind (sql params) (select-sql (repo-adapter repo) query)
    (adapter-execute (repo-adapter repo) sql params)))

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

(defun catch-constraint-error (adapter cs thunk)
  "Run THUNK. If it signals a DB error matching a constraint declared on CS,
return (values nil cs-with-error). Otherwise propagate."
  (handler-case (funcall thunk)
    (error (e)
      (multiple-value-bind (field message)
          (adapter-translate-constraint-error adapter e (cs-constraints cs))
        (if field
            (values nil (add-error cs field message))
            (error e))))))

(defun repo-insert (repo cs &key on-conflict conflict-target)
  "Insert from changeset. Returns (values record nil) on success or
(values nil cs) on validation or constraint failure.

ON-CONFLICT and CONFLICT-TARGET enable upsert; see INSERT-SQL."
  (if (not (cs-valid-p cs))
      (values nil cs)
      (catch-constraint-error
       (repo-adapter repo) cs
       (lambda ()
         (let* ((schema (find-schema (cs-schema cs)))
                (table  (intern-table schema))
                (values (stamp-insert schema (apply-changes cs)))
                (target (or conflict-target
                            (and on-conflict (schema-primary-key schema)))))
           (multiple-value-bind (sql params)
               (insert-sql (repo-adapter repo) table values
                           :on-conflict on-conflict
                           :conflict-target target)
             (adapter-execute-returning (repo-adapter repo) sql params)
             (let* ((pk (schema-primary-key schema))
                    (id (or (getf values pk)
                            (adapter-last-insert-id (repo-adapter repo))))
                    (record (list* pk id values)))
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
                (changes (stamp-update schema (cs-changes cs))))
           (unless id (error "repo-update: data is missing primary key ~a" pk))
           (multiple-value-bind (sql params)
               (update-sql (repo-adapter repo) table changes (list '= pk id))
             (adapter-execute-returning (repo-adapter repo) sql params)
             (values (append changes (cs-data cs)) nil)))))))

(defun repo-insert-all (repo schema-name rows)
  "Bulk insert ROWS (a list of plists). Auto-stamps timestamps when enabled.
Returns the number of rows inserted."
  (when rows
    (let* ((schema (find-schema schema-name))
           (table  (intern-table schema))
           (stamped (if (schema-timestamps-p schema)
                        (let ((now (now-naive-datetime)))
                          (mapcar (lambda (r)
                                    (list* :inserted-at now :updated-at now
                                           (alexandria:remove-from-plist
                                            r :inserted-at :updated-at)))
                                  rows))
                        rows)))
      (multiple-value-bind (sql params)
          (insert-all-sql (repo-adapter repo) table stamped)
        (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params))))))

(defun repo-update-all (repo query set-plist)
  "Bulk UPDATE rows matching QUERY with SET-PLIST. Returns rows affected."
  (let* ((table (query-table query))
         (where (when (query-wheres query)
                  (if (= 1 (length (query-wheres query)))
                      (first (query-wheres query))
                      (cons 'and (query-wheres query))))))
    (multiple-value-bind (sql params)
        (update-sql (repo-adapter repo) table set-plist where)
      (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))

(defun repo-delete-all (repo query)
  "Bulk DELETE rows matching QUERY. Returns rows affected."
  (let* ((table (query-table query))
         (where (when (query-wheres query)
                  (if (= 1 (length (query-wheres query)))
                      (first (query-wheres query))
                      (cons 'and (query-wheres query))))))
    (multiple-value-bind (sql params)
        (delete-sql (repo-adapter repo) table where)
      (nth-value 0 (adapter-execute-returning (repo-adapter repo) sql params)))))

(defun repo-delete (repo schema-name id)
  (let* ((schema (find-schema schema-name))
         (table  (intern-table schema))
         (pk     (schema-primary-key schema)))
    (multiple-value-bind (sql params)
        (delete-sql (repo-adapter repo) table (list '= pk id))
      (adapter-execute-returning (repo-adapter repo) sql params))))

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
  (adapter-execute (repo-adapter repo) sql params))
