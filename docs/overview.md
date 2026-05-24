# Overview

clecto is a data layer built around three ideas:

1. **Data describes data.** Schemas, queries, and changesets are
   plain values — structs holding plists of field metadata, AST
   nodes, accumulated changes. No CLOS instances with mutable
   slots, no metaprogramming reaching into the database.

2. **Everything immutable except the repo.** Casting, validating,
   composing queries — all return new values. The repo is the
   *only* thing that touches I/O, and the only place mutation
   actually happens.

3. **The compiler is pure.** A query AST plus an adapter produces
   `(values sql params)` deterministically. Swapping SQLite for
   Postgres swaps the adapter; the query you wrote doesn't change.

This page sketches how the pieces fit. Each piece has its own
doc — links at the bottom.

---

## The shape of a request

A typical "create a user" lifecycle looks like:

```
   user-supplied attrs (a plist)
              │
              ▼
       cast → validate-*           ← pure changeset pipeline
              │                       (no DB access yet)
              ▼
       changeset (valid?)
              │
              ▼
       repo-insert (or update / delete)   ← the only I/O step
              │
              ▼
        record plist or
        changeset with errors
```

Every step before the repo call is value-in / value-out. You can
inspect the changeset, log it, fork it for retry, test it without
a database. Errors from validation accumulate on the changeset
without raising.

The repo turns a valid changeset into SQL + parameters, runs them
through the adapter, and gives you back either the inserted record
(as a plist) or the changeset with DB-side errors attached
(unique-constraint violations, foreign-key violations, etc.).

---

## The layers

| Layer | What it owns | Doc |
| ----- | ------------ | --- |
| **schema**     | Field metadata, associations, primary key, timestamps flag | [schema](./schema.md) |
| **changeset**  | Cast → validate pipeline producing an immutable validation result | [changeset](./changeset.md) |
| **query**      | A data AST built by chainable functions (`from`/`where`/...) | [query](./query.md) |
| **sql**        | Pure AST → SQL string + parameter list compiler | [sql](./sql.md) |
| **adapter**    | Generic-function protocol: execute, quote, placeholder, etc. | [adapter](./adapter.md) |
| **repo**       | The I/O boundary — combines schema + changeset + query + adapter | [repo](./repo.md) |
| **telemetry**  | A single callable invoked around every query | [telemetry](./telemetry.md) |

You usually don't touch the SQL compiler directly — the repo
drives it. But it's exposed so you can pre-compile a query, peek
at the generated SQL, or compile against a non-default adapter.

---

## Two flavors of pipeline

clecto deliberately re-uses the "build a value through chained
calls" pattern in two contexts:

**Changeset pipeline** (validation):

```lisp
(-> (cast 'user attrs '(:email :age :password))
    (validate-required '(:email))
    (validate-format    :email "@")
    (validate-length    :password :min 12)
    (validate-confirmation :password)
    (unique-constraint  :email))
```

**Query pipeline** (DB read):

```lisp
(-> (from :users)
    (where '(= :active t))
    (where '(>= :age 18))
    (order-by '((:desc :inserted-at)))
    (limit 50))
```

Both are sequences of `(value → value)` calls. Both compose freely
— stash intermediate values in variables, splice with
`alexandria:if-let`, branch with `where-if`. Both are testable
without a database.

The repo functions are the **only** place these pipelines actually
do anything observable.

---

## The minimum app

```lisp
(defpackage #:demo
  (:use #:cl #:clecto)
  (:shadowing-import-from #:clecto #:union))    ; clecto exports a UNION
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
```

The `->` macro isn't part of clecto — it's just a thread-first
helper to keep changesets readable. Use your project's preferred
threading macro, or `let*`, or `cl-arrows`.

---

## The package convention

clecto exports a function named `union` (for SQL `UNION`), which
shadows `cl:union`. If you `:use #:clecto` in a package, also
`:shadowing-import-from #:clecto #:union` (and `#:intersection`
/ `#:set-difference` if you want those).

If you don't want the shadow, qualify: `clecto:union`.

---

## What clecto deliberately doesn't do

| not in clecto | use this instead |
| ------------- | ---------------- |
| migrations         | external tools — `dbmate`, `golang-migrate`, `goose`, sqitch |
| connection pooling | adapter-specific — `cl-dbi` pools work for Postgres |
| schema introspection | not provided; declare schemas with `defschema` |
| caching            | not provided; cache at your application layer |
| ORM-style objects  | not provided — records are plists |
| auto-loading associations on attribute access | use `repo-preload` explicitly |

The first one is the most-asked-about: see the project README and
each library's `docs/schema.md` for the SQL and tool examples.

---

## Reading order

1. **[schema](./schema.md)** — declare your tables
2. **[changeset](./changeset.md)** — validate user input
3. **[query](./query.md)** — express reads as values
4. **[repo](./repo.md)** — touch the DB

Then:

5. **[adapter](./adapter.md)** — SQLite, Postgres, writing your own
6. **[sql](./sql.md)** — the compiler, fragments, escape hatches
7. **[telemetry](./telemetry.md)** — observability

Cross-cutting:

8. **[cookbook](./cookbook.md)** — full patterns
9. **[testing](./testing.md)** — testing without a real database
