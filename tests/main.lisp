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

;;; --- fragment escape hatch ---

(defschema fr-user "fr_users"
  (:id    :integer :primary-key t)
  (:email :string))

(test fragment
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE fr_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-insert r (cast 'fr-user '(:email "AbC@Example") '(:email)))
           ;; case-insensitive match via raw SQL
           (let ((u (repo-one r
                              (where (from :fr-users)
                                     '(:fragment "lower(?) = ?" :email "abc@example")))))
             (is (equal "AbC@Example" (getf u :email))))
           ;; fragment in select
           (let* ((row (repo-one r
                                 (select (from :fr-users)
                                         '((:fragment "upper(?)" :email)))))
                  (vals (loop for (k v) on row by #'cddr collect v)))
             (is (equal "ABC@EXAMPLE" (first vals)))))
      (sqlite-close a))))

;;; --- joins / group-by / having / aggregates ---

(defschema j-user "j_users"
  (:id    :integer :primary-key t)
  (:email :string))

(defschema j-post "j_posts"
  (:id      :integer :primary-key t)
  (:title   :string)
  (:user-id :integer))

(test joins-and-aggregates
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE j_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-execute r "CREATE TABLE j_posts (id INTEGER PRIMARY KEY, title TEXT, user_id INTEGER)")
           (repo-insert-all r 'j-user '((:email "a@b") (:email "c@d")))
           (repo-insert-all r 'j-post '((:title "p1" :user-id 1)
                                        (:title "p2" :user-id 1)
                                        (:title "p3" :user-id 2)))
           ;; INNER JOIN
           (let ((rows (repo-all r
                                 (-> (from :j-users)
                                     (join :inner :j-posts
                                           '(= :j-users.id :j-posts.user-id))
                                     (select '(:j-users.email :j-posts.title))))))
             (is (= 3 (length rows))))
           ;; COUNT — returned under SQLite's auto-named column
           (let* ((row (repo-one r (select (from :j-posts) '((:count :id)))))
                  (vals (loop for (k v) on row by #'cddr collect v)))
             (is (= 3 (first vals))))
           ;; GROUP BY + HAVING + aggregate
           (let ((rows (repo-all r
                                 (-> (from :j-posts)
                                     (group-by :user-id)
                                     (having '(> (:count :id) 1))
                                     (select '(:user-id (:count :id)))))))
             (is (= 1 (length rows)))
             (is (= 1 (getf (first rows) :user-id)))))
      (sqlite-close a))))

;;; --- constraint errors -> changeset errors ---

(defschema cn-user "cn_users"
  (:id    :integer :primary-key t)
  (:email :string))

(defschema cn-post "cn_posts"
  (:id      :integer :primary-key t)
  (:user-id :integer)
  (:title   :string))

(test unique-constraint-translation
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE cn_users (id INTEGER PRIMARY KEY, email TEXT UNIQUE)")
           (repo-insert r (cast 'cn-user '(:email "a@b") '(:email)))
           (let* ((cs (-> (cast 'cn-user '(:email "a@b") '(:email))
                          (unique-constraint :email :message "already taken"))))
             (multiple-value-bind (rec err) (repo-insert r cs)
               (is (null rec))
               (is (not (cs-valid-p err)))
               (is (equal "already taken"
                          (cdr (assoc :email (cs-errors err))))))))
      (sqlite-close a))))

(test foreign-key-constraint-translation
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "PRAGMA foreign_keys = ON")
           (repo-execute r "CREATE TABLE cn_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-execute r "CREATE TABLE cn_posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES cn_users(id), title TEXT)")
           (let* ((cs (-> (cast 'cn-post '(:user-id 999 :title "x") '(:user-id :title))
                          (foreign-key-constraint :user-id :message "owner missing"))))
             (multiple-value-bind (rec err) (repo-insert r cs)
               (is (null rec))
               (is (equal "owner missing"
                          (cdr (assoc :user-id (cs-errors err))))))))
      (sqlite-close a))))

(test unmatched-constraint-reraises
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE cn_users (id INTEGER PRIMARY KEY, email TEXT UNIQUE)")
           (repo-insert r (cast 'cn-user '(:email "a@b") '(:email)))
           ;; cs has no declared constraint -> raw error escapes
           (signals error
             (repo-insert r (cast 'cn-user '(:email "a@b") '(:email)))))
      (sqlite-close a))))

;;; --- upsert ---

(defschema up-user "up_users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test upsert
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE up_users (id INTEGER PRIMARY KEY, email TEXT UNIQUE, age INTEGER)")
           (repo-insert r (cast 'up-user '(:email "a@b" :age 20) '(:email :age)))
           ;; :nothing on a colliding email is a no-op
           (repo-insert r (cast 'up-user '(:email "a@b" :age 99) '(:email :age))
                        :on-conflict :nothing :conflict-target :email)
           (is (= 20 (getf (repo-get-by r 'up-user '(:email "a@b")) :age)))
           ;; :replace overrides
           (repo-insert r (cast 'up-user '(:email "a@b" :age 99) '(:email :age))
                        :on-conflict :replace :conflict-target :email)
           (is (= 99 (getf (repo-get-by r 'up-user '(:email "a@b")) :age)))
           ;; partial replace: only :age
           (repo-insert r (cast 'up-user '(:email "a@b" :age 1) '(:email :age))
                        :on-conflict '(:replace :age) :conflict-target :email)
           (is (= 1 (getf (repo-get-by r 'up-user '(:email "a@b")) :age))))
      (sqlite-close a))))

;;; --- transactions ---

(defschema tx-user "tx_users"
  (:id    :integer :primary-key t)
  (:email :string))

(test transaction-commit
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE tx_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-transaction (r)
             (repo-insert r (cast 'tx-user '(:email "a@b") '(:email)))
             (repo-insert r (cast 'tx-user '(:email "c@d") '(:email))))
           (is (= 2 (length (repo-all r (from :tx-users))))))
      (sqlite-close a))))

(test transaction-rollback-on-error
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE tx_users (id INTEGER PRIMARY KEY, email TEXT)")
           (handler-case
               (repo-transaction (r)
                 (repo-insert r (cast 'tx-user '(:email "a@b") '(:email)))
                 (error "boom"))
             (error () nil))
           (is (= 0 (length (repo-all r (from :tx-users))))))
      (sqlite-close a))))

(test transaction-explicit-rollback
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE tx_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-transaction (r)
             (repo-insert r (cast 'tx-user '(:email "a@b") '(:email)))
             (clecto:rollback))
           (is (= 0 (length (repo-all r (from :tx-users))))))
      (sqlite-close a))))

(test transaction-nested-savepoint
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE tx_users (id INTEGER PRIMARY KEY, email TEXT)")
           (repo-transaction (r)
             (repo-insert r (cast 'tx-user '(:email "outer") '(:email)))
             (handler-case
                 (repo-transaction (r)
                   (repo-insert r (cast 'tx-user '(:email "inner") '(:email)))
                   (error "inner fail"))
               (error () nil)))
           ;; outer kept, inner rolled back
           (let ((rows (repo-all r (from :tx-users))))
             (is (= 1 (length rows)))
             (is (equal "outer" (getf (first rows) :email)))))
      (sqlite-close a))))

;;; --- bulk: insert-all / update-all / delete-all ---

(defschema bulk-user "bulk_users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test bulk-operations
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE bulk_users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER)")
           (is (= 3 (repo-insert-all r 'bulk-user
                                     '((:email "a@b" :age 10)
                                       (:email "c@d" :age 20)
                                       (:email "e@f" :age 30)))))
           (is (= 3 (length (repo-all r (from :bulk-users)))))
           ;; update-all
           (is (= 2 (repo-update-all r (where (from :bulk-users) '(>= :age 20))
                                     '(:age 99))))
           (is (= 1 (length (repo-all r (where (from :bulk-users) '(= :age 10))))))
           (is (= 2 (length (repo-all r (where (from :bulk-users) '(= :age 99))))))
           ;; delete-all
           (is (= 2 (repo-delete-all r (where (from :bulk-users) '(= :age 99)))))
           (is (= 1 (length (repo-all r (from :bulk-users))))))
      (sqlite-close a))))

;;; --- get-by / exists? ---

(defschema gb-user "gb_users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test get-by-and-exists
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE gb_users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER)")
           (repo-insert r (cast 'gb-user '(:email "a@b" :age 20) '(:email :age)))
           (repo-insert r (cast 'gb-user '(:email "c@d" :age 30) '(:email :age)))
           (let ((u (repo-get-by r 'gb-user '(:email "c@d"))))
             (is (= 30 (getf u :age))))
           (let ((u (repo-get-by r 'gb-user '(:email "missing"))))
             (is (null u)))
           (is (repo-exists-p r (where (from :gb-users) '(= :email "a@b"))))
           (is (not (repo-exists-p r (where (from :gb-users) '(= :email "no"))))))
      (sqlite-close a))))

;;; --- timestamps + extended types ---

(defschema ts-user "ts_users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:timestamps))

(test schema-timestamps
  (let ((s (find-schema 'ts-user)))
    (is (schema-timestamps-p s))
    (is (find :inserted-at (schema-fields s) :key #'field-name))
    (is (find :updated-at (schema-fields s) :key #'field-name))))

(test timestamps-roundtrip
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE ts_users (id INTEGER PRIMARY KEY, email TEXT, inserted_at TEXT, updated_at TEXT)")
           (let ((rec (nth-value 0 (repo-insert r (cast 'ts-user '(:email "a@b") '(:email))))))
             (is (stringp (getf rec :inserted-at)))
             (is (stringp (getf rec :updated-at)))
             (is (equal (getf rec :inserted-at) (getf rec :updated-at))))
           (sleep 1)
           ;; update should bump updated-at but not inserted-at
           (let* ((row (repo-get r 'ts-user 1))
                  (cs  (put-change
                        (cast (list* :__schema__ 'ts-user row) '() '())
                        :email "c@d"))
                  (updated (nth-value 0 (repo-update r cs))))
             (is (not (equal (getf updated :updated-at)
                             (getf row :updated-at))))
             (is (equal (getf updated :inserted-at)
                        (getf row :inserted-at)))))
      (sqlite-close a))))

(test cast-extended-types
  (is (equal "2026-05-23" (nth-value 0 (clecto::cast-value "2026-05-23" :date))))
  (is (equal "2026-05-23 12:34:56"
             (nth-value 0 (clecto::cast-value "2026-05-23 12:34:56" :naive-datetime))))
  (is (= 3/4 (nth-value 0 (clecto::cast-value "3/4" :decimal))))
  (let ((u (generate-uuid)))
    (is (= 36 (length u)))
    (is (char= #\- (char u 8)))))

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
