;;; A tiny end-to-end example. Run with:
;;;   sbcl --load ~/quicklisp/setup.lisp --load examples/users.lisp

(ql:quickload :clecto :silent t)

(defpackage #:clecto-example
  (:use #:cl #:clecto))
(in-package #:clecto-example)

(defmacro -> (init &body forms)
  (reduce (lambda (acc f)
            (if (consp f) (list* (car f) acc (cdr f)) (list f acc)))
          forms :initial-value init))

(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(defparameter *repo* (make-repo (make-sqlite-adapter ":memory:")))

(repo-execute *repo*
  "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER)")

;; Insert via a validated changeset (the pipeline IS the validation).
(defun new-user (attrs)
  (-> (cast 'user attrs '(:email :age))
      (validate-required '(:email))
      (validate-format :email "@")
      (validate-number :age :>= 0)))

(multiple-value-bind (rec err) (repo-insert *repo* (new-user '(:email "a@b" :age 20)))
  (format t "inserted: ~a (err: ~a)~%" rec err))

(multiple-value-bind (rec err) (repo-insert *repo* (new-user '(:email "bad" :age -1)))
  (format t "rejected: ~a / errors: ~a~%" rec (cs-errors err)))

;; Compose queries by piping through builders.
(format t "all over 18: ~a~%"
        (repo-all *repo*
                  (-> (from :users)
                      (where '(>= :age 18))
                      (order-by '((:asc :id))))))
