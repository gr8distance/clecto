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

(defstruct query
  (table   nil)              ; keyword or string
  (wheres  nil :type list)
  (selects nil :type list)   ; nil = SELECT *
  (orders  nil :type list)   ; list of (:asc :col) / (:desc :col)
  (joins   nil :type list)   ; list of (:kind K :table T :on EXPR)
  (groups  nil :type list)   ; list of column refs
  (havings nil :type list)   ; list of where-exprs
  (limit   nil)
  (offset  nil))

(defun copy-q (q &rest overrides)
  (let ((c (copy-query q)))
    (loop for (slot val) on overrides by #'cddr do
      (ecase slot
        (:table   (setf (query-table c) val))
        (:wheres  (setf (query-wheres c) val))
        (:selects (setf (query-selects c) val))
        (:orders  (setf (query-orders c) val))
        (:joins   (setf (query-joins c) val))
        (:groups  (setf (query-groups c) val))
        (:havings (setf (query-havings c) val))
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
