# clecto

An Ecto-flavored, immutable, functional data layer for Common Lisp.

`clecto` is the data layer companion to [clug](https://github.com/gr8distance/clug).
The goal is the same: a small stack of pure functions you compose into
something the size of Phoenix, without any of the magic.

> **Values are immutable. Plugs are functions. The repo is the only thing
> that touches I/O.**

---

## What you get

| Layer | Role |
|---|---|
| **schema**     | `defschema` registers field metadata as plain data. No CLOS instances. |
| **changeset**  | `(cast → validate-* → validate-*)` — an immutable value flows through the pipeline. |
| **query**      | `(from → where → join → group-by → having → ...)` — builds a data AST. |
| **sql**        | Pure AST → SQL compiler. Split into `sql-expr`, `sql-select`, `sql-mutation`. |
| **adapter**    | Generic-function protocol — SQLite ships with the core; Postgres lives in `clecto/postgres`. |
| **repo**       | The side-effect boundary. The *only* place that hits the DB. |
| **telemetry**  | A single `*telemetry*` callable invoked around every query. |

143 tests pass against SQLite. The Postgres adapter compiles cleanly and
emits the right SQL; integration tests against a live PG live with your app.

---

## Install

Not on Quicklisp yet — symlink it:

```sh
git clone https://github.com/gr8distance/clecto.git ~/src/clecto
ln -s ~/src/clecto ~/quicklisp/local-projects/clecto
```

Then in a REPL:

```lisp
(ql:quickload :clecto)             ; core + SQLite adapter
(ql:quickload :clecto/postgres)    ; optional: Postgres adapter
```

You'll also need a SQLite library on your system if you use the default
adapter. The Postgres adapter pulls `postmodern`.

---

## Quickstart

```lisp
(defpackage #:demo
  (:use #:cl #:clecto)
  (:shadowing-import-from #:clecto #:union #:intersection #:set-difference))
(in-package #:demo)

(defmacro -> (init &body forms)
  (reduce (lambda (acc f)
            (if (consp f) (list* (car f) acc (cdr f)) (list f acc)))
          forms :initial-value init))

(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer)
  (:timestamps))

(defparameter *repo* (make-repo (make-sqlite-adapter ":memory:")))

(repo-execute *repo*
  "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT, age INTEGER,
                       inserted_at TEXT, updated_at TEXT)")

(defun new-user (attrs)
  (-> (cast 'user attrs '(:email :age))
      (validate-required '(:email))
      (validate-format   :email "@")
      (validate-number   :age :>= 0)
      (unique-constraint :email)))

(repo-insert *repo* (new-user '(:email "a@b" :age 20)))
;; => (:ID 1 :EMAIL "a@b" :AGE 20 :INSERTED-AT "..." :UPDATED-AT "..."), NIL

(repo-insert *repo* (new-user '(:email "bad" :age -1)))
;; => NIL, #<CHANGESET ... :errors ((AGE . "is out of range") ...)>
```

---

## Schema

```lisp
(defschema user "users"
  (:id       :integer :primary-key t)
  (:email    :string)
  (:age      :integer)
  (:status   :enum :values '(:draft :published))
  (:password :string :virtual t)             ; never persisted
  (:address  :embeds-one  address)           ; stored as JSON
  (:tags     :embeds-many tag)               ; JSON array
  (:posts    :has-many post :foreign-key :user-id)
  (:bio      :has-one  bio  :foreign-key :user-id)
  (:timestamps))                              ; auto inserted-at/updated-at
```

**Field types**:
`:integer`, `:float`, `:decimal`, `:string`, `:boolean`,
`:utc-datetime`, `:naive-datetime`, `:date`, `:binary-id`,
`:enum` (with `:values '(...)`)

**Field options**:
`:primary-key`, `:virtual t` (skipped at insert/update), `:required`, …

**Association kinds**:
`:has-many`, `:has-one`, `:belongs-to`, `:embeds-one`, `:embeds-many`

**Timestamps**: writing `(:timestamps)` injects `:inserted-at` and
`:updated-at` (`:naive-datetime`) fields and auto-populates them.

---

## Changeset

```lisp
(-> (cast 'user attrs '(:email :age :password))
    (validate-required '(:email))
    (validate-format     :email "@")
    (validate-length     :email :min 3 :max 80)
    (validate-number     :age :>= 0 :<= 150)
    (validate-inclusion  :status '(:draft :published))
    (validate-exclusion  :email '("admin@example.com"))
    (validate-confirmation :password)             ; checks :password-confirmation
    (validate-acceptance :terms)
    (unique-constraint :email :message "taken")
    (foreign-key-constraint :role-id)
    (check-constraint  :age :name "users_age_positive"))
```

A changeset carries `data`, `changes`, `errors`, `valid-p`, `constraints`,
`action`. Every operation returns a fresh one. The full constructor and
helper API:

```lisp
(cast data-or-schema attrs allowed-fields)   ; produces a changeset
(put-change cs field value)                  ; force a change
(get-change cs field)                        ; only in proposed changes
(get-field  cs field)                        ; change overrides data
(add-error  cs field message)
(apply-changes cs)                            ; merge changes onto data

;; Nested forms / embedded data
(cast-embed cs :address attrs #'address-changeset)   ; one or many
(cast-assoc cs :posts   attrs #'post-changeset)

;; LiveView form pattern: validate without hitting DB
(apply-action cs :insert)
;; => (values data nil)  if valid
;; => (values nil cs-with-action) otherwise

;; Render errors in templates
(traverse-errors cs (lambda (field msg) (format nil "[~a] ~a" field msg)))
;; => ((:email "[email] can't be blank") (:age "[age] is out of range"))
```

---

## Query

```lisp
(-> (from :users)
    (where '(= :age 20))
    (where '(like :email "%@example.com"))
    (select '(:id :email))
    (order-by '((:asc :id)))
    (limit 10))
```

**Where operators**:
```
(= COL V)   (<> COL V)   (< COL V)   (<= COL V)   (> COL V)   (>= COL V)
(in COL (V1 V2 ...))     (in COL subquery)
(like COL "pat%")
(is-null COL)   (is-not-null COL)
(and EXPR ...)  (or EXPR ...)  (not EXPR)
(:fragment "raw sql with ? holes" arg1 arg2 ...)
```

**Aggregates** (in `select` / `having`):
```
(:count :id)   (:count :*)   (:sum :age)   (:avg :age)   (:min ...)   (:max ...)
```

**Joins, group-by, having** — qualified columns are dotted keywords:
```lisp
(-> (from :users)
    (join :inner :posts '(= :users.id :posts.user-id))
    (group-by :users.id)
    (having '(> (:count :posts.id) 3))
    (select '(:users.id (:count :posts.id))))
```

Join kinds: `:inner`, `:left`, `:right`, `:full` (dialect-dependent).

**Distinct** (incl. Postgres DISTINCT ON):
```lisp
(distinct (from :users))            ; SELECT DISTINCT *
(distinct (from :users) :role)       ; DISTINCT ON (role)
```

**Subqueries and CTEs**:
```lisp
(let ((inner (select (from :users) '(:id))))
  (where (from :posts) (list 'in :user-id (subquery inner))))

(-> (from :user-counts)
    (with-cte :user-counts (from :users)))
```

**Set operations** (shadowing `cl:union` & friends):
```lisp
(clecto:union     q1 q2)
(union-all        q1 q2)
(intersect        q1 q2)
(except           q1 q2)
```

**Locking + multi-tenant prefix**:
```lisp
(lock        (from :users) :for-update)
(with-prefix (from :users) "tenant_a")
```

**Composable dynamic filters**:
```lisp
(-> (from :users)
    (where-if min-age `(>= :age ,min-age))   ; nil condition → no-op
    (where-if role    `(= :role ,role))
    (where (and-filters '(>= :age 18) (when verified? '(= :verified t)))))
```

**Fragment** — when the DSL doesn't reach, embed raw SQL safely:
```lisp
(where q '(:fragment "lower(?) = ?" :email "abc@example.com"))
(select q '((:fragment "coalesce(?, 0)" :score)))
```
Keyword args become inlined (escaped) identifiers; everything else is a
parameter.

---

## Repo

```lisp
(defparameter *repo* (make-repo (make-sqlite-adapter "app.db")))

;; reads
(repo-all      *repo* (from :users))
(repo-one      *repo* (where (from :users) '(= :id 1)))
(repo-get      *repo* 'user 1)                        ; by primary key
(repo-get-by   *repo* 'user '(:email "a@b"))          ; by arbitrary fields
(repo-exists-p *repo* (where (from :users) '(= :email "a@b")))

;; single-row writes (changeset-based)
(repo-insert *repo* changeset)                        ; => (values record err)
(repo-update *repo* changeset)
(repo-delete *repo* 'user 1)

;; bulk writes (no changeset)
(repo-insert-all *repo* 'user '((:email "a@b") (:email "c@d")))
(repo-update-all *repo* (where (from :users) '(>= :age 18)) '(:status "adult"))
(repo-delete-all *repo* (where (from :users) '(= :status "banned")))

;; upsert
(repo-insert *repo* cs :on-conflict :replace :conflict-target :email)
(repo-insert *repo* cs :on-conflict :nothing)
(repo-insert *repo* cs :on-conflict '(:replace :age :updated-at))

;; preload associations
(repo-preload *repo* 'user users :posts)
(repo-preload *repo* 'user user '(:posts :bio))
(repo-preload *repo* 'post posts :author)

;; raw SQL escape hatch
(repo-execute *repo* "VACUUM")
```

**Transactions** (nested = automatic savepoints):
```lisp
(repo-transaction (*repo*)
  (repo-insert *repo* cs1)
  (repo-insert *repo* cs2)
  (repo-transaction (*repo*)              ; nested = savepoint
    (when oops? (rollback))               ; cleanly aborts the savepoint
    ...))
```
Any unhandled error rolls back the (sub)transaction; `rollback` aborts
without an error.

---

## Adapters

```lisp
(defgeneric adapter-execute              (a sql params))
(defgeneric adapter-execute-returning    (a sql params))
(defgeneric adapter-quote-identifier     (a name))
(defgeneric adapter-placeholder          (a index))
(defgeneric adapter-last-insert-id       (a))
(defgeneric adapter-supports-returning-p (a))
(defgeneric adapter-begin    (a))
(defgeneric adapter-commit   (a))
(defgeneric adapter-rollback (a))
(defgeneric adapter-translate-constraint-error (a condition constraints))
```

Two adapters ship today:

```lisp
(make-sqlite-adapter ":memory:")
(make-sqlite-adapter "/var/app.db")

(make-postgres-adapter "mydb" "user" "secret" "localhost"
                       :port 5432 :pooled-p t)
```

The Postgres adapter is in the optional `clecto/postgres` system — it
pulls `postmodern`. When the adapter signals
`adapter-supports-returning-p`, `repo-insert` will use `RETURNING` to
recover the inserted PK in one round-trip instead of `last_insert_id`.

> **Thread safety**: the SQLite/PG adapters lock their internal
> transaction depth with `bordeaux-threads`. For Clack workers the
> standard practice is one connection per worker thread — sharing one
> adapter across threads works for short reads but a long-running
> transaction will block.

---

## Telemetry

A single hook around every executed query:

```lisp
(setf clecto:*telemetry*
      (lambda (event payload)
        (case event
          (:query (log:info "sql=~a duration=~,3fs" (getf payload :sql)
                                                      (getf payload :duration)))
          (:error (log:error "boom: ~a / ~a"
                             (getf payload :sql)
                             (getf payload :condition))))))
```

Payload keys: `:sql`, `:params`, `:duration`, `:adapter`, plus
`:condition` on `:error`. Callback errors are swallowed so telemetry
never breaks a query.

---

## Source layout

```
src/
  package.lisp         ; subsystem-grouped (:export ...) blocks
  util.lisp            ; define-copier macro
  schema.lisp          ; defschema, field, association, cast-value
  changeset.lisp       ; cast, validate-*, constraints, traverse-errors
  query.lisp           ; from / where / join / etc. + subquery + cte
  adapter.lisp         ; generic-function protocol + identifier escaping
  telemetry.lisp       ; *telemetry* hook + with-telemetry macro
  sql.lisp             ; facade: sql-state, qi, emit-param
  sql-expr.lisp        ; operators, aggregates, fragment, operands
  sql-select.lisp      ; emit-select, joins, distinct, CTE, set ops, lock
  sql-mutation.lisp    ; INSERT (incl. RETURNING + ON CONFLICT), UPDATE, DELETE
  adapters/
    sqlite.lisp        ; default
    postgres.lisp      ; clecto/postgres system
  repo.lisp            ; the side-effect boundary
```

---

## Run the tests

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :clecto/tests)' \
     --eval '(asdf:test-system :clecto)'
```

143 tests covering schema, changeset, query AST, SQL emission, SQLite
roundtrips (insert / select / update / delete / transactions /
constraints / preload / upsert / bulk / embeds), Postgres SQL emission
via a mock adapter, telemetry, and security guards (read-from-string
rejection, identifier escaping, LIMIT/OFFSET coercion, ORDER BY and
lock whitelists).

---

## License

MIT
