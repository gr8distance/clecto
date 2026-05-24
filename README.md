# clecto

An immutable, functional data layer for Common Lisp built on three
ideas:

> **Values describe data. Pipelines transform them. The repo is
> the only thing that touches I/O.**

Schemas, changesets, and queries are plain values. Every builder
returns a new value. Only the repo runs SQL — and the SQL
compiler that powers it is pure.

clecto pairs with [clug](https://github.com/gr8distance/clug)
(routing) and [clauth](https://github.com/gr8distance/clauth)
(auth), but it's useful standalone for anyone who wants a small,
type-cast-aware data layer that doesn't ship an ORM.

---

## Install

Not on Quicklisp yet — symlink the checkout:

```sh
git clone https://github.com/gr8distance/clecto.git ~/src/clecto
ln -s ~/src/clecto ~/quicklisp/local-projects/clecto
```

```lisp
(ql:quickload :clecto)             ; core + SQLite adapter
(ql:quickload :clecto/postgres)    ; optional: PostgreSQL adapter
```

You need a SQLite library installed (`brew install sqlite` /
`apt install libsqlite3-dev` etc.) for the default adapter. The
Postgres adapter pulls `postmodern`.

---

## Quickstart

```lisp
(defpackage #:demo
  (:use #:cl #:clecto)
  (:shadowing-import-from #:clecto #:union))   ; clecto exports a UNION
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

That's the whole shape: build a value (the changeset), hand it to
the repo, get back a record or a changeset with errors.

---

## Documentation

clecto is documented as topic pages under [`docs/`](./docs/).

**Core**

- [Overview](./docs/overview.md) — philosophy, layers, request lifecycle
- [schema](./docs/schema.md) — `defschema`, field types, associations, timestamps
- [changeset](./docs/changeset.md) — `cast`, validators, constraints, `traverse-errors`
- [query](./docs/query.md) — `from`/`where`/`select`/`join`, subqueries, CTEs, fragments
- [repo](./docs/repo.md) — CRUD, bulk operations, preloading, transactions

**Lower layers**

- [adapter](./docs/adapter.md) — protocol, SQLite, PostgreSQL, writing your own
- [sql](./docs/sql.md) — the compiler internals, fragment escape hatch
- [telemetry](./docs/telemetry.md) — observability hooks

**Cross-cutting**

- [Cookbook](./docs/cookbook.md) — full patterns
- [Testing](./docs/testing.md) — testing without (and with) a real database

---

## Schema applied to your DB

clecto does **not** ship a migration runner. Define your schemas
with `defschema`, and apply DDL with whatever tool you already
use:

- **Per-library docs** — each clecto-using library (e.g.
  [clauth](https://github.com/gr8distance/clauth/blob/main/docs/schema.md))
  ships its own `docs/schema.md` documenting the SQL it expects
  for SQLite and PostgreSQL, plus examples for `dbmate`,
  `golang-migrate`, and `goose`.
- **For your own tables**, write the DDL as you see fit. clecto
  doesn't introspect your schema; everything is declared via
  `defschema`.

The data layer is intentionally separate from schema lifecycle.
See the docs/schema.md pages in each library, and pick a
migration tool that fits your stack.

---

## What's intentionally out of scope

| not in clecto | reason / alternative |
| ------------- | -------------------- |
| migrations         | external tools (`dbmate` / `golang-migrate` / `goose` / sqitch) |
| connection pooling | adapter-specific — postmodern has a pool, cl-dbi has a pool |
| schema introspection from the DB | schemas are declared, not inferred |
| auto-loading associations on attribute access | `repo-preload` is explicit |
| ORM-style objects with identity | records are plists |
| caching                          | application-layer concern |
| LiveView / PubSub / Mailer       | separate Lisp ports (clauth, cliam, …) |

---

## Source layout

```
src/
  schema.lisp          ; defschema, fields, types, timestamps helpers
  changeset.lisp       ; cast, validators, traverse-errors, constraints
  query.lisp           ; from / where / select / ... AST builders
  sql.lisp             ; compiler state, entry points
  sql-expr.lisp        ; expression compiler (where / having / ON / SET RHS)
  sql-select.lisp      ; SELECT compiler (joins, CTEs, distinct, set ops, lock)
  sql-mutation.lisp    ; INSERT (with RETURNING / ON CONFLICT), UPDATE, DELETE
  adapter.lisp         ; protocol generic functions
  adapters/sqlite.lisp ; SQLite adapter
  adapters/postgres.lisp ; PostgreSQL adapter (clecto/postgres system)
  telemetry.lisp       ; *telemetry* hook
  repo.lisp            ; the side-effect boundary
```

Each file is small and orthogonal — read whichever covers what
you're touching.

---

## Run the tests

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :clecto/tests)' \
     --eval '(asdf:test-system :clecto)'
```

143 tests covering schema, changeset, query AST, SQL emission,
SQLite round-trips (insert / select / update / delete /
transactions / constraints / preload / upsert / bulk / embeds),
Postgres SQL emission via a mock adapter, telemetry, and
security guards (numeric parsing caps, identifier escaping,
ORDER BY whitelisting, lock-mode whitelisting).

---

## License

MIT
