(in-package #:clecto)

;;; Mutation compilers: INSERT (with ON CONFLICT), INSERT...VALUES (multi),
;;; UPDATE, DELETE.

(defun insert-sql (adapter table values-plist
                   &key on-conflict conflict-target returning)
  "Optional ON-CONFLICT modes:
  :nothing         -> ON CONFLICT DO NOTHING
  :replace         -> ON CONFLICT DO UPDATE SET (all cols)
  (:replace COLS)  -> ON CONFLICT DO UPDATE SET (listed cols)
CONFLICT-TARGET is a column keyword or list of keywords (defaults to PK column).
RETURNING is a column keyword, list of keywords, or T (for *) — adapters
that support it (Postgres) get a RETURNING clause appended."
  (let ((st (make-sql-state :adapter adapter)))
    (multiple-value-bind (cols vals) (plist-split values-plist)
      (let* ((placeholders (mapcar (lambda (v) (emit-param st v)) vals))
             (conflict-sql (when on-conflict
                             (render-conflict adapter on-conflict
                                              conflict-target cols)))
             (returning-sql (when returning (render-returning adapter returning)))
             (sql (format nil "INSERT INTO ~a (~{~a~^, ~}) VALUES (~{~a~^, ~})~@[~a~]~@[~a~]"
                          (qi adapter table)
                          (mapcar (lambda (c) (qi adapter c)) cols)
                          placeholders
                          conflict-sql
                          returning-sql)))
        (values sql (nreverse (sql-state-params st)))))))

(defun render-returning (adapter spec)
  (cond
    ((eq spec t) " RETURNING *")
    ((keywordp spec) (format nil " RETURNING ~a" (qi adapter spec)))
    ((consp spec)
     (format nil " RETURNING ~{~a~^, ~}"
             (mapcar (lambda (c) (qi adapter c)) spec)))
    (t (error "Bad :returning spec ~a" spec))))

(defun render-conflict (adapter on-conflict target all-cols)
  (let ((target-sql
          (when target
            (format nil "(~{~a~^, ~})"
                    (mapcar (lambda (c) (qi adapter c))
                            (alexandria:ensure-list target))))))
    (cond
      ((eq on-conflict :nothing)
       (format nil " ON CONFLICT~@[~a~] DO NOTHING" target-sql))
      ((eq on-conflict :replace)
       (format nil " ON CONFLICT~@[~a~] DO UPDATE SET ~a"
               target-sql (excluded-set adapter all-cols)))
      ((and (consp on-conflict) (eq (first on-conflict) :replace))
       (format nil " ON CONFLICT~@[~a~] DO UPDATE SET ~a"
               target-sql (excluded-set adapter (rest on-conflict))))
      (t (error "Unknown :on-conflict mode: ~a" on-conflict)))))

(defun excluded-set (adapter cols)
  "Emit \"col\" = excluded.\"col\" pairs. Both sides are properly quoted
so a hostile (or just weird) column name can't escape its quotes."
  (format nil "~{~a~^, ~}"
          (mapcar (lambda (c)
                    (format nil "~a = excluded.\"~a\""
                            (qi adapter c)
                            (escape-identifier-body (sqlify-column c))))
                  cols)))

(defun insert-all-sql (adapter table rows)
  "Compile a multi-row INSERT. ROWS is a list of plists. All rows must
share the same column set; column order is taken from the first row."
  (let* ((st (make-sql-state :adapter adapter))
         (cols (nth-value 0 (plist-split (first rows))))
         (col-sql (format nil "~{~a~^, ~}" (mapcar (lambda (c) (qi adapter c)) cols)))
         (tuples
           (mapcar (lambda (row)
                     (format nil "(~{~a~^, ~})"
                             (mapcar (lambda (c)
                                       (emit-param st (getf row c)))
                                     cols)))
                   rows))
         (sql (format nil "INSERT INTO ~a (~a) VALUES ~{~a~^, ~}"
                      (qi adapter table) col-sql tuples)))
    (values sql (nreverse (sql-state-params st)))))

(defun compile-set-value (st v)
  "Compile a value sitting on the right-hand side of an UPDATE SET pair.

A (:fragment ...) form expands to its raw-SQL body with safe parameter
substitution (used by clauth's atomic increment). Anything else —
including bare keywords — is treated as a parameter value.

For an SQL-side column-to-column copy, write it as a fragment:
    (list :name (list :fragment \"other_col\"))

NOT as a bare keyword. Bare keywords used to compile to column
references, which made it possible for a :enum cast result (e.g.
the keyword :ACTIVE in (put-change cs :status :active)) to silently
become a column reference in the generated SQL:

    -- before this fix:
    UPDATE users SET \"status\" = \"active\" WHERE \"id\" = ?
    --                              ↑↑↑↑↑↑↑↑ column ref, not 'active'

If the table happened to have an \"active\" column, this would copy
that column's value into the status column. The risk surface was
small in practice (caller-controlled cast pipeline), but the
footgun was sharp.

The boolean sentinels :TRUE / :FALSE (introduced by ENCODE-BOOLEANS)
go through EMIT-PARAM so the adapter can render them as 0/1 / 't'/'f'."
  (cond
    ((and (consp v) (eq (car v) :fragment))
     (compile-fragment st v))
    (t
     ;; Bind every other value — including keywords (enum values, etc.) —
     ;; as a parameter. Column-ref-as-SET-RHS is the fragment-only path
     ;; now; explicit, auditable, no surprises.
     (emit-param st v))))

(defun update-sql (adapter table set-plist where-expr)
  "Compile an UPDATE statement. SET-PLIST values are run through
COMPILE-SET-VALUE so callers can do
    (list :counter (list :fragment \"counter + 1\"))
to get an atomic SQL-side increment."
  (let* ((st (make-sql-state :adapter adapter))
         (set-pairs
           (loop for (k v) on set-plist by #'cddr
                 collect (format nil "~a = ~a"
                                 (qi adapter k)
                                 (compile-set-value st v))))
         (where-sql (when where-expr
                      (format nil " WHERE ~a" (compile-expr st where-expr))))
         (sql (format nil "UPDATE ~a SET ~{~a~^, ~}~@[~a~]"
                      (qi adapter table) set-pairs where-sql)))
    (values sql (nreverse (sql-state-params st)))))

(defun delete-sql (adapter table where-expr)
  (let* ((st (make-sql-state :adapter adapter))
         (where-sql (when where-expr
                      (format nil " WHERE ~a" (compile-expr st where-expr))))
         (sql (format nil "DELETE FROM ~a~@[~a~]"
                      (qi adapter table) where-sql)))
    (values sql (nreverse (sql-state-params st)))))
