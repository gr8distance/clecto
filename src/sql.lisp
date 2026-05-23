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

(defun compile-expr (st expr)
  "Compile a where-expression to SQL string, accumulating params into ST."
  (cond
    ((or (null expr) (eq expr t))
     (if expr "1=1" "1=0"))
    ((not (consp expr))
     ;; literal value
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
                  (qi (sql-state-adapter st) (second expr))
                  op-name
                  (emit-param st (third expr))))
         (t (error "Unknown where operator: ~a" (first expr))))))))

(defun join-strings (items sep)
  (with-output-to-string (s)
    (loop for (x . rest) on items
          do (write-string x s)
          when rest do (write-string sep s))))

;;; --- SELECT ---

(defun select-sql (adapter q)
  "Compile a QUERY into (values sql params)."
  (let* ((st (make-sql-state :adapter adapter))
         (cols (if (query-selects q)
                   (format nil "~{~a~^, ~}"
                           (mapcar (lambda (c) (qi adapter c)) (query-selects q)))
                   "*"))
         (where-sql
           (when (query-wheres q)
             (let ((parts (mapcar (lambda (e) (compile-expr st e))
                                  (query-wheres q))))
               (format nil " WHERE ~{~a~^ AND ~}" parts))))
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
         (sql (format nil "SELECT ~a FROM ~a~@[~a~]~@[~a~]~@[~a~]~@[~a~]"
                      cols
                      (qi adapter (query-table q))
                      where-sql order-sql limit-sql offset-sql)))
    (values sql (nreverse (sql-state-params st)))))

;;; --- INSERT / UPDATE / DELETE ---

(defun insert-sql (adapter table values-plist)
  (let* ((st (make-sql-state :adapter adapter))
         (cols (loop for (k v) on values-plist by #'cddr collect k))
         (vals (loop for (k v) on values-plist by #'cddr collect v))
         (placeholders (mapcar (lambda (v) (emit-param st v)) vals))
         (sql (format nil "INSERT INTO ~a (~{~a~^, ~}) VALUES (~{~a~^, ~})"
                      (qi adapter table)
                      (mapcar (lambda (c) (qi adapter c)) cols)
                      placeholders)))
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
