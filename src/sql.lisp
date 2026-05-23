(in-package #:clecto)

;;; AST -> SQL string + params. Dialect specifics (quoting, placeholders)
;;; are delegated to the adapter. The compiler itself is pure.
;;;
;;; Facade: shared state struct + helpers used by every sub-compiler.

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

(defun join-strings (items sep)
  (with-output-to-string (s)
    (loop for (x . rest) on items
          do (write-string x s)
          when rest do (write-string sep s))))

(defun to-sql (adapter q)
  "Convenience entry point for SELECT compilation."
  (select-sql adapter q))
