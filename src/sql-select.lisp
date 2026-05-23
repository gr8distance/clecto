(in-package #:clecto)

;;; SELECT compiler: table sources, joins, distinct, CTEs, combinators,
;;; group/having, order/limit/offset, lock.

(defun compile-select-col (st c)
  (or (compile-column-or-aggregate st c)
      (error "Bad select column: ~a" c)))

(defun order-direction-sql (dir)
  (case dir
    (:asc "ASC")
    (:desc "DESC")
    (t (error "Bad ORDER BY direction ~a (allowed: :asc :desc)" dir))))

(defun lock-sql-keyword (lock)
  (case lock
    (:for-update "FOR UPDATE")
    (:for-share  "FOR SHARE")
    (:no-key-update "FOR NO KEY UPDATE")
    (:key-share     "FOR KEY SHARE")
    (t (error "Bad lock mode ~a" lock))))

(defun kind-sql (kind)
  (case kind
    (:inner "INNER")
    (:left  "LEFT")
    (:right "RIGHT")
    (:full  "FULL")
    (t (error "Bad JOIN kind ~a" kind))))

(defun combinator-keyword-sql (k)
  (case k
    (:union "UNION")
    (:union-all "UNION ALL")
    (:intersect "INTERSECT")
    (:except "EXCEPT")
    (t (error "Bad set-op ~a" k))))

(defun compile-table-source (st x &optional prefix)
  (cond
    ((subquery-p x)
     (format nil "(~a) AS ~a"
             (emit-select st (subquery-query x))
             (qi (sql-state-adapter st) (subquery-alias x))))
    (prefix
     (format nil "~a.~a"
             (qi (sql-state-adapter st) prefix)
             (qi (sql-state-adapter st) x)))
    (t (qi (sql-state-adapter st) x))))

(defun select-sql (adapter q)
  "Compile a QUERY into (values sql params)."
  (let* ((st (make-sql-state :adapter adapter))
         (sql (emit-select st q)))
    (values sql (nreverse (sql-state-params st)))))

(defun emit-select (st q)
  "Render a SELECT statement using shared state ST. Used recursively for
subqueries so all params live in one list."
  (let* ((adapter (sql-state-adapter st))
         (cte-sql
           (when (query-ctes q)
             (format nil "WITH ~{~a~^, ~} "
                     (mapcar (lambda (c)
                               (format nil "~a AS (~a)"
                                       (qi adapter (first c))
                                       (emit-select st (second c))))
                             (query-ctes q)))))
         (distinct-sql
           (cond
             ((null (query-distinct q)) "")
             ((eq (query-distinct q) t) "DISTINCT ")
             (t (format nil "DISTINCT ON (~{~a~^, ~}) "
                        (mapcar (lambda (c) (qi adapter c))
                                (alexandria:ensure-list (query-distinct q)))))))
         (cols (if (query-selects q)
                   (format nil "~{~a~^, ~}"
                           (mapcar (lambda (c) (compile-select-col st c))
                                   (query-selects q)))
                   "*"))
         (join-sql
           (when (query-joins q)
             (apply #'concatenate 'string
                    (mapcar (lambda (j)
                              (format nil " ~a JOIN ~a ON ~a"
                                      (kind-sql (getf j :kind))
                                      (compile-table-source st (getf j :table))
                                      (compile-expr st (getf j :on))))
                            (query-joins q)))))
         (where-sql
           (when (query-wheres q)
             (let ((parts (mapcar (lambda (e) (compile-expr st e))
                                  (query-wheres q))))
               (format nil " WHERE ~{~a~^ AND ~}" parts))))
         (group-sql
           (when (query-groups q)
             (format nil " GROUP BY ~{~a~^, ~}"
                     (mapcar (lambda (c) (qi adapter c)) (query-groups q)))))
         (having-sql
           (when (query-havings q)
             (let ((parts (mapcar (lambda (e) (compile-expr st e))
                                  (query-havings q))))
               (format nil " HAVING ~{~a~^ AND ~}" parts))))
         (order-sql
           (when (query-orders q)
             (format nil " ORDER BY ~{~a~^, ~}"
                     (mapcar (lambda (o)
                               (format nil "~a ~a"
                                       (qi adapter (second o))
                                       (order-direction-sql (first o))))
                             (query-orders q)))))
         (limit-sql
           (when (query-limit q)
             (check-type (query-limit q) (integer 0 *) "a non-negative LIMIT")
             (format nil " LIMIT ~d" (query-limit q))))
         (offset-sql
           (when (query-offset q)
             (check-type (query-offset q) (integer 0 *) "a non-negative OFFSET")
             (format nil " OFFSET ~d" (query-offset q))))
         (combinator-sql
           (when (query-combinators q)
             (apply #'concatenate 'string
                    (mapcar (lambda (pair)
                              (format nil " ~a ~a"
                                      (combinator-keyword-sql (first pair))
                                      (emit-select st (second pair))))
                            (query-combinators q)))))
         (lock-sql (when (query-lock q)
                     (format nil " ~a" (lock-sql-keyword (query-lock q))))))
    (format nil "~@[~a~]SELECT ~a~a FROM ~a~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]"
            cte-sql distinct-sql cols
            (compile-table-source st (query-table q) (query-prefix q))
            join-sql where-sql
            group-sql having-sql
            combinator-sql
            order-sql limit-sql offset-sql
            lock-sql)))
