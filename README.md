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
| **query**      | `(from → where → order-by → limit)` — builds a data AST. |
| **sql**        | Pure AST → SQL compiler. Dialect specifics live in the adapter. |
| **adapter**    | Generic-function protocol (`adapter-execute`, `-quote-identifier`, ...). |
| **repo**       | The side-effect boundary. The *only* place that hits the DB. |

---

## Install

Not on Quicklisp yet — symlink it:

```sh
git clone https://github.com/gr8distance/clecto.git ~/src/clecto
ln -s ~/src/clecto ~/quicklisp/local-projects/clecto
```

Then in a REPL:

```lisp
(ql:quickload :clecto)
```

You'll also need `cl-sqlite` (pulled in automatically) and a SQLite library on
your system. v0.1 ships a SQLite adapter only; Postgres/MySQL fit the same
protocol and will land later.

---

## Quickstart

```lisp
(defpackage #:demo (:use #:cl #:clecto))
(in-package #:demo)

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

;; A changeset is just a value that flows through validators.
(defun new-user (attrs)
  (-> (cast 'user attrs '(:email :age))
      (validate-required '(:email))
      (validate-format   :email "@")
      (validate-number   :age :>= 0)))

(repo-insert *repo* (new-user '(:email "a@b" :age 20)))
;; => (:ID 1 :EMAIL "a@b" :AGE 20), NIL

(repo-insert *repo* (new-user '(:email "bad" :age -1)))
;; => NIL, #<CHANGESET ... :errors ((AGE . "is out of range") ...)>
```

---

## Concepts

### Schema — declarative shape

```lisp
(defschema user "users"
  (:id          :integer      :primary-key t)
  (:email       :string)
  (:age         :integer)
  (:inserted-at :utc-datetime))
```

A schema is a name + table + list of `field` records. It's stored in a
registry by name and looked up with `find-schema`. No methods, no instances —
just a description of the shape.

Supported types: `:integer`, `:float`, `:string`, `:boolean`, `:utc-datetime`.

### Changeset — validation as a pipeline

A changeset carries:

- `data`     — the existing record (`nil` on insert)
- `changes`  — proposed updates
- `errors`   — `(field . message)` pairs
- `valid-p`  — derived flag
- `schema`   — the schema name, for type casting

Every operation returns a fresh changeset:

```lisp
(-> (cast 'user '(:email "a@b" :age "20") '(:email :age))
    (validate-required '(:email))
    (validate-format   :email "@")
    (validate-length   :email :min 3 :max 80)
    (validate-number   :age :>= 0 :<= 150))
```

`cast` filters the incoming attrs by the allowed list and runs type coercion
against the schema (`"20"` → `20`). If a value fails to cast, it shows up in
`cs-errors` and `valid-p` flips to `nil`.

You can also stash intermediate values:

```lisp
(put-change cs :hashed-password (hash (get-change cs :password)))
```

### Query — composable AST

```lisp
(-> (from :users)
    (where '(= :age 20))
    (where '(like :email "%@example.com"))
    (select '(:id :email))
    (order-by '((:asc :id)))
    (limit 10))
```

Where-expressions are S-expressions. Supported operators:

```
(= COL V)   (<> COL V)   (< COL V)   (<= COL V)   (> COL V)   (>= COL V)
(in COL (V1 V2 ...))
(like COL "pat%")
(is-null COL)   (is-not-null COL)
(and EXPR EXPR ...)   (or EXPR EXPR ...)   (not EXPR)
(:fragment "raw sql with ? holes" arg1 arg2 ...)
```

Aggregates work in `select` and `having`:

```
(:count :id)   (:count :*)   (:sum :age)   (:avg :age)   (:min ...)   (:max ...)
```

### Joins, group-by, having

Qualified column names use a dotted keyword (`:users.id`).

```lisp
(-> (from :users)
    (join :inner :posts '(= :users.id :posts.user-id))
    (where '(= :users.email "a@b"))
    (group-by :users.id)
    (having '(> (:count :posts.id) 3))
    (select '(:users.id (:count :posts.id))))
```

Supported join kinds: `:inner`, `:left`, `:right`, `:full`
(dialect-dependent).

### Fragment — raw SQL escape hatch

When the DSL doesn't reach, drop down to SQL:

```lisp
(where q '(:fragment "lower(?) = ?" :email "abc@example.com"))
(select q '((:fragment "coalesce(?, 0)" :score)))
```

Keyword args become inlined identifiers; everything else is parameterized.

Every builder returns a fresh `query` — composing two pipelines never
mutates a shared object.

### Associations — declared inline, preloaded explicitly

Associations live in the same form as fields. If the second element of a spec
is `:has-many`, `:has-one`, or `:belongs-to`, it's an association.

```lisp
(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:posts :has-many post :foreign-key :user-id)
  (:bio   :has-one  bio  :foreign-key :user-id))

(defschema post "posts"
  (:id      :integer :primary-key t)
  (:title   :string)
  (:user-id :integer)
  (:author  :belongs-to user :foreign-key :user-id))
```

Fetching is explicit — no lazy magic, no N+1 surprises. `repo-preload`
runs one query per association regardless of how many records you give it:

```lisp
(let ((users (repo-all *repo* (from :users))))
  (repo-preload *repo* 'user users :posts))
;; => each user plist gains a :posts key

(repo-preload *repo* 'user user '(:posts :bio))    ; multiple at once
(repo-preload *repo* 'post posts :author)          ; belongs-to
```

Column-name translation between Lisp keywords (`:user-id`) and DB columns
(`user_id`) is handled by the adapter — write idiomatic Lisp, get idiomatic SQL.

### Repo — the side-effect boundary

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

;; raw SQL escape hatch
(repo-execute *repo* "VACUUM")
```

`repo-insert` / `repo-update` return `(values record nil)` on success and
`(values nil invalid-changeset)` on validation or constraint failure.

### Transactions

```lisp
(repo-transaction (*repo*)
  (repo-insert *repo* cs1)
  (repo-insert *repo* cs2))

;; Abort cleanly from anywhere inside:
(repo-transaction (*repo*)
  (when (something-bad) (rollback))
  ...)
```

Nesting uses savepoints automatically. Any unhandled error inside the body
rolls back the (sub)transaction.

### Constraint errors as changeset errors

Declare which DB constraint should land on which field, then let the repo
translate failures:

```lisp
(-> (cast 'user attrs '(:email))
    (validate-required '(:email))
    (unique-constraint :email :message "already taken")
    (foreign-key-constraint :role-id))

;; If insert fails with UNIQUE/FOREIGN KEY, you get back the changeset
;; with the right error attached — no exception escapes.
```

### Timestamps

Opt in by adding `(:timestamps)` to the schema body. `:inserted-at` and
`:updated-at` (type `:naive-datetime`) are added to the field list and
auto-populated on insert/update.

```lisp
(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:timestamps))
```

### Adapter — the dialect protocol

```lisp
(defgeneric adapter-execute           (a sql params))
(defgeneric adapter-execute-returning (a sql params))
(defgeneric adapter-quote-identifier  (a name))
(defgeneric adapter-placeholder       (a index))
(defgeneric adapter-last-insert-id    (a))
```

That's the whole protocol. Adding Postgres or MySQL is one file in
`src/adapters/`.

---

## Source layout

```
src/
  package.lisp         ; exports
  schema.lisp          ; defschema, field, cast-value
  changeset.lisp       ; cast, validate-*, put-change, apply-changes
  query.lisp           ; from / where / select / order-by / limit
  sql.lisp             ; pure AST -> SQL compiler
  adapter.lisp         ; the generic-function protocol
  adapters/
    sqlite.lisp        ; v0.1 ships this one
  repo.lisp            ; the only side-effecting module
```

Each file is small and orthogonal — take what you need, ignore the rest.

---

## Run the tests

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :clecto/tests)' \
     --eval '(asdf:test-system :clecto)'
```

27 checks, including a SQLite roundtrip (insert → select → update → delete).

---

## Roadmap

- v0.1 (this release): schema, changeset, query, sql, sqlite adapter, repo
- Postgres adapter via `postmodern`
- Associations (`belongs-to`, `has-many`) with explicit preload
- Migrations DSL
- Transactions (`repo-transaction`)
- MySQL adapter

---

## License

MIT
