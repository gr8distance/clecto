# sql

The SQL compiler turns a query AST into `(values sql-string
params)`. It's a pure function — same AST + same adapter →
same SQL — and adapter-driven, so dialect specifics (placeholder
syntax, identifier quoting, RETURNING support) live in the
adapter instead of in the compiler.

You usually don't call the compiler directly. The repo runs it
during `repo-all` / `repo-insert` / etc. This page is for two
audiences:

1. People debugging "why does this query produce that SQL?"
2. People writing custom adapters or doing advanced things like
   fragments.

---

## The entry point

### `(to-sql ADAPTER QUERY) → (values SQL-STRING PARAMS)`

Compile a query against an adapter and return the rendered SQL
and the parameter list.

```lisp
(let ((adapter (make-sqlite-adapter ":memory:"))
      (q (-> (from :users)
             (where '(= :active t))
             (where '(>= :age 18))
             (limit 10))))
  (to-sql adapter q))
;; => "SELECT * FROM \"users\" WHERE \"active\" = ? AND \"age\" >= ? LIMIT 10"
;;    (T 18)
```

Useful for:

- Printing the SQL during debugging
- Pre-compiling a query against a non-default adapter
- Snapshot-testing query output

---

## Sub-compilers

The compiler is split into three files; each handles one
statement family. They share a tiny state struct passed via
`sql-state` and a small set of helpers (`emit-param`, `qi`,
`compile-expr`).

| Sub-compiler | Statements |
| ------------ | ---------- |
| `sql-expr.lisp`     | WHERE expressions, JOIN ON, HAVING, SET RHS |
| `sql-select.lisp`   | SELECT (including CTEs, joins, combinators, lock, distinct) |
| `sql-mutation.lisp` | INSERT (with ON CONFLICT, RETURNING), UPDATE, DELETE |

You generally only invoke the entry points the repo uses:

- `select-sql` — drives every read
- `insert-sql`, `insert-all-sql` — drive `repo-insert` /
  `repo-insert-all`
- `update-sql`, `delete-sql` — drive `repo-update` /
  `repo-update-all` / `repo-delete` / `repo-delete-all`

All four return `(values sql params)` and accept the adapter as
the first argument.

---

## Where-expressions

A where-expression is an S-expression compiled by `compile-expr`.
Documented in detail in [query](./query.md); short version:

- A **keyword** is a column reference. `:user-id` →
  `"user_id"` (snake-cased and quoted).
- A **literal scalar** is bound as a parameter.
- A **cons form** is dispatched on its head:

| Head                    | Becomes |
| ----------------------- | ------- |
| `=` / `<>` / `<` / `<=` / `>` / `>=` | binary infix operator |
| `and` / `or` / `not`    | combinators |
| `in`                    | `col IN (vals)` or `col IN (subquery)` |
| `like`                  | `col LIKE ?` |
| `is-null` / `is-not-null` | `col IS [NOT] NULL` |
| `:fragment`             | raw SQL with `?` holes substituted |
| `:count` / `:sum` / `:avg` / `:min` / `:max` | aggregates (in SELECT / GROUP BY) |

Operator names are matched **case-insensitively** by symbol-name.
That's why `'=` and `'cl:=` and a symbol named `=` in any
package all work.

The compiler errors on unknown operators rather than silently
emitting nonsense SQL:

```lisp
(where q '(matches :email "..."))
;; → error: Unknown where operator: MATCHES
```

---

## Fragments — the raw-SQL escape hatch

Sometimes you need a SQL idiom clecto's expression grammar
doesn't model — `JSON_EXTRACT(col, '$.key')`, `LOWER(col)`,
window functions, vendor-specific functions, etc. Fragments let
you write raw SQL with placeholder substitution:

```lisp
'(:fragment "lower(:email) = lower(?)" "Alice@example.com")
;; →  lower("email") = lower(?)
;;    params: ("Alice@example.com")
```

In the template, `?` means "consume the next argument from the
arglist." Arguments are compiled as operands: a keyword inlines
as a column reference, a non-keyword binds as a parameter.

```lisp
;; clauth's atomic counter increment looks like this:
(repo-update-all *repo*
                 (-> (from :users) (where `(= :id ,user-id)))
                 (list :failed-login-count
                       '(:fragment "failed_login_count + 1")))
;; UPDATE "users" SET "failed_login_count" = failed_login_count + 1
;; WHERE "id" = ?
```

A fragment in a WHERE position:

```lisp
(where q '(:fragment "json_extract(:data, '$.tier') = ?" "pro"))
```

### Safety

`:fragment` is a **developer-trust contract**: the template string
is treated as raw SQL. *Never* thread untrusted input into a
fragment template. The compiler enforces one defense:

- `*fragment-template-cap*` (default 64 KB) — templates longer
  than this signal an error. Catches accidental threading of
  unbounded user input from places where it shouldn't happen.

For everything else, the contract is yours to keep. Treat
fragment templates like format strings: they're code, not data.

---

## Where the SQL comes from

For each repo call, the lifecycle is:

```
   query value                       changeset value
      │                                    │
      ▼                                    ▼
   to-sql / select-sql              insert-sql / update-sql / delete-sql
      │                                    │
      ▼                                    ▼
   (sql, params)                     (sql, params)
      │                                    │
      ▼                                    ▼
   adapter-execute                   adapter-execute-returning
```

For SELECTs the path is straightforward — the query is the AST.
For mutations, the repo first runs `prepare-row` on the
changeset (strip metadata, stamp timestamps, drop virtuals,
encode embeds), then hands the resulting plist to the mutation
sub-compiler.

---

## Identifier handling

Every identifier goes through `adapter-quote-identifier` (default
method: ANSI double-quoted). The default method also:

- Splits qualified names (`:users.id` → `"users"."id"`)
- Doubles embedded double-quotes per ANSI
- Rejects NUL bytes outright (those would terminate the C-side
  string the driver hands to the DB)

So even with hostile column names the rendered SQL is well-formed.

The compiler keeps everything as plain strings — no special
"identifier" wrapper type. Each operator's compiler emits
`(qi adapter col)` where it needs an identifier, and
`(emit-param st value)` where it needs a placeholder. There's no
syntactic ambiguity because column refs are always keywords and
parameters are always non-keywords.

---

## Parameter handling

`emit-param` accumulates parameters into the `sql-state` and
returns the placeholder string for the adapter:

```lisp
(defun emit-param (st value)
  (incf (sql-state-index st))
  (push value (sql-state-params st))
  (adapter-placeholder (sql-state-adapter st) (sql-state-index st)))
```

The `index` is 1-based — exactly what Postgres wants for `$N`
placeholders. SQLite's placeholder doesn't care about the index;
the default method just returns `"?"`.

At the end of compilation, the accumulated list is reversed (it
was built head-first) and returned as the params list.

---

## What the compiler does NOT do

- **Validate queries semantically.** A WHERE on a non-existent
  column compiles; the DB returns the error. The compiler doesn't
  inspect the schema.
- **Pretty-print.** Output is one line of SQL. For
  human-readable debugging, run it through `(sql-format ...)` in
  your DB tool — or implement a pretty-printer downstream.
- **Cache compiled SQL.** Each repo call re-compiles. Repeated
  reads of the same query are cheap (the compiler is small), but
  if you're running the same query thousands of times in a hot
  loop, compile once and pass `(sql, params)` to
  `adapter-execute` directly.

---

## Pre-compiling for hot paths

The repo calls compile on every request. For a query that runs
thousands of times in a tight loop, pre-compile once:

```lisp
(let ((adapter (repo-adapter *repo*)))
  (multiple-value-bind (sql template-params)
      (to-sql adapter
              (-> (from :users) (where '(= :active t)) (limit 100)))
    ;; reuse sql + adjust params per call:
    (loop repeat 10000
          do (clecto:adapter-execute adapter sql template-params))))
```

For queries with **variable** parameters per call, you'd
parameterize differently — or just accept the compilation cost,
which is in single-digit microseconds for typical queries.

---

## Snippets

**Peek at the SQL a query produces:**

```lisp
(multiple-value-bind (sql params)
    (to-sql (repo-adapter *repo*)
            (-> (from :users) (where '(= :email "a@x"))))
  (format t "~a~%params: ~a~%" sql params))
;; SELECT * FROM "users" WHERE "email" = ?
;; params: (a@x)
```

**Fragment with a real-world idiom (Postgres `ILIKE`):**

```lisp
(where q '(:fragment ":email ILIKE ?" "%@example.com"))
;; "email" ILIKE ?
```

**Fragment for `coalesce`:**

```lisp
(where q '(:fragment "coalesce(:nickname, :email) = ?" "alice"))
```

**Fragment with multiple parameters:**

```lisp
(where q '(:fragment "extract(year from :created-at) BETWEEN ? AND ?"
                     2020 2026))
```

The compiler walks `?` characters in the template and consumes
arguments left-to-right. Argument order in the form must match
order in the template.

---

## Gotchas

- **`:fragment` is raw SQL.** Don't string-format user input into
  the template — bind via `?` instead.
- **Aggregate position matters.** `(:count *)` works inside
  `select`, `group-by`, and `having`. Outside those, the
  compiler will treat it like an unknown operator and error.
- **`(or expr1 expr2 ...)` vs `(in col (...))`.** Both can
  express "match one of these values" but `IN` is what the DB
  optimiser likes; prefer it when matching a column against a
  list of literals.
- **Identifiers with embedded dots.** `:users.id` splits on the
  first `.`; you can't have a column or table name that actually
  contains a dot. (Don't do that anyway.)
