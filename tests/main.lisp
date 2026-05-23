(defpackage #:clecto/tests
  (:use #:cl #:clecto #:fiveam))
(in-package #:clecto/tests)

(def-suite :clecto)
(in-suite :clecto)

(defmacro -> (init &body forms)
  "Thread-first: insert ACC as the first argument after the function name."
  (reduce (lambda (acc f)
            (if (consp f) (list* (car f) acc (cdr f)) (list f acc)))
          forms :initial-value init))

;;; --- schema + cast ---

(defschema test-user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test cast-and-validate
  (let ((cs (cast 'test-user '(:email "a@b" :age "20" :nope "x")
                  '(:email :age))))
    (is (cs-valid-p cs))
    (is (equal "a@b" (get-change cs :email)))
    (is (equal 20    (get-change cs :age)))    ; cast from string
    (is (null (get-change cs :nope))))         ; not in allowed
  (let ((cs (-> (cast 'test-user '(:email "" :age 20) '(:email :age))
                (validate-required '(:email))
                (validate-format :email "@"))))
    (is (not (cs-valid-p cs)))
    (is (assoc :email (cs-errors cs)))))

(test put-change-and-get-field
  (let* ((cs (cast 'test-user '(:email "a@b") '(:email :age)))
         (cs2 (put-change cs :age 99)))
    (is (= 99 (get-field cs2 :age)))))

(test validate-number
  (let ((cs (validate-number
             (cast 'test-user '(:age -1) '(:age))
             :age :>= 0)))
    (is (not (cs-valid-p cs)))))

;;; --- query + sql ---

(defclass dummy-adapter (clecto:adapter) ())
(defmethod adapter-execute ((a dummy-adapter) sql params)
  (list (list :sql sql :params params)))
(defmethod adapter-last-insert-id ((a dummy-adapter)) 0)

(test select-sql
  (let ((a (make-instance 'dummy-adapter))
        (q (limit (where (select (from :users) '(:id :email))
                         '(= :id 1))
                  10)))
    (multiple-value-bind (sql params) (clecto::select-sql a q)
      (is (search "SELECT \"id\", \"email\" FROM \"users\"" sql))
      (is (search "WHERE \"id\" = ?" sql))
      (is (search "LIMIT 10" sql))
      (is (equal '(1) params)))))

(test compound-where
  (let* ((a (make-instance 'dummy-adapter))
         (q (where (from :users) '(and (= :age 20) (in :id (1 2 3))))))
    (multiple-value-bind (sql params) (clecto::select-sql a q)
      (is (search "\"age\" = ? AND \"id\" IN (?, ?, ?)" sql))
      (is (equal '(20 1 2 3) params)))))

(test insert-sql
  (let ((a (make-instance 'dummy-adapter)))
    (multiple-value-bind (sql params)
        (clecto::insert-sql a :users '(:email "a@b" :age 20))
      (is (search "INSERT INTO \"users\" (\"email\", \"age\") VALUES (?, ?)" sql))
      (is (equal '("a@b" 20) params)))))

(test update-sql
  (let ((a (make-instance 'dummy-adapter)))
    (multiple-value-bind (sql params)
        (clecto::update-sql a :users '(:age 21) '(= :id 5))
      (is (search "UPDATE \"users\" SET \"age\" = ?" sql))
      (is (search "WHERE \"id\" = ?" sql))
      (is (equal '(21 5) params)))))

;;; --- integration: real SQLite roundtrip ---

(defschema int-user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test sqlite-roundtrip
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER)")
           ;; insert
           (let ((cs (cast 'int-user '(:email "a@b" :age 20) '(:email :age))))
             (multiple-value-bind (rec err) (repo-insert r cs)
               (is (null err))
               (is (= 1 (getf rec :id)))
               (is (equal "a@b" (getf rec :email)))))
           ;; second insert
           (repo-insert r (cast 'int-user '(:email "c@d" :age 30) '(:email :age)))
           ;; all
           (let ((rows (repo-all r (from :users))))
             (is (= 2 (length rows))))
           ;; filtered
           (let ((row (repo-one r (where (from :users) '(= :email "c@d")))))
             (is (equal "c@d" (getf row :email)))
             (is (= 30 (getf row :age))))
           ;; update via changeset
           (let* ((existing (repo-get r 'int-user 1))
                  (existing+ (list* :__schema__ 'int-user existing))
                  (cs (put-change (cast existing+ '() '()) :age 99)))
             (repo-update r cs))
           (is (= 99 (getf (repo-get r 'int-user 1) :age)))
           ;; delete
           (repo-delete r 'int-user 2)
           (is (= 1 (length (repo-all r (from :users))))))
      (sqlite-close a))))

;;; --- associations / preload ---

(defschema assoc-user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:posts :has-many assoc-post :foreign-key :user-id)
  (:bio   :has-one  assoc-bio  :foreign-key :user-id))

(defschema assoc-post "posts"
  (:id      :integer :primary-key t)
  (:title   :string)
  (:user-id :integer)
  (:author  :belongs-to assoc-user :foreign-key :user-id))

(defschema assoc-bio "bios"
  (:id      :integer :primary-key t)
  (:user-id :integer)
  (:text    :string))

(test schema-parses-associations
  (let ((s (find-schema 'assoc-user)))
    (is (= 2 (length (schema-assocs s))))
    (let ((a (schema-assoc s :posts)))
      (is (eq :has-many (association-kind a)))
      (is (eq 'assoc-post (association-target a)))
      (is (eq :user-id (association-foreign-key a))))))

(test preload-roundtrip
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-execute r "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, user_id INTEGER)")
           (repo-execute r "CREATE TABLE bios  (id INTEGER PRIMARY KEY, user_id INTEGER, text TEXT)")
           (repo-insert r (cast 'assoc-user '(:email "a@b") '(:email)))
           (repo-insert r (cast 'assoc-user '(:email "c@d") '(:email)))
           (dolist (p '((:title "p1" :user-id 1)
                        (:title "p2" :user-id 1)
                        (:title "p3" :user-id 2)))
             (repo-insert r (cast 'assoc-post p '(:title :user-id))))
           (repo-insert r (cast 'assoc-bio '(:user-id 1 :text "hi") '(:user-id :text)))
           ;; has-many on list
           (let* ((users (repo-all r (from :users)))
                  (with-posts (repo-preload r 'assoc-user users :posts)))
             (is (= 2 (length with-posts)))
             (is (= 2 (length (getf (first with-posts) :posts))))
             (is (= 1 (length (getf (second with-posts) :posts)))))
           ;; has-one
           (let ((with-bio (repo-preload r 'assoc-user
                                         (repo-get r 'assoc-user 1)
                                         :bio)))
             (is (equal "hi" (getf (getf with-bio :bio) :text))))
           ;; belongs-to
           (let* ((posts (repo-all r (from :posts)))
                  (with-author (repo-preload r 'assoc-post posts :author)))
             (is (every (lambda (p) (getf p :author)) with-author))
             (is (equal "a@b"
                        (getf (getf (first with-author) :author) :email))))
           ;; multiple at once
           (let ((u (repo-preload r 'assoc-user
                                  (repo-get r 'assoc-user 1)
                                  '(:posts :bio))))
             (is (= 2 (length (getf u :posts))))
             (is (equal "hi" (getf (getf u :bio) :text)))))
      (sqlite-close a))))
