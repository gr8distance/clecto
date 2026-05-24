(in-package #:clecto)

;;; Expression compiler: operators, aggregates, fragments, operands.

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

(defparameter *fragment-template-cap* 4096
  "Maximum length accepted for a fragment template. Fragment templates
are by contract developer constants — real-world uses (atomic
counters, lower(), coalesce(), JSON extracts) are all well under
1 KB. A 4 KB cap is a generous backstop that still catches
accidental threading of unbounded user input.

Raise this only if a legitimate template genuinely needs to be
larger; lowering it further (e.g. 1024) tightens the catch.")

(defun compile-fragment (st form)
  "Expand (:fragment \"sql with ? holes\" arg1 arg2 ...) — each ? is
replaced by its arg compiled as an operand (column refs inline, other
values become parameters)."
  (let ((tmpl (second form)))
    (check-type tmpl string)
    (when (> (length tmpl) *fragment-template-cap*)
      (error "fragment template length ~d exceeds *fragment-template-cap* (~d)"
             (length tmpl) *fragment-template-cap*))
    (let ((args (cddr form))
          (idx  0))
      (with-output-to-string (s)
        (loop for c across tmpl do
          (cond
            ((char= c #\?)
             (write-string (compile-operand st (nth idx args)) s)
             (incf idx))
            (t (write-char c s))))))))

(defun compile-column-or-aggregate (st x)
  "Return SQL for a column ref, aggregate, or fragment. NIL if X is none."
  (cond
    ((keywordp x) (qi (sql-state-adapter st) x))
    ((aggregate-form-p x) (compile-aggregate (sql-state-adapter st) x))
    ((fragment-form-p x)  (compile-fragment st x))))

(defun compile-operand (st x)
  "Column ref / aggregate / fragment, falling back to a parameter."
  (or (compile-column-or-aggregate st x)
      (emit-param st x)))

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
          (let ((col (second expr))
                (rhs (third expr)))
            (cond
              ((subquery-p rhs)
               (format nil "~a IN (~a)"
                       (qi (sql-state-adapter st) col)
                       (emit-select st (subquery-query rhs))))
              ((listp rhs)
               (let ((placeholders (mapcar (lambda (v) (emit-param st v)) rhs)))
                 (format nil "~a IN (~{~a~^, ~})"
                         (qi (sql-state-adapter st) col)
                         placeholders)))
              (t
               (error "IN expects a list or subquery on the right, got: ~s" rhs)))))
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
