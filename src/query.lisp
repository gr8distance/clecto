(in-package #:clecto)

;;; Query is data — a plist holding an AST. Builders return fresh queries.
;;;
;;;   (-> (from :users)
;;;       (where '(= :age 20))
;;;       (where '(like :email "%@example.com"))
;;;       (select '(:id :email))
;;;       (order-by '((:asc :id)))
;;;       (limit 10))
;;;
;;; Where-expressions are S-expressions:
;;;   (= :col value)  (<> :col value)  (< :col value) ...
;;;   (in :col (1 2 3))   (is-null :col)   (like :col "pat%")
;;;   (and EXPR EXPR ...)   (or EXPR EXPR ...)   (not EXPR)

(defstruct subquery
  (query nil)
  (alias nil :type keyword))

(defun subquery (q &key (alias :sub))
  "Wrap a query so it can be used as a from-source or where-in argument."
  (make-subquery :query q :alias alias))

(defstruct query
  (ctes    nil :type list)   ; list of (NAME INNER-QUERY)
  (table   nil)              ; keyword, string, or SUBQUERY
  (wheres  nil :type list)
  (selects nil :type list)   ; nil = SELECT *
  (orders  nil :type list)   ; list of (:asc :col) / (:desc :col)
  (joins   nil :type list)   ; list of (:kind K :table T :on EXPR)
  (groups  nil :type list)   ; list of column refs
  (havings nil :type list)   ; list of where-exprs
  (distinct nil)            ; nil, t, or list of columns (DISTINCT ON)
  (combinators nil :type list)   ; ((:union Q) (:intersect Q) ...)
  (lock    nil)             ; :for-update / :for-share / etc
  (prefix  nil)             ; string: schema or db prefix
  (limit   nil)
  (offset  nil))

(defun copy-q (q &rest overrides)
  (let ((c (copy-query q)))
    (loop for (slot val) on overrides by #'cddr do
      (ecase slot
        (:ctes    (setf (query-ctes c) val))
        (:table   (setf (query-table c) val))
        (:wheres  (setf (query-wheres c) val))
        (:selects (setf (query-selects c) val))
        (:orders  (setf (query-orders c) val))
        (:joins   (setf (query-joins c) val))
        (:groups  (setf (query-groups c) val))
        (:havings (setf (query-havings c) val))
        (:distinct (setf (query-distinct c) val))
        (:combinators (setf (query-combinators c) val))
        (:lock    (setf (query-lock c) val))
        (:prefix  (setf (query-prefix c) val))
        (:limit   (setf (query-limit c) val))
        (:offset  (setf (query-offset c) val))))
    c))

(defun from (table)
  (make-query :table table))

(defun where (q expr)
  (copy-q q :wheres (append (query-wheres q) (list expr))))

(defun select (q fields)
  (copy-q q :selects (alexandria:ensure-list fields)))

(defun order-by (q specs)
  (copy-q q :orders (append (query-orders q) specs)))

(defun limit (q n)
  (copy-q q :limit n))

(defun offset (q n)
  (copy-q q :offset n))

(defun join (q kind table on)
  "Add a JOIN clause. KIND is :inner, :left, :right, or :full.
ON is a where-expression."
  (copy-q q :joins (append (query-joins q)
                           (list (list :kind kind :table table :on on)))))

(defun group-by (q cols)
  (copy-q q :groups (append (query-groups q) (alexandria:ensure-list cols))))

(defun having (q expr)
  (copy-q q :havings (append (query-havings q) (list expr))))

(defun union (q other)
  (copy-q q :combinators (append (query-combinators q) (list (list :union other)))))

(defun union-all (q other)
  (copy-q q :combinators (append (query-combinators q) (list (list :union-all other)))))

(defun intersect (q other)
  (copy-q q :combinators (append (query-combinators q) (list (list :intersect other)))))

(defun except (q other)
  (copy-q q :combinators (append (query-combinators q) (list (list :except other)))))

(defun where-if (q condition expr)
  "Apply WHERE only when CONDITION is truthy. Lets you compose dynamic
filters without an outer if/cond:

  (-> (from :users)
      (where-if min-age `(>= :age ,min-age))
      (where-if role    `(= :role ,role)))"
  (if condition (where q expr) q))

(defun and-filters (&rest exprs)
  "AND-combine zero or more filter expressions, skipping nils.
Returns nil when nothing remains, the single expr when only one, otherwise
an (and ...) form. Pairs naturally with WHERE."
  (let ((non-null (remove nil exprs)))
    (cond
      ((null non-null) nil)
      ((null (cdr non-null)) (first non-null))
      (t (cons 'and non-null)))))

(defun lock (q kind)
  "Add a locking clause. KIND is typically :for-update or :for-share."
  (copy-q q :lock kind))

(defun with-prefix (q prefix)
  "Set a schema/db prefix so the from-table renders as PREFIX.table."
  (copy-q q :prefix prefix))

(defun with-cte (q name inner)
  "Prepend a CTE: WITH NAME AS (INNER) ..."
  (copy-q q :ctes (append (query-ctes q) (list (list name inner)))))

(defun distinct (q &optional (on t))
  "Make the query SELECT DISTINCT. ON is T for plain DISTINCT, or a column
keyword / list of keywords for DISTINCT ON (Postgres)."
  (copy-q q :distinct on))
