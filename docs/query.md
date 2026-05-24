# query

A query is a **value**. The query builders (`from`, `where`,
`select`, `join`, etc.) return new query values without touching
the database. The repo turns a query into SQL the moment it
actually needs to run.

This separation means you can build queries incrementally, fork
them, log them, test them, compile them against multiple adapters,
or hand them to subqueries — all without I/O.

---

## Quick example

```lisp
(-> (from :users)
    (where '(= :active t))
    (where '(>= :age 18))
    (where-if min-followers `(>= :followers ,min-followers))
    (order-by '((:desc :inserted-at)))
    (limit 50))
```

Each call returns a new query value. The repo compiles it via the
adapter just before execution.

---

## Building queries

### `(from TABLE) → QUERY`

Start a query against TABLE. TABLE is a keyword (the typical
case), a string, or a `subquery` value.

```lisp
(from :users)
;; => query with :table :users
```

Note the leading colon: clecto treats CL keywords as table /
column references and converts them to snake_case at SQL render
time. So `(from :user-roles)` compiles to `FROM "user_roles"`.

### `(where Q EXPR) → QUERY`

Add a WHERE clause. Multiple `where` calls accumulate — they're
AND-combined at compile time.

```lisp
(-> (from :users)
    (where '(= :active t))           ; WHERE active = ?
    (where '(>= :age 18)))            ; AND age >= ?
```

EXPR is an S-expression. See **Where expressions** below.

### `(where-if Q CONDITION EXPR) → QUERY`

Apply WHERE only when CONDITION is truthy. Avoids `if`-wrapping
every conditional filter:

```lisp
(-> (from :users)
    (where-if min-age `(>= :age ,min-age))
    (where-if role    `(= :role ,role)))
```

### `(and-filters &rest EXPRS) → EXPR | NIL`

AND-combine zero or more filter expressions, dropping `NIL`s.
Returns `NIL` when nothing remains, the single expression when
only one is non-NIL, otherwise `(and ...)`.

```lisp
(and-filters (when starts `(>= :inserted-at ,starts))
             (when ends   `(<= :inserted-at ,ends)))
;; → nil / single expr / (AND ...) — feed straight into WHERE
```

### `(select Q FIELDS) → QUERY`

Restrict the SELECT clause. FIELDS is a keyword or list:

```lisp
(select q :id)              ; SELECT "id"
(select q '(:id :email))    ; SELECT "id", "email"
```

Without `select`, the query emits `SELECT *`.

### `(order-by Q ORDERS) → QUERY`

ORDERS is a list of `(:direction :column)` pairs. `:asc` or
`:desc`:

```lisp
(order-by q '((:desc :inserted-at) (:asc :id)))
;; ORDER BY "inserted_at" DESC, "id" ASC
```

### `(limit Q N) → QUERY` / `(offset Q N)`

Standard pagination. Both must be non-negative integers (enforced
at compile time):

```lisp
(-> q (limit 25) (offset 50))
```

### `(join Q KIND TABLE ON) → QUERY`

Add a JOIN. KIND is `:inner` / `:left` / `:right` / `:full`;
TABLE is a keyword or subquery; ON is a where-expression.

```lisp
(-> (from :posts)
    (join :inner :users '(= :posts.user-id :users.id))
    (where '(= :users.active t)))
;; FROM "posts"
;; INNER JOIN "users" ON "posts"."user_id" = "users"."id"
;; WHERE "users"."active" = ?
```

Qualified column names use dot syntax in keywords: `:posts.user-id`
compiles to `"posts"."user_id"`.

### `(group-by Q COLS)` / `(having Q EXPR)`

Standard SQL group/having semantics:

```lisp
(-> (from :events)
    (select '((:count *) :event-type))
    (group-by :event-type)
    (having '(> (:count *) 100)))
```

### `(distinct Q &optional ON)` 

```lisp
(distinct q)              ; SELECT DISTINCT ...
(distinct q :user-id)     ; SELECT DISTINCT ON ("user_id") ...   (Postgres)
(distinct q '(:user-id :date))
```

### `(lock Q KIND)`

Add row-level locking. KIND is `:for-update`, `:for-share`,
`:no-key-update`, or `:key-share`:

```lisp
(-> (from :accounts)
    (where '(= :id 1))
    (lock :for-update))
;; SELECT * FROM "accounts" WHERE "id" = ? FOR UPDATE
```

### `(with-prefix Q PREFIX)`

Set a schema/db prefix so the from-table renders as
`PREFIX.table`:

```lisp
(with-prefix q "public")
;; FROM "public"."users"
```

---

## Where expressions

WHERE conditions are S-expressions. The grammar:

| Form | SQL |
| ---- | --- |
| `(= COL VALUE)`           | `"col" = ?` |
| `(<> COL VALUE)`          | `"col" <> ?` |
| `(< COL VALUE)`           | `"col" < ?` |
| `(<= COL VALUE)`          | `"col" <= ?` |
| `(> COL VALUE)`           | `"col" > ?` |
| `(>= COL VALUE)`          | `"col" >= ?` |
| `(in COL (V1 V2 ...))`    | `"col" IN (?, ?, ...)` |
| `(in COL SUBQUERY)`       | `"col" IN (SELECT ...)` |
| `(like COL "pat%")`       | `"col" LIKE ?` |
| `(is-null COL)`           | `"col" IS NULL` |
| `(is-not-null COL)`       | `"col" IS NOT NULL` |
| `(and EXPR EXPR ...)`     | `(... AND ...)` |
| `(or EXPR EXPR ...)`      | `(... OR ...)` |
| `(not EXPR)`              | `(NOT ...)` |
| `(:fragment "raw sql" ...)` | raw SQL with `?` holes filled by safe parameters |

Operator names are matched **case-insensitively** by `symbol-name`,
so `'=` and `'CL:=` both work — and you don't need to import
clecto's operator symbols into your package.

Examples:

```lisp
(where q '(in :role ("admin" "moderator")))
(where q '(or (= :status "active") (= :status "pending")))
(where q '(and (is-not-null :email) (like :email "%@example.com")))
```

Column references on **both sides** work too:

```lisp
(where q '(< :created-at :updated-at))
;; "created_at" < "updated_at"
```

A keyword is treated as a column ref; a non-keyword literal
becomes a parameter.

### Fragments — the escape hatch

`(:fragment "raw sql" arg1 arg2 ...)` interpolates each `?` in
the template with a safe parameter:

```lisp
(where q '(:fragment "lower(:email) = lower(?)" "alice@example.com"))
;; lower("email") = lower(?)
```

Keyword args (like `:email` above) are inlined as column
references; non-keyword args become parameters. The template
itself is treated as raw SQL — **do not** thread untrusted input
into the template string.

A length cap (`*fragment-template-cap*`, default 64KB) catches
accidental threading of unbounded user input — clauth's atomic
counter increment uses fragments and the cap keeps even buggy
callers contained.

---

## Subqueries

Use a query as a from-source or as the right side of an `IN`:

```lisp
(defparameter *recent-orders*
  (-> (from :orders)
      (where `(>= :created-at ,(some-date)))
      (select '(:user-id))))

(-> (from :users)
    (where `(in :id ,(subquery *recent-orders*))))
;; FROM "users" WHERE "id" IN (SELECT "user_id" FROM "orders" WHERE ...)

;; or use it as a from-source:
(-> (from (subquery *recent-orders* :alias :ro))
    (join :inner :users '(= :ro.user-id :users.id)))
```

`subquery` wraps a query so the compiler knows to render it
parenthesized with an alias.

---

## CTEs (WITH clauses)

```lisp
(with-cte (from :result)
          :result
          (-> (from :users) (where '(= :active t))))
;; WITH "result" AS (SELECT * FROM "users" WHERE "active" = ?)
;; SELECT * FROM "result"
```

Multiple CTEs chain by calling `with-cte` repeatedly. They render
in declaration order, comma-separated.

---

## Set operations

Combine queries with `UNION` (clecto-shadowed),
`union-all`, `intersect`, `except`:

```lisp
(-> q1 (union q2))
(-> q1 (union-all q2))
(-> q1 (intersect q2))
(-> q1 (except q2))
```

Note: clecto exports a function named `union` that shadows
`cl:union`. If you `:use #:clecto`, also `:shadowing-import-from
#:clecto #:union` — or qualify as `clecto:union`.

---

## Aggregates

In `select`, group-by columns, or `having` expressions, use
aggregate forms:

```lisp
(-> (from :events)
    (select '((:count *)              ; COUNT(*)
              (:sum :amount)           ; SUM("amount")
              (:avg :duration)         ; AVG("duration")
              :event-type))            ; "event_type"
    (group-by :event-type))
```

Supported aggregates: `:count`, `:sum`, `:avg`, `:min`, `:max`.
`*` (or `:*` or `"*"`) means "all rows" — only useful inside
`:count`.

---

## Inspecting a query

The struct accessors are exported:

```lisp
(let ((q (-> (from :users) (where '(= :active t)) (limit 10))))
  (query-table q)        ; :users
  (query-wheres q)       ; ((= :active t))
  (query-limit q)        ; 10
  (query-offset q))      ; NIL
```

Useful in tests and when debugging "why doesn't this query do
what I think it does."

---

## Compiling a query manually

The repo compiles queries automatically. If you want to peek at
the SQL or compile against a non-default adapter:

```lisp
(let ((sqlite (make-sqlite-adapter ":memory:"))
      (q (-> (from :users) (where '(= :active t)) (limit 10))))
  (to-sql sqlite q))
;; → (values "SELECT * FROM \"users\" WHERE \"active\" = ? LIMIT 10"
;;           (t))   ; the params, in order
```

`to-sql` is the public entry point that delegates to `select-sql`
internally. See [sql](./sql.md) for the compiler internals.

---

## Snippets

**Pagination helper:**

```lisp
(defun paginate (q &key (page 1) (per-page 25))
  (-> q
      (limit per-page)
      (offset (* per-page (1- page)))))
```

**Filter that adds zero or more WHEREs:**

```lisp
(defun search-users (&key q role active)
  (-> (from :users)
      (where-if q       `(like :email ,(format nil "%~a%" q)))
      (where-if role    `(= :role ,role))
      (where-if active  `(= :active ,active))
      (order-by '((:desc :inserted-at)))))
```

`where-if` keeps each branch one line. If none of the filters
fire, the query is a plain `SELECT * FROM users ORDER BY ...`.

**An EXISTS-style check:**

```lisp
(defun user-has-recent-post-p (repo user-id since)
  (repo-exists-p repo
                 (-> (from :posts)
                     (where `(= :user-id ,user-id))
                     (where `(>= :inserted-at ,since)))))
```

**Aggregate-as-where via GROUP BY + HAVING:**

```lisp
(defun popular-tags (repo &key (min-count 10))
  (repo-all
   repo
   (-> (from :tags)
       (select '((:count :id) :name))
       (group-by :name)
       (having `(> (:count :id) ,min-count))
       (order-by '((:desc (:count :id)))))))
```

**A query that joins, filters on the joined side, and selects from
both:**

```lisp
(-> (from :posts)
    (join :inner :users '(= :posts.user-id :users.id))
    (where '(= :users.role "admin"))
    (select '(:posts.id :posts.title :users.email))
    (order-by '((:desc :posts.inserted-at)))
    (limit 50))
```

---

## Gotchas

- **Composition order matters for joins**. The order you `join` is
  the order they appear in SQL. If a later JOIN references an
  alias from an earlier one, declare them in dependency order.
- **`where` always AND-combines**. For OR across separate
  `where` calls, use `(or ...)` inside a single `where`.
- **`select` replaces, doesn't append**. Each `select` call
  replaces the prior column list. To extend, build the list
  separately.
- **`order-by` accumulates**. Multiple calls compose ORDER BY
  pairs in declaration order.
- **Keywords are always identifiers**. To pass a literal
  keyword as a value (e.g. an `:enum` column), it goes through
  cast at the changeset / parameter binding layer — not via a
  bare keyword in a where expression.
