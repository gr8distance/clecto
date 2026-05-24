# repo

The repo is the **I/O boundary**. It wraps an adapter and is the
only thing in clecto that touches the database. Everything before
the repo — schema, changeset, query — is value-in / value-out.

A typical app builds one repo at startup and passes it around.

---

## Building a repo

### `(make-repo ADAPTER) → REPO`

Wrap an adapter in a repo. See [adapter](./adapter.md) for the
adapters clecto ships and how to write your own.

```lisp
;; SQLite — included in clecto core
(defparameter *repo*
  (make-repo (make-sqlite-adapter ":memory:")))

(defparameter *repo*
  (make-repo (make-sqlite-adapter #P"/var/data/app.db")))

;; PostgreSQL — opt-in clecto/postgres
(ql:quickload :clecto/postgres)
(defparameter *repo*
  (make-repo (make-postgres-adapter
              :host "localhost" :database "myapp"
              :user "myapp" :password (uiop:getenv "DB_PASS"))))
```

`(repo-adapter repo)` returns the wrapped adapter — useful for
adapter-specific calls (e.g. closing a SQLite connection at
shutdown).

---

## Reads

### `(repo-all REPO QUERY) → LIST-OF-PLISTS`

Run QUERY and return every matching row as a plist.

```lisp
(repo-all *repo*
          (-> (from :users)
              (where '(= :active t))
              (order-by '((:desc :inserted-at)))
              (limit 25)))
;; → ((:ID 1 :EMAIL "..." :ACTIVE T :INSERTED-AT "...") ...)
```

Column names come back lispified: `user_id` → `:USER-ID`. Boolean
column values come back as proper `T` / `NIL`.

### `(repo-one REPO QUERY) → PLIST | NIL`

Return the first matching row, or `NIL`. Adds `LIMIT 1` to the
query if no LIMIT was set.

```lisp
(repo-one *repo* (where (from :users) '(= :email "alice@example.com")))
```

### `(repo-get REPO SCHEMA-NAME ID) → PLIST | NIL`

Fetch by primary key. The schema tells the repo which column is
the PK; you just pass the ID.

```lisp
(repo-get *repo* 'user 42)
;; → (:ID 42 :EMAIL "alice@example.com" ...)
```

### `(repo-get-by REPO SCHEMA-NAME FILTERS) → PLIST | NIL`

Fetch the first row matching a plist of `(field value ...)` —
all conditions are AND-combined:

```lisp
(repo-get-by *repo* 'user (list :email "alice@example.com"))
(repo-get-by *repo* 'user (list :role "admin" :active t))
```

### `(repo-exists-p REPO QUERY) → BOOLEAN`

`T` if QUERY matches any row, `NIL` otherwise. Implemented as
`(not (null (repo-one ...)))`.

```lisp
(repo-exists-p *repo*
               (-> (from :users)
                   (where '(= :email "alice@example.com"))))
```

---

## Mutations

The mutating helpers take a **changeset** and return
`(values RECORD-PLIST NIL)` on success or `(values NIL CHANGESET)`
on failure. The changeset on failure carries field errors —
either from the changeset's own validators, or from a declared
constraint that the DB flagged.

### `(repo-insert REPO CS &key on-conflict conflict-target)`

Insert a new row. The changeset must be valid; otherwise the
return is `(values nil cs)` without touching the DB.

```lisp
(multiple-value-bind (record err)
    (repo-insert *repo* (new-user '(:email "alice@example.com" :age 20)))
  (cond
    (record (format t "inserted ~a~%" (getf record :id)))
    (t (format t "errors: ~a~%" (traverse-errors err)))))
```

When the DB rejects the insert and a matching constraint is
declared on the changeset (`unique-constraint`, etc.), the error
becomes a field error on the returned changeset:

```lisp
;; second insert of the same email
(multiple-value-bind (record err)
    (repo-insert *repo* (new-user '(:email "alice@example.com" :age 20)))
  (assert (null record))
  (assert (assoc :email (cs-errors err))))
```

Adapters that support RETURNING (Postgres) get the row back in
one round-trip. SQLite falls back to `last_insert_rowid()` and
overlays the new PK on the inserted values to construct the
record plist.

#### Upserts: `:on-conflict`

```lisp
(repo-insert *repo* cs :on-conflict :nothing)
;; INSERT ... ON CONFLICT DO NOTHING

(repo-insert *repo* cs :on-conflict :replace)
;; INSERT ... ON CONFLICT DO UPDATE SET col1 = excluded.col1, ...

(repo-insert *repo* cs :on-conflict '(:replace :email :role))
;; UPDATE only the listed columns
```

`:conflict-target` is a column keyword or list of keywords
identifying the unique index that triggers the conflict. Defaults
to the schema's primary key:

```lisp
(repo-insert *repo* cs
             :on-conflict :replace
             :conflict-target :email)
```

### `(repo-update REPO CS) → (values RECORD NIL) | (values NIL CS)`

Update the row identified by the changeset's `:data` (which must
include the primary key). The changeset's `:changes` plist is what
gets written — fields not in `:changes` are left alone.

```lisp
(let* ((row (repo-get *repo* 'user 1))
       (cs  (-> (cast (list* :__schema__ 'user row)
                      '(:age 21) '(:age))
                (validate-number :age :>= 0))))
  (repo-update *repo* cs))
```

For schemas with `(:timestamps)`, `updated_at` is auto-stamped to
the current local time.

### `(repo-delete REPO SCHEMA-NAME ID) → ROWS-AFFECTED`

Delete by primary key:

```lisp
(repo-delete *repo* 'user 42)
;; → 1   (or 0 if no row matched)
```

This does not take a changeset — it's a direct PK delete. For
soft-deletes (setting a flag), use `repo-update` instead.

---

## Bulk operations

### `(repo-insert-all REPO SCHEMA-NAME ROWS) → ROWS-AFFECTED`

Insert many rows in one statement. ROWS is a list of plists; all
rows must share the same column set.

```lisp
(repo-insert-all *repo* 'tag
                 '((:name "news")
                   (:name "tech")
                   (:name "design")))
;; → 3
```

Auto-stamps timestamps when the schema opts in.

**Safety cap**: capped at `*repo-insert-all-row-cap*` (default
1000) per call. Beyond the cap the function signals an error
asking you to chunk explicitly. The cap protects against
accidentally building a single statement with millions of
parameters (Postgres' protocol max is 65535).

### `(repo-update-all REPO QUERY SET-PLIST &key all) → ROWS-AFFECTED`

Bulk update every row matching QUERY:

```lisp
(repo-update-all *repo*
                 (-> (from :users) (where '(= :active nil)))
                 (list :archived-at (now-naive-datetime)))
```

**Safety guard**: a query with no WHERE refuses by default —
that would update *every row*. Pass `:all t` to confirm:

```lisp
;; "yes, every row"
(repo-update-all *repo* (from :users)
                 (list :version 2)
                 :all t)
```

SET values can be SQL fragments for atomic operations:

```lisp
(repo-update-all *repo*
                 (-> (from :users) (where `(= :id ,user-id)))
                 (list :failed-login-count
                       '(:fragment "failed_login_count + 1")))
;; UPDATE "users" SET "failed_login_count" = failed_login_count + 1
;; WHERE "id" = ?
```

This is how clauth's lockout counter increments atomically without
a read-modify-write race.

### `(repo-delete-all REPO QUERY &key all) → ROWS-AFFECTED`

Bulk delete. Same `:all` safety guard:

```lisp
(repo-delete-all *repo*
                 (-> (from :sessions) (where `(< :expires-at ,(now-naive-datetime)))))
```

---

## Preloading associations

clecto doesn't auto-load associations. You ask for them when you
need them.

### `(repo-preload REPO SCHEMA-NAME RECORDS ASSOCS) → RECORDS-WITH-ASSOCS`

Attach association data to one or more records.

```lisp
(let ((users (repo-all *repo* (from :users))))
  (repo-preload *repo* 'user users '(:posts :bio)))
;; each user gets :posts (list of posts) and :bio (single record) attached
```

Works for `:has-many`, `:has-one`, `:belongs-to`. For embeddings
(`:embeds-one`, `:embeds-many`), data is already on the row — no
preload needed.

The implementation does an `IN (id1, id2, ...)` query per
association, regardless of how many records you pass — N+1
queries are avoided by batching.

RECORDS may be a single plist or a list of plists; the return
shape matches.

```lisp
;; single record
(let ((user (repo-get *repo* 'user 1)))
  (repo-preload *repo* 'user user :posts))

;; list
(let ((users (repo-all *repo* (from :users))))
  (repo-preload *repo* 'user users :posts))
```

---

## Transactions

### `(repo-transaction (REPO) &body BODY)`

Wrap BODY in a DB transaction. On normal completion the
transaction commits; on any signalled error it rolls back and
re-raises.

```lisp
(repo-transaction (*repo*)
  (multiple-value-bind (user err) (repo-insert *repo* user-cs)
    (when err (error "user insert failed: ~a" err))
    (repo-insert *repo* (post-cs (getf user :id)))))
```

### `(rollback)`

Roll back the enclosing transaction without raising. The
transaction body's return value is discarded; `repo-transaction`
returns `NIL`:

```lisp
(repo-transaction (*repo*)
  (let ((rec (insert-some-row)))
    (unless (sanity-check rec) (rollback))
    rec))
```

This is for "I have second thoughts about committing" without
needing to invent an exception type.

Nested `repo-transaction` calls use savepoints — the outer
commit is the one that actually persists; an inner rollback only
discards work since its savepoint.

---

## Raw SQL escape hatch

### `(repo-execute REPO SQL &optional PARAMS) → ROWS`

Run arbitrary SQL with parameter binding. Useful for:

- DDL (`CREATE TABLE`, `CREATE INDEX`) during demos / tests
- Database-specific statements clecto doesn't model
- Migrations bootstrapping (when not using an external migration
  tool)

> ⚠️ **`repo-execute` is an UNPARAMETERISED ESCAPE HATCH** — the
> SQL string is sent to the adapter unchanged. Use PARAMS for
> every dynamic value:
>
> ```lisp
> ;; GOOD:
> (repo-execute *repo*
>               "SELECT * FROM users WHERE id = ?"
>               (list user-id))
>
> ;; BAD (SQL injection):
> (repo-execute *repo*
>               (format nil "SELECT * FROM users WHERE id = ~a"
>                       user-id))
> ```
>
> There is no smart string parser between this call and the
> adapter — anything you splice into the SQL string is executed
> verbatim. Never thread user input there; bind via PARAMS.

```lisp
(repo-execute *repo*
  "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER,
                       inserted_at TEXT, updated_at TEXT)")

(repo-execute *repo*
  "SELECT count(*) AS total FROM users WHERE created_at >= ?"
  (list yesterday))
;; → ((:total 42))
```

Telemetry fires for `repo-execute` calls just like for built-in
operations — see [telemetry](./telemetry.md).

---

## Errors

### `db-error`

Wraps an unhandled DB error from the adapter. The original
condition lives at `(db-error-original e)`, the offending SQL at
`(db-error-sql e)`. The default reporter does **not** print the
original message — it leaks row data in some adapters — so you
get a tidy `"Database error. SQL: ..."` in logs by default.

To see the original:

```lisp
(handler-case (repo-insert *repo* cs)
  (clecto:db-error (e)
    (format t "real error: ~a~%" (db-error-original e))))
```

You only get a `db-error` when the adapter's error doesn't match
any declared constraint. Declare `unique-constraint` /
`foreign-key-constraint` / `check-constraint` on changesets you
expect might violate; the repo will turn matching DB errors into
changeset errors instead.

### Changeset errors

The normal failure mode. `repo-insert` / `repo-update` return
`(values nil cs)` and the changeset's `:errors` has details.
Render with `traverse-errors` (see [changeset](./changeset.md)).

---

## Snippets

**The "show one or 404" pattern:**

```lisp
(defun fetch-user-or-404 (id)
  (or (repo-get *repo* 'user id)
      (error 'not-found :resource 'user :id id)))
```

**Insert with redirect-on-success:**

```lisp
(defun create-handler (conn)
  (multiple-value-bind (record cs)
      (repo-insert *repo* (new-user (form-attrs conn)))
    (cond
      (record (redirect conn (format nil "/users/~a" (getf record :id))))
      (t      (render-form conn :errors (traverse-errors cs))))))
```

**Transactional money transfer:**

```lisp
(defun transfer (from-id to-id amount)
  (repo-transaction (*repo*)
    (let ((from (or (repo-get *repo* 'account from-id) (rollback)))
          (to   (or (repo-get *repo* 'account to-id)   (rollback))))
      (when (< (getf from :balance) amount) (rollback))
      (repo-update *repo* (decrement-cs from amount))
      (repo-update *repo* (increment-cs to   amount)))))
```

**Soft-delete via update-all:**

```lisp
(defun soft-delete-stale-sessions ()
  (repo-update-all *repo*
                   (-> (from :sessions)
                       (where `(< :expires-at ,(now-naive-datetime))))
                   (list :revoked-at (now-naive-datetime))))
```

**Upsert with conflict target:**

```lisp
(defun upsert-counter (name)
  (repo-insert *repo*
               (-> (cast 'counter (list :name name :count 1) '(:name :count)))
               :on-conflict '(:replace :count)
               :conflict-target :name))
```

**Bulk import in chunks:**

```lisp
(defun import-rows (rows)
  (loop for chunk in (alexandria:split-sequence-if
                      (constantly nil) rows :count 500)
        do (repo-insert-all *repo* 'event chunk)))
```

(The chunk size of 500 stays well under the
`*repo-insert-all-row-cap*` default of 1000 and is a reasonable
balance with Postgres' parameter-count limit.)
