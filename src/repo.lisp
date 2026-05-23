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

(defun intern-table (schema)
  (alexandria:make-keyword (string-upcase (schema-table schema))))

;;; --- mutations: take a changeset, return (values record-or-nil cs) ---

(defun repo-insert (repo cs)
  "Insert from changeset. Returns (values record nil) on success
or (values nil cs) when invalid."
  (if (not (cs-valid-p cs))
      (values nil cs)
      (let* ((schema (find-schema (cs-schema cs)))
             (table  (intern-table schema))
             (values (apply-changes cs)))
        (multiple-value-bind (sql params)
            (insert-sql (repo-adapter repo) table values)
          (adapter-execute-returning (repo-adapter repo) sql params)
          (let* ((pk (schema-primary-key schema))
                 (id (or (getf values pk)
                         (adapter-last-insert-id (repo-adapter repo))))
                 (record (list* pk id values)))
            (values record nil))))))

(defun repo-update (repo cs)
  "Update the row identified by the changeset's data (must include PK)."
  (if (not (cs-valid-p cs))
      (values nil cs)
      (let* ((schema (find-schema (cs-schema cs)))
             (table  (intern-table schema))
             (pk     (schema-primary-key schema))
             (id     (getf (cs-data cs) pk)))
        (unless id (error "repo-update: data is missing primary key ~a" pk))
        (multiple-value-bind (sql params)
            (update-sql (repo-adapter repo) table (cs-changes cs)
                        (list '= pk id))
          (adapter-execute-returning (repo-adapter repo) sql params)
          (values (apply-changes cs) nil)))))

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

;;; --- escape hatch for raw SQL / migrations ---

(defun repo-execute (repo sql &optional params)
  (adapter-execute (repo-adapter repo) sql params))
