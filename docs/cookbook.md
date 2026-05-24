# Cookbook

Cross-cutting recipes. Each is a complete pattern with the
context of why pieces sit where they sit.

---

## A complete user registration

```lisp
(defschema user "users"
  (:id                    :integer :primary-key t)
  (:email                 :string)
  (:password-hash         :string)
  (:password              :string :virtual t)
  (:password-confirmation :string :virtual t)
  (:timestamps))

(defun new-user (attrs)
  (let ((cs (-> (cast 'user attrs '(:email :password :password-confirmation))
                (validate-required '(:email :password))
                (validate-format    :email "@")
                (validate-length    :email :min 3 :max 254)
                (validate-length    :password :min 12 :max 1024)
                (validate-confirmation :password)
                (unique-constraint  :email))))
    (if (cs-valid-p cs)
        (put-change cs :password-hash
                    (hash-password (get-field cs :password)))
        cs)))

(defun register (attrs)
  (repo-insert *repo* (new-user attrs)))
```

Walk-through:

- The schema declares two **virtual** fields (`:password`,
  `:password-confirmation`). They flow through the changeset for
  validation but are dropped before SQL.
- Validators run in sequence — each `add-error` fires only when
  the preceding check passed.
- `unique-constraint` is declared on the *changeset* (not the
  schema). The repo checks for it after the DB rejects the
  insert and turns the violation into a field error.
- `put-change :password-hash` only runs once the changeset is
  valid — otherwise we'd be hashing an empty password into the
  changeset on a validation failure.

---

## Update with `:__schema__` splice

When updating, you need to tell `cast` which schema the existing
row belongs to. The convention is `:__schema__` as a key:

```lisp
(defun change-user-email (user attrs)
  (let* ((data (list* :__schema__ 'user user))
         (cs (-> (cast data attrs '(:email))
                 (validate-required '(:email))
                 (validate-format   :email "@")
                 (unique-constraint :email))))
    (repo-update *repo* cs)))
```

Pattern: prepend `:__schema__ 'name` to the record plist, then
`cast` finds the schema via the metadata key. The repo strips
this key before generating SQL so it doesn't try to write a
`__schema__` column.

---

## Atomic counter increment

`SET col = col + 1` without a read-modify-write race:

```lisp
(defun bump-failed-login-count (user-id)
  (repo-update-all *repo*
                   (-> (from :users) (where `(= :id ,user-id)))
                   (list :failed-login-count
                         '(:fragment "failed_login_count + 1"))))
```

The `:fragment` form is a raw-SQL escape hatch — its template is
inlined as-is, with `?` holes filled by safe parameters. Use it
sparingly; the more you reach for fragments, the more your
queries diverge from being adapter-portable.

---

## Soft delete with timestamp

```lisp
(defun soft-delete-user (id)
  (repo-update-all *repo*
                   (-> (from :users) (where `(= :id ,id)))
                   (list :deleted-at (now-naive-datetime))))

(defun active-users ()
  (-> (from :users)
      (where '(is-null :deleted-at))))
```

The "scope" pattern — wrap the WHERE in a function so every
query naturally filters out soft-deleted rows. The repo doesn't
know about soft delete; you opt in per query.

---

## Pagination

```lisp
(defun paginate (q &key (page 1) (per-page 25))
  (-> q
      (limit per-page)
      (offset (* per-page (1- page)))))

(defun page-of-users (&key (page 1) role)
  (repo-all *repo*
            (-> (from :users)
                (where-if role `(= :role ,role))
                (order-by '((:desc :inserted-at)))
                (paginate :page page :per-page 25))))
```

For "infinite scroll" / cursor pagination, replace offset with
`(where '(< :id ,cursor))`. The latter scales better for large
tables (OFFSET 1000000 is slow).

---

## Search with optional filters

```lisp
(defun search-events (&key user-id event-type since until)
  (repo-all *repo*
            (-> (from :events)
                (where-if user-id   `(= :user-id ,user-id))
                (where-if event-type `(= :event-type ,event-type))
                (where-if since     `(>= :occurred-at ,since))
                (where-if until     `(<= :occurred-at ,until))
                (order-by '((:desc :occurred-at)))
                (limit 100))))
```

Each filter is a one-liner. None of them fire → the query is
just "SELECT * FROM events ORDER BY occurred_at DESC LIMIT 100".
Compose freely; the AST is just data.

---

## Insert with associations

clecto doesn't auto-persist associated rows. Use a transaction:

```lisp
(defun create-user-with-profile (user-attrs profile-attrs)
  (repo-transaction (*repo*)
    (multiple-value-bind (user err) (repo-insert *repo* (new-user user-attrs))
      (when err (error "user creation failed: ~a" (traverse-errors err)))
      (multiple-value-bind (profile p-err)
          (repo-insert *repo*
                       (new-profile (list* :user-id (getf user :id)
                                           profile-attrs)))
        (when p-err
          (error "profile creation failed: ~a" (traverse-errors p-err)))
        (list :user user :profile profile)))))
```

If either insert fails, the transaction rolls back the other.

---

## Preloading associations

```lisp
(defun user-with-posts-and-bio (id)
  (let ((user (repo-get *repo* 'user id)))
    (when user
      (repo-preload *repo* 'user user '(:posts :bio)))))

(defun list-with-author (limit)
  (let ((posts (repo-all *repo*
                         (-> (from :posts)
                             (order-by '((:desc :inserted-at)))
                             (limit limit)))))
    (repo-preload *repo* 'post posts :user)))
```

`repo-preload` batches the secondary query — for N posts each
with a `:user` association, you get **one** query against
`users WHERE id IN (...)`, not N queries.

---

## Embedded JSON columns

```lisp
(defschema address "_"   ; table name irrelevant — embeds don't get their own table
  (:line1 :string)
  (:city  :string)
  (:zip   :string))

(defschema user "users"
  (:id      :integer :primary-key t)
  (:email   :string)
  (:address :embeds-one address)
  (:timestamps))

(defun address-cs (attrs)
  (-> (cast 'address attrs '(:line1 :city :zip))
      (validate-required '(:line1 :city))))

(defun new-user (attrs)
  (-> (cast 'user attrs '(:email))
      (validate-required '(:email))
      (cast-embed :address attrs #'address-cs)))

(repo-insert *repo* (new-user
                     '(:email "a@b" :address (:line1 "1 Main" :city "NYC" :zip "10001"))))
```

The address gets JSON-encoded into the `address` column of
`users`. Reads come back as a string by default — decode in the
caller, or specialize the adapter to auto-decode JSON columns.

---

## Repo wrapped in a thread-safe singleton

```lisp
(defparameter *repo* nil)
(defparameter *repo-lock* (bordeaux-threads:make-lock))

(defun ensure-repo ()
  (bordeaux-threads:with-lock-held (*repo-lock*)
    (or *repo*
        (setf *repo* (make-repo (make-app-adapter))))))
```

For SQLite this matters more than for Postgres — the SQLite
adapter holds a single connection (the cl-sqlite library doesn't
multiplex), so all access serializes anyway. For Postgres, use
postmodern's pool support inside the adapter.

---

## Telemetry hooked to slow-query logging

```lisp
(setf clecto:*telemetry*
      (lambda (event payload)
        (let ((ms (* 1000 (getf payload :duration))))
          (cond
            ((eq event :error)
             (log:error "DB error: ~a~%SQL: ~a"
                        (getf payload :condition)
                        (getf payload :sql)))
            ((> ms 100)
             (log:warn "slow query (~,1fms): ~a"
                       ms (getf payload :sql)))))))
```

Drop into your app at startup. Errors always log; queries log
only when slow. See [telemetry](./telemetry.md) for the full
payload shape.

---

## Setup at app boot

```lisp
(defparameter *repo* nil)

(defun init-repo (&key (path #P"app.db"))
  (let ((adapter (etypecase path
                   (string   (make-sqlite-adapter path))
                   (pathname (make-sqlite-adapter (namestring path))))))
    (setf *repo* (make-repo adapter))
    ;; bootstrap: create tables if missing (dev only — prod uses a real
    ;; migration tool, see project README for tool choices)
    (repo-execute *repo*
      "CREATE TABLE IF NOT EXISTS users
       (id INTEGER PRIMARY KEY,
        email TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        inserted_at TEXT,
        updated_at TEXT)")
    *repo*))

(defun stop-app ()
  (when *repo*
    (sqlite-close (repo-adapter *repo*))
    (setf *repo* nil)))
```

The DDL in `repo-execute` is fine for an in-memory demo or a
one-off test database. For real schemas, use a migration tool
(see the project README; each library's docs/schema*.md
documents the SQL).

---

## A custom validator that uses other fields

```lisp
(defun validate-date-range (cs &key start-field end-field)
  (let ((s (get-field cs start-field))
        (e (get-field cs end-field)))
    (cond
      ((or (null s) (null e)) cs)              ; required-check handles missing
      ((string<= s e) cs)
      (t (add-error cs end-field "must be on or after start")))))

(-> (cast 'event attrs '(:start-at :end-at))
    (validate-required '(:start-at :end-at))
    (validate-date-range :start-field :start-at :end-field :end-at))
```

Validators are just functions on the changeset. Reach for
helpers when the rule spans two fields.

---

## Working with `:utc-datetime`

```lisp
(defschema event "events"
  (:id           :integer :primary-key t)
  (:title        :string)
  (:occurred-at  :utc-datetime)
  (:timestamps))

(repo-insert *repo*
             (-> (cast 'event
                       (list :title "launch"
                             :occurred-at (now-utc-datetime))
                       '(:title :occurred-at))
                 (validate-required '(:title :occurred-at))))
```

`:utc-datetime` and `:naive-datetime` both store as ISO-8601-ish
strings. The difference is convention: UTC carries a `Z` suffix,
naive doesn't. clecto doesn't auto-convert between them — pick
one per column and stay consistent.

---

## Bulk operations with safety

```lisp
;; Refusing to update every row
(repo-update-all *repo* (from :users) (list :flag t))
;; → error: repo-update-all refuses to touch every row. Add WHERE or pass :all t.

;; Confirming it
(repo-update-all *repo* (from :users) (list :flag t) :all t)

;; Insert with the row cap
(repo-insert-all *repo* 'tag (loop repeat 1001
                                   collect (list :name "x")))
;; → error: repo-insert-all: 1001 rows exceeds cap of 1000. Chunk the input.
```

The safety guards exist because both operations are easy to
fire by accident with a missing WHERE or an unbounded list. The
right move is rarely to slap `:all t` on; it's to add the WHERE
you meant.

---

## Switching adapters by environment

```lisp
(defun make-app-adapter ()
  (let ((url (uiop:getenv "DATABASE_URL")))
    (cond
      ((null url)
       (make-sqlite-adapter #P"dev.db"))
      ((alexandria:starts-with-subseq "postgres://" url)
       (make-postgres-adapter :url url))
      (t (error "unknown DATABASE_URL: ~s" url)))))

(setf *repo* (make-repo (make-app-adapter)))
```

The queries / changesets / schemas don't change between
adapters. Only the adapter object and the SQL it renders does.
