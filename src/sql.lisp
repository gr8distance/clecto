(in-package #:clecto)

;;; AST -> SQL string + params. Dialect specifics (quoting, placeholders)
;;; are delegated to the adapter. The compiler itself is pure.

(defstruct sql-state
  (adapter nil)
  (params  nil)    ; reverse-accumulated
  (index   0))     ; placeholder counter

(defun emit-param (st value)
  "Append VALUE as a parameter; return its placeholder string."
  (incf (sql-state-index st))
  (push value (sql-state-params st))
  (adapter-placeholder (sql-state-adapter st) (sql-state-index st)))

(defun qi (adapter name)
  (adapter-quote-identifier adapter name))

(defparameter *aggregates* '(:count :sum :avg :min :max))

(defun aggregate-form-p (x)
  (and (consp x) (member (car x) *aggregates*)))

(defun compile-aggregate (adapter form)
  (let ((fn  (string-upcase (symbol-name (first form))))
        (arg (second form)))
    (cond
      ((or (eq arg :*) (eq arg '*) (equal arg "*"))
       (format nil "~a(*)" fn))
      (t (format nil "~a(~a)" fn (qi adapter arg))))))

(defun fragment-form-p (x)
  (and (consp x) (eq (car x) :fragment)))

(defun compile-fragment (st form)
  "Expand (:fragment \"sql with ? holes\" arg1 arg2 ...) — each ? is
replaced by its arg compiled as an operand (column refs inline, other
values become parameters)."
  (let* ((tmpl (second form))
         (args (cddr form))
         (idx  0))
    (with-output-to-string (s)
      (loop for c across tmpl do
        (cond
          ((char= c #\?)
           (write-string (compile-operand st (nth idx args)) s)
           (incf idx))
          (t (write-char c s)))))))

(defun compile-operand (st x)
  "Compile a value that may be a column ref, an aggregate, a fragment,
or a literal param."
  (cond
    ((keywordp x) (qi (sql-state-adapter st) x))
    ((aggregate-form-p x) (compile-aggregate (sql-state-adapter st) x))
    ((fragment-form-p x)  (compile-fragment st x))
    (t (emit-param st x))))

(defun compile-expr (st expr)
  "Compile a where-expression to SQL string, accumulating params into ST."
  (cond
    ((or (null expr) (eq expr t))
     (if expr "1=1" "1=0"))
    ((fragment-form-p expr) (compile-fragment st expr))
    ((not (consp expr))
     (emit-param st expr))
    (t
     ;; Dispatch on the operator's name (case-insensitive) so user-side
     ;; symbols don't need to live in the clecto package.
     (let ((op-name (string-upcase (symbol-name (first expr)))))
       (cond
         ((or (string= op-name "AND") (string= op-name "OR"))
          (let ((parts (mapcar (lambda (e) (compile-expr st e)) (rest expr)))
                (sep (format nil " ~a " op-name)))
            (format nil "(~a)" (join-strings parts sep))))
         ((string= op-name "NOT")
          (format nil "(NOT ~a)" (compile-expr st (second expr))))
         ((string= op-name "IS-NULL")
          (format nil "~a IS NULL" (qi (sql-state-adapter st) (second expr))))
         ((string= op-name "IS-NOT-NULL")
          (format nil "~a IS NOT NULL" (qi (sql-state-adapter st) (second expr))))
         ((string= op-name "IN")
          (let* ((col (second expr))
                 (vals (third expr))
                 (placeholders (mapcar (lambda (v) (emit-param st v)) vals)))
            (format nil "~a IN (~{~a~^, ~})"
                    (qi (sql-state-adapter st) col)
                    placeholders)))
         ((string= op-name "LIKE")
          (format nil "~a LIKE ~a"
                  (qi (sql-state-adapter st) (second expr))
                  (emit-param st (third expr))))
         ((member op-name '("=" "<>" "<" "<=" ">" ">=") :test #'string=)
          (format nil "~a ~a ~a"
                  (compile-operand st (second expr))
                  op-name
                  (compile-operand st (third expr))))
         (t (error "Unknown where operator: ~a" (first expr))))))))

(defun join-strings (items sep)
  (with-output-to-string (s)
    (loop for (x . rest) on items
          do (write-string x s)
          when rest do (write-string sep s))))

;;; --- SELECT ---

(defun compile-select-col (st c)
  (cond
    ((keywordp c) (qi (sql-state-adapter st) c))
    ((aggregate-form-p c) (compile-aggregate (sql-state-adapter st) c))
    ((fragment-form-p c) (compile-fragment st c))
    (t (error "Bad select column: ~a" c))))

(defun kind-sql (kind)
  (case kind
    (:inner "INNER")
    (:left  "LEFT")
    (:right "RIGHT")
    (:full  "FULL")
    (t (string-upcase (string kind)))))

(defun select-sql (adapter q)
  "Compile a QUERY into (values sql params)."
  (let* ((st (make-sql-state :adapter adapter))
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
                                      (qi adapter (getf j :table))
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
                                       (string-upcase (string (first o)))))
                             (query-orders q)))))
         (limit-sql  (when (query-limit q)  (format nil " LIMIT ~a"  (query-limit q))))
         (offset-sql (when (query-offset q) (format nil " OFFSET ~a" (query-offset q))))
         (sql (format nil "SELECT ~a FROM ~a~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]"
                      cols
                      (qi adapter (query-table q))
                      join-sql where-sql
                      group-sql having-sql
                      order-sql limit-sql offset-sql)))
    (values sql (nreverse (sql-state-params st)))))

;;; --- INSERT / UPDATE / DELETE ---

(defun insert-sql (adapter table values-plist &key on-conflict conflict-target)
  "Optional ON-CONFLICT modes:
  :nothing         -> ON CONFLICT DO NOTHING
  :replace         -> ON CONFLICT DO UPDATE SET (all cols)
  (:replace COLS)  -> ON CONFLICT DO UPDATE SET (listed cols)
CONFLICT-TARGET is a column keyword or list of keywords (defaults to PK column)."
  (let* ((st (make-sql-state :adapter adapter))
         (cols (loop for (k v) on values-plist by #'cddr collect k))
         (vals (loop for (k v) on values-plist by #'cddr collect v))
         (placeholders (mapcar (lambda (v) (emit-param st v)) vals))
         (conflict-sql (when on-conflict
                         (render-conflict adapter on-conflict conflict-target cols)))
         (sql (format nil "INSERT INTO ~a (~{~a~^, ~}) VALUES (~{~a~^, ~})~@[~a~]"
                      (qi adapter table)
                      (mapcar (lambda (c) (qi adapter c)) cols)
                      placeholders
                      conflict-sql)))
    (values sql (nreverse (sql-state-params st)))))

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
  (format nil "~{~a~^, ~}"
          (mapcar (lambda (c)
                    (format nil "~a = excluded.~a"
                            (qi adapter c) (sqlify-column c)))
                  cols)))

(defun insert-all-sql (adapter table rows)
  "Compile a multi-row INSERT. ROWS is a list of plists. All rows must
share the same column set; column order is taken from the first row."
  (let* ((st (make-sql-state :adapter adapter))
         (cols (loop for (k v) on (first rows) by #'cddr collect k))
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

(defun update-sql (adapter table set-plist where-expr)
  (let* ((st (make-sql-state :adapter adapter))
         (set-pairs
           (loop for (k v) on set-plist by #'cddr
                 collect (format nil "~a = ~a"
                                 (qi adapter k)
                                 (emit-param st v))))
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

(defun to-sql (adapter q)
  "Convenience entry point for SELECT compilation."
  (select-sql adapter q))
