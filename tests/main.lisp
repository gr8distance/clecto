(defpackage #:clecto/tests
  (:use #:cl #:clecto #:fiveam)
  (:shadowing-import-from #:clecto #:union #:intersection #:set-difference))
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

;;; --- telemetry ---

(defschema tel-row "tel"
  (:id :integer :primary-key t)
  (:n  :integer))

(test telemetry-fires-on-query
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a))
         (events nil)
         (clecto:*telemetry*
           (lambda (event payload)
             (push (list event (getf payload :sql)) events))))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE tel (id INTEGER PRIMARY KEY, n INTEGER)")
           (repo-insert r (cast 'tel-row '(:n 1) '(:n)))
           (repo-all r (from :tel))
           (is (some (lambda (e) (eq (first e) :query)) events))
           (is (some (lambda (e) (search "SELECT" (second e))) events)))
      (sqlite-close a))))

(test telemetry-fires-on-error
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a))
         (events nil)
         (clecto:*telemetry*
           (lambda (event payload) (push (list event payload) events))))
    (unwind-protect
         (signals error (repo-execute r "SELECT bogus FROM nope"))
      (sqlite-close a))
    (is (some (lambda (e) (eq (first e) :error)) events))))

;;; --- postgres adapter SQL emission (no live DB required) ---

(defclass mock-pg-adapter (clecto:adapter) ())
(defmethod adapter-quote-identifier ((a mock-pg-adapter) name)
  (multiple-value-bind (q c) (clecto::split-qualified name)
    (if q (format nil "\"~a\".\"~a\""
                  (clecto::escape-identifier-body q)
                  (clecto::escape-identifier-body c))
          (format nil "\"~a\"" (clecto::escape-identifier-body c)))))
(defmethod adapter-placeholder ((a mock-pg-adapter) index)
  (format nil "$~a" index))
(defmethod adapter-supports-returning-p ((a mock-pg-adapter)) t)

(test postgres-style-placeholders-and-returning
  (let ((a (make-instance 'mock-pg-adapter)))
    ;; placeholders are $N
    (multiple-value-bind (sql params)
        (clecto::select-sql a (where (from :users) '(= :id 1)))
      (is (search "\"id\" = $1" sql))
      (is (equal '(1) params)))
    ;; insert with RETURNING is emitted
    (multiple-value-bind (sql params)
        (clecto::insert-sql a :users '(:email "a@b") :returning t)
      (declare (ignore params))
      (is (search "RETURNING *" sql)))
    ;; RETURNING with explicit columns
    (multiple-value-bind (sql params)
        (clecto::insert-sql a :users '(:email "a@b") :returning '(:id :email))
      (declare (ignore params))
      (is (search "RETURNING \"id\", \"email\"" sql)))))

;;; --- security guards ---

(test safe-number-parsing-rejects-reader-injection
  ;; The reader macro #. would evaluate at parse time on the old impl.
  ;; safe-parse-number must reject it without side effects.
  (is (null (nth-value 1 (clecto::safe-parse-number "#.(error \"boom\")"))))
  (is (null (nth-value 1 (clecto::safe-parse-number "(+ 1 2)"))))
  (is (null (nth-value 1 (clecto::safe-parse-number "1.2.3"))))
  (is (= 3.14d0 (nth-value 0 (clecto::safe-parse-number "3.14"))))
  (is (= 100   (nth-value 0 (clecto::safe-parse-number "1e2")))))

(test identifier-quoting-escapes-and-rejects-nul
  (let ((a (make-sqlite-adapter ":memory:")))
    (unwind-protect
         (progn
           ;; embedded " is doubled
           (is (equal "\"weird\"\"col\""
                      (adapter-quote-identifier a "weird\"col")))
           ;; NUL byte is rejected
           (signals error
             (adapter-quote-identifier a (format nil "x~ay" #\Nul))))
      (sqlite-close a))))

(test limit-rejects-non-integer
  (let ((a (make-sqlite-adapter ":memory:"))
        (q (limit (from :users) "1 OR 1=1")))
    (unwind-protect
         (signals error (clecto::select-sql a q))
      (sqlite-close a))))

(test order-by-direction-whitelist
  (let ((a (make-sqlite-adapter ":memory:"))
        (q (order-by (from :users) '((:asc--malicious :id)))))
    (unwind-protect
         (signals error (clecto::select-sql a q))
      (sqlite-close a))))

(test lock-mode-whitelist
  (let ((a (make-sqlite-adapter ":memory:"))
        (q (lock (from :users) :boguslock)))
    (unwind-protect
         (signals error (clecto::select-sql a q))
      (sqlite-close a))))

;;; --- dynamic filters (where-if / and-filters) ---

(defschema d-prod "d_prods"
  (:id    :integer :primary-key t)
  (:price :integer)
  (:tag   :string))

(test dynamic-filters
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE d_prods (id INTEGER PRIMARY KEY, price INTEGER, tag TEXT)")
           (repo-insert-all r 'd-prod '((:price 100 :tag "a")
                                        (:price 200 :tag "a")
                                        (:price 300 :tag "b")))
           ;; conditional where via where-if
           (let* ((min  150)
                  (tag  nil)
                  (q (-> (from :d-prods)
                         (where-if min  `(>= :price ,min))
                         (where-if tag  `(= :tag ,tag)))))
             (is (= 2 (length (repo-all r q)))))
           ;; and-filters combine
           (let* ((filter (and-filters '(>= :price 150) '(= :tag "a"))))
             (is (= 1 (length (repo-all r (where (from :d-prods) filter))))))
           ;; and-filters with nils -> skip
           (is (null (and-filters nil nil)))
           (is (equal '(= :x 1) (and-filters nil '(= :x 1) nil))))
      (sqlite-close a))))

;;; --- lock / prefix (SQL emission only) ---

(test lock-and-prefix-sql
  (let* ((a (make-sqlite-adapter ":memory:"))
         (q1 (lock (from :users) :for-update))
         (q2 (with-prefix (from :users) "tenant_a")))
    (unwind-protect
         (progn
           (multiple-value-bind (sql params) (clecto::select-sql a q1)
             (declare (ignore params))
             (is (search "FOR UPDATE" sql)))
           (multiple-value-bind (sql params) (clecto::select-sql a q2)
             (declare (ignore params))
             (is (search "FROM \"tenant_a\".\"users\"" sql))))
      (sqlite-close a))))

;;; --- union / intersect / except ---

(defschema set-row "set_t"
  (:n :integer))

(test set-operations
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE set_t (n INTEGER)")
           (repo-insert-all r 'set-row '((:n 1) (:n 2) (:n 3)))
           (let* ((q1 (select (where (from :set-t) '(<= :n 2)) '(:n)))
                  (q2 (select (where (from :set-t) '(>= :n 2)) '(:n))))
             ;; UNION (dedup): {1, 2} ∪ {2, 3} = {1, 2, 3}
             (is (= 3 (length (repo-all r (clecto:union q1 q2)))))
             ;; UNION ALL: keeps duplicates
             (is (= 4 (length (repo-all r (union-all q1 q2)))))
             ;; INTERSECT: {2}
             (is (= 1 (length (repo-all r (intersect q1 q2)))))
             ;; EXCEPT: {1, 2} − {2, 3} = {1}
             (is (= 1 (length (repo-all r (except q1 q2)))))))
      (sqlite-close a))))

;;; --- distinct / subquery / CTE ---

(defschema d-user "d_users"
  (:id   :integer :primary-key t)
  (:role :string))

(test distinct-and-subquery-and-cte
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE d_users (id INTEGER PRIMARY KEY, role TEXT)")
           (repo-insert-all r 'd-user '((:role "admin") (:role "admin") (:role "user")))
           ;; DISTINCT
           (let ((rows (repo-all r (distinct (select (from :d-users) '(:role))))))
             (is (= 2 (length rows))))
           ;; subquery in FROM
           (let* ((inner (select (from :d-users) '(:role)))
                  (rows  (repo-all r (from (subquery inner :alias :s)))))
             (is (= 3 (length rows))))
           ;; subquery in WHERE IN
           (let* ((inner (select (where (from :d-users) '(= :role "admin")) '(:id)))
                  (rows  (repo-all r (where (from :d-users) (list 'in :id (subquery inner))))))
             (is (= 2 (length rows))))
           ;; CTE
           (let* ((cte-q (from :d-users))
                  (main  (with-cte (from :cte-users) :cte-users cte-q))
                  (rows  (repo-all r main)))
             (is (= 3 (length rows)))))
      (sqlite-close a))))

;;; --- embeds + cast-embed / cast-assoc ---

(defschema em-address "addresses"
  (:street :string)
  (:city   :string))

(defschema em-user "em_users"
  (:id      :integer :primary-key t)
  (:email   :string)
  (:address :embeds-one em-address)
  (:tags    :embeds-many em-address))

(defun em-address-changeset (attrs)
  (-> (cast 'em-address attrs '(:street :city))
      (validate-required '(:street))))

(test embeds-cast-and-persist
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE em_users (id INTEGER PRIMARY KEY, email TEXT, address TEXT, tags TEXT)")
           (let* ((attrs '(:email "a@b"
                           :address (:street "1 Main" :city "Tokyo")
                           :tags    ((:street "Home") (:street "Office"))))
                  (cs (-> (cast 'em-user attrs '(:email))
                          (cast-embed :address attrs #'em-address-changeset)
                          (cast-embed :tags    attrs #'em-address-changeset))))
             (is (cs-valid-p cs))
             ;; child changesets attached to cs changes
             (is (changeset-p (get-change cs :address)))
             (is (every #'changeset-p (get-change cs :tags)))
             ;; persist: JSON-encoded in the DB
             (repo-insert r cs)
             (let ((row (repo-get r 'em-user 1)))
               (is (search "Tokyo" (getf row :address)))
               (is (search "Home"  (getf row :tags))))))
      (sqlite-close a))))

(test embed-invalid-child-bubbles-up
  (let* ((attrs '(:email "a@b" :address (:city "no street")))
         (cs (cast-embed (cast 'em-user attrs '(:email))
                         :address attrs #'em-address-changeset)))
    (is (not (cs-valid-p cs)))
    (is (assoc :address (cs-errors cs)))))

;;; --- traverse-errors / apply-action ---

(defschema ta-user "ta_users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test traverse-errors-and-apply-action
  ;; collect errors grouped by field
  (let* ((cs (-> (cast 'ta-user '(:email "" :age -1) '(:email :age))
                 (validate-required '(:email))
                 (validate-number :age :>= 0))))
    (let ((traversed (traverse-errors cs)))
      (is (find :email traversed :key #'car))
      (is (find :age   traversed :key #'car))))
  ;; valid cs -> apply-action returns data
  (multiple-value-bind (data err)
      (apply-action (cast 'ta-user '(:email "a@b" :age 20) '(:email :age))
                    :insert)
    (is (equal "a@b" (getf data :email)))
    (is (null err)))
  ;; invalid cs -> apply-action returns the cs tagged with action
  (multiple-value-bind (data err)
      (apply-action (validate-required (cast 'ta-user '() '(:email)) '(:email))
                    :insert)
    (is (null data))
    (is (eq :insert (cs-action err)))))

;;; --- extended validators ---

(defschema val-user "val_users"
  (:id    :integer :primary-key t)
  (:role  :string)
  (:tags  :string)
  (:terms :boolean :virtual t)
  (:password :string :virtual t)
  (:password-confirmation :string :virtual t))

(test extended-validators
  ;; inclusion
  (is (cs-valid-p (validate-inclusion (cast 'val-user '(:role "admin") '(:role))
                                      :role '("admin" "user"))))
  (is (not (cs-valid-p (validate-inclusion (cast 'val-user '(:role "x") '(:role))
                                           :role '("admin" "user")))))
  ;; exclusion
  (is (not (cs-valid-p (validate-exclusion (cast 'val-user '(:role "admin") '(:role))
                                           :role '("admin")))))
  ;; subset
  (is (cs-valid-p (validate-subset
                   (put-change (cast 'val-user '() '()) :tags '("a" "b"))
                   :tags '("a" "b" "c"))))
  ;; confirmation
  (is (cs-valid-p
       (validate-confirmation
        (cast 'val-user '(:password "x" :password-confirmation "x")
              '(:password :password-confirmation))
        :password)))
  (is (not (cs-valid-p
            (validate-confirmation
             (cast 'val-user '(:password "x" :password-confirmation "y")
                   '(:password :password-confirmation))
             :password))))
  ;; acceptance
  (is (cs-valid-p (validate-acceptance
                   (cast 'val-user '(:terms t) '(:terms)) :terms)))
  (is (not (cs-valid-p (validate-acceptance
                        (cast 'val-user '(:terms nil) '(:terms)) :terms)))))

;;; --- virtual fields + enum ---

(defschema vf-user "vf_users"
  (:id       :integer :primary-key t)
  (:email    :string)
  (:status   :enum :values '(:draft :published))
  (:password :string :virtual t))

(test virtual-and-enum
  (let* ((a (make-sqlite-adapter ":memory:"))
         (r (make-repo a)))
    (unwind-protect
         (progn
           (repo-execute r "CREATE TABLE vf_users (id INTEGER PRIMARY KEY, email TEXT, status TEXT)")
           ;; virtual field accepted into changeset but not persisted
           (let* ((cs (cast 'vf-user '(:email "a@b" :status "published" :password "s3cret")
                            '(:email :status :password))))
             (is (cs-valid-p cs))
             (is (equal :published (get-change cs :status)))    ; enum coerced
             (is (equal "s3cret"   (get-change cs :password)))  ; virtual lives in cs
             (multiple-value-bind (rec err) (repo-insert r cs)
               (is (null err))
               ;; the inserted record (we return all values that hit DB)
               (is (not (member :password rec)))))               ; virtual filtered
           ;; enum rejects bad value
           (let ((cs (cast 'vf-user '(:status "bogus") '(:status))))
             (is (not (cs-valid-p cs)))
             (is (assoc :status (cs-errors cs)))))
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
