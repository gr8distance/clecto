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

;;; --- escape hatch for raw SQL / migrations ---

(defun repo-execute (repo sql &optional params)
  (adapter-execute (repo-adapter repo) sql params))
