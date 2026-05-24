# adapter

Adapters describe how to talk to a particular database. The
protocol is a tiny set of generic functions; clecto ships two
implementations (SQLite, PostgreSQL) and gives you everything you
need to write more.

The repo holds an adapter and delegates I/O to it. Everything
above the repo (schema / changeset / query / SQL compiler) is
adapter-agnostic.

---

## SQLite

In clecto core — no extra load needed.

```lisp
(defparameter *adapter* (make-sqlite-adapter ":memory:"))
(defparameter *repo*    (make-repo *adapter*))

;; later
(sqlite-close *adapter*)   ; close the underlying connection
```

`make-sqlite-adapter` takes a path string. `":memory:"` is the
in-process anonymous database. A real path lazily opens the file
(creating it if it doesn't exist).

The adapter uses the `cl-sqlite` library under the hood. A
recursive lock around every connection-touching method allows
nested transactions on the same thread while serializing across
threads (so prepare/step/finalize never interleave between
threads sharing one connection).

Notes:

- **Boolean storage**: `t` / `nil` round-trip as `1` / `0`.
  Reads come back as `t` / `nil` thanks to schema-aware decoding.
- **Foreign keys**: SQLite has `PRAGMA foreign_keys` off by
  default. Enable it explicitly if you depend on FK enforcement:
  `(repo-execute *repo* "PRAGMA foreign_keys = ON")`.
- **DDL changes**: SQLite's `ALTER TABLE` is restricted. Modern
  versions (3.35+) added `DROP COLUMN`; older versions need a
  rename-and-rebuild dance.

---

## PostgreSQL

Opt-in via `clecto/postgres`:

```lisp
(ql:quickload :clecto/postgres)

(defparameter *adapter*
  (make-postgres-adapter
   :host     "localhost"
   :port     5432
   :database "myapp"
   :user     "myapp"
   :password (uiop:getenv "DB_PASSWORD")))

(defparameter *repo* (make-repo *adapter*))

;; later
(postgres-close *adapter*)
```

Built on `postmodern`. The adapter supports `RETURNING` so
`repo-insert` gets the inserted row in one round-trip (including
server-defaulted columns). Constraint translation maps PostgreSQL
SQLSTATE codes to declared changeset constraints — `23505` to
`:unique`, `23503` to `:foreign-key`, `23514` to `:check`.

Notes:

- **Connection pooling** is delegated to postmodern / cl-dbi.
  clecto doesn't own it; configure per your deployment.
- **Boolean storage**: native `boolean`. `t` / `nil` round-trip
  cleanly.
- **Timestamps**: stored as `timestamp without time zone` to match
  clecto's `:naive-datetime` type. UTC is enforced at the
  application layer.
- **DDL**: full `ALTER TABLE` support; migrations don't have the
  SQLite restrictions.

---

## The adapter protocol

Adapter is a CLOS class hierarchy. To add a backend:

1. Define a subclass of `clecto:adapter`.
2. Specialize the generic functions below for it.
3. Provide a constructor and a close helper.

The protocol breaks down into three groups: **execution**,
**dialect**, **transactions**.

### Execution

#### `(adapter-execute ADAPTER SQL PARAMS) → LIST-OF-PLISTS`

Execute SQL (typically a SELECT) and return the result rows as
plists. PARAMS is a list of values in placeholder order.

#### `(adapter-execute-returning ADAPTER SQL PARAMS) → (values ROWS-AFFECTED LAST-INSERT-ID)`

Execute a mutating statement. The default contract is to return
counts. Adapters that support `RETURNING` (Postgres) can
specialize this to return the inserted rows directly — the repo
detects support via `adapter-supports-returning-p`.

#### `(adapter-supports-returning-p ADAPTER) → BOOLEAN`

True if the adapter prefers `INSERT ... RETURNING ...` over a
`last_insert_rowid()` round-trip. Defaults to `NIL`.

### Dialect

#### `(adapter-quote-identifier ADAPTER NAME) → STRING`

Quote a column or table identifier per the adapter's dialect.
Handles qualified names like `:users.id` → `"users"."id"`.

The default method handles ANSI double-quoted identifiers. SQLite
and Postgres both inherit it; an adapter for a database with
different quoting (MySQL backticks, e.g.) would specialize.

#### `(adapter-placeholder ADAPTER INDEX) → STRING`

Render the Nth (1-based) placeholder. Default is `"?"` (SQLite,
generic). Postgres specializes to `"$1"`, `"$2"`, etc.

### Transactions

#### `(adapter-begin ADAPTER)` / `(adapter-commit ADAPTER)` / `(adapter-rollback ADAPTER)`

Standard BEGIN / COMMIT / ROLLBACK. Adapters that support
savepoints can use them for nested transactions — the repo's
`repo-transaction` macro handles nesting by counting depth and
delegating to the adapter.

### Constraint translation

#### `(adapter-translate-constraint-error ADAPTER CONDITION CONSTRAINTS) → (values FIELD MESSAGE) | NIL`

Inspect a DB error against the list of declared `:constraints` on
a changeset. Return `(values field message)` when a match is found;
`NIL` otherwise.

Each adapter implements this for its dialect:

- SQLite: parses error strings (`"UNIQUE constraint failed: users.email"` →
  match against `:unique` constraints on `:email`)
- Postgres: switches on SQLSTATE codes from the postmodern condition

The repo uses this to convert DB errors into changeset errors
(see [changeset](./changeset.md)'s constraint declarations).

---

## Writing a custom adapter

Skeleton for a hypothetical adapter:

```lisp
(defclass my-adapter (clecto:adapter)
  ((conn :initarg :conn :reader my-adapter-conn)))

(defun make-my-adapter (&key host db ...)
  (make-instance 'my-adapter :conn (open-connection ...)))

(defun my-adapter-close (a)
  (close-connection (my-adapter-conn a)))

;;; Execution
(defmethod clecto:adapter-execute ((a my-adapter) sql params)
  ;; run sql with params; return list of plists
  ...)

(defmethod clecto:adapter-execute-returning ((a my-adapter) sql params)
  ;; run mutating sql; return (values rows-affected last-id)
  ...)

;;; Dialect
(defmethod clecto:adapter-placeholder ((a my-adapter) index)
  (format nil "$~a" index))    ; or "?", or ":N", etc.

(defmethod clecto:adapter-supports-returning-p ((a my-adapter)) t)

;;; Transactions
(defmethod clecto:adapter-begin    ((a my-adapter)) ...)
(defmethod clecto:adapter-commit   ((a my-adapter)) ...)
(defmethod clecto:adapter-rollback ((a my-adapter)) ...)

;;; Constraint translation
(defmethod clecto:adapter-translate-constraint-error
    ((a my-adapter) condition constraints)
  ;; inspect condition; match against constraints; return (values field msg)
  ...)
```

A few practical tips:

- **Lock the connection** if your underlying driver isn't
  thread-safe. The SQLite adapter shows how — a recursive lock
  around every method that touches the connection. The
  recursive flavor is important: nested `repo-transaction` calls
  reach `adapter-begin` twice on the same thread.
- **Decode columns lazily**. Column-name → keyword conversion
  goes through `clecto::lispify-column`, which is bounded-cache
  by default. Reuse it; don't write your own intern loop.
- **Don't let the connection escape**. Adapter constructors
  should own the connection lifetime. Expose a close helper so
  callers can shut down cleanly.

---

## Identifier and parameter conventions

The compiler delegates everything dialect-specific to the
adapter:

- **Identifiers** flow through `adapter-quote-identifier`. NUL
  bytes inside an identifier signal an error outright; double
  quotes are doubled per ANSI rules.
- **Parameters** flow through `adapter-placeholder` numbered
  starting at 1. SQLite stays at `?` regardless; Postgres
  produces `$1`, `$2`, ...
- **Snake_case conversion** happens at the compiler level via
  `sqlify-column`. Adapters never see CL keywords.

This separation means the same query AST compiles cleanly to
both SQLite and Postgres SQL — only the rendered strings differ.

---

## Error wrapping

Adapters generally let the underlying driver's conditions
propagate. The repo's mutation helpers wrap unmatched conditions
in `clecto:db-error`, which (a) hides the original message from
the default reporter (some drivers leak row data into error
messages), and (b) lets callers do `handler-case
(clecto:db-error ...)` without coupling to the specific driver
type.

If you need the original condition, it's at
`(db-error-original e)`. The original SQL (if recorded) is at
`(db-error-sql e)`.

---

## Snippets

**Switching adapters at runtime (e.g. dev vs prod):**

```lisp
(defun make-app-repo ()
  (let ((url (uiop:getenv "DATABASE_URL")))
    (cond
      ((null url)
       (make-repo (make-sqlite-adapter "dev.db")))
      ((search "postgres://" url)
       (make-repo (make-postgres-adapter :url url)))
      (t (error "Unknown DATABASE_URL: ~s" url)))))
```

**Closing the connection at shutdown:**

```lisp
(defun shutdown-app ()
  (when *repo*
    (let ((a (repo-adapter *repo*)))
      (etypecase a
        (sqlite-adapter   (sqlite-close a))
        (postgres-adapter (postgres-close a))))
    (setf *repo* nil)))
```

**Custom adapter that delegates to an existing one (decorator
pattern):**

```lisp
(defclass logged-adapter (clecto:adapter)
  ((inner :initarg :inner :reader inner-adapter)
   (log-stream :initarg :stream :reader log-stream)))

(defmethod clecto:adapter-execute ((a logged-adapter) sql params)
  (format (log-stream a) "EXEC: ~a~%" sql)
  (clecto:adapter-execute (inner-adapter a) sql params))

;; ... specialize the other generics to delegate to inner-adapter
```

But: this is exactly what `*telemetry*` is for. Use telemetry
for logging / metrics; reach for a custom adapter only when you
need to change *behavior*, not just observe it.
