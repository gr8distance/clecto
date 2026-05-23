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
```

Every builder returns a fresh `query` — composing two pipelines never
mutates a shared object.

### Repo — the side-effect boundary

```lisp
(defparameter *repo* (make-repo (make-sqlite-adapter "app.db")))

(repo-all    *repo* (from :users))                  ; => list of plists
(repo-one    *repo* (where (from :users) '(= :id 1)))
(repo-get    *repo* 'user 1)                        ; by primary key
(repo-insert *repo* changeset)                      ; => (values record err)
(repo-update *repo* changeset)
(repo-delete *repo* 'user 1)
(repo-execute *repo* "VACUUM")                      ; raw SQL escape hatch
```

`repo-insert` / `repo-update` return `(values record nil)` on success and
`(values nil invalid-changeset)` on validation failure. No exceptions for the
expected case.

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
