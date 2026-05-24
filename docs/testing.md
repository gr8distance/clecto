# Testing

Most of clecto can be tested without a database — schemas,
changesets, and queries are pure values. Only repo calls hit
I/O, and SQLite gives you a free in-memory database for those
parts that need it.

This page shows how to structure tests, what to assert against
the pure-value parts, and how to set up an in-memory repo for
integration tests.

---

## The split

```
   pure values, no DB needed                         repo calls
   ─────────────────────────────────                 ──────────
   schema definitions      → defschema               repo-all
   changeset pipeline      → cast + validate-*       repo-insert
   query AST               → from / where / ...      repo-update
   SQL compilation         → to-sql                  repo-delete
                                                     repo-transaction
```

Test left-side values with plain `is` / `signals` assertions.
Test right-side calls against an in-memory SQLite repo.

The clecto test suite at `tests/main.lisp` does exactly this —
the bulk is pure-value tests, with a smaller integration section
that creates tables in `:memory:` and exercises the repo.

---

## Schema tests

```lisp
(test schema-registers-and-finds
  (defschema thing "things"
    (:id   :integer :primary-key t)
    (:name :string)
    (:timestamps))
  (let ((s (find-schema 'thing)))
    (is (eq 'thing (schema-name s)))
    (is (equal "things" (schema-table s)))
    (is (eq :id (schema-primary-key s)))
    (is (schema-timestamps-p s))))

(test fields-are-introspectable
  (defschema thing "things"
    (:id :integer :primary-key t)
    (:secret :string :virtual t))
  (let* ((s (find-schema 'thing))
         (secret (find :secret (schema-fields s) :key #'field-name)))
    (is (field-virtual-p secret))))
```

`defschema` is idempotent (re-evaluating replaces the prior
registration), so it's fine to redefine in tests.

---

## Cast tests

```lisp
(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer))

(test cast-accepts-allowed-and-converts
  (let ((cs (cast 'user '(:email "a@b" :age "20") '(:email :age))))
    (is (cs-valid-p cs))
    (is (equal "a@b" (get-change cs :email)))
    (is (= 20 (get-change cs :age)))))      ; cast "20" -> 20

(test cast-drops-unlisted
  (let ((cs (cast 'user '(:email "a@b" :uninvited "x") '(:email))))
    (is (null (get-change cs :uninvited)))))

(test cast-records-invalid-without-signalling
  (let ((cs (cast 'user '(:age "twenty") '(:age))))
    (is (not (cs-valid-p cs)))
    (is (assoc :age (cs-errors cs)))))
```

Notice the casts never raise — they record errors on the
changeset. Tests that expected an error from bad input would be
wrong; assert on the changeset state instead.

---

## Validator tests

```lisp
(test validate-required-catches-blank
  (let ((cs (-> (cast 'user '(:email "") '(:email))
                (validate-required '(:email)))))
    (is (not (cs-valid-p cs)))
    (is (search "can't be blank"
                (cdr (assoc :email (cs-errors cs)))))))

(test validate-length-bounds-respected
  (let ((short (-> (cast 'user '(:email "a") '(:email))
                   (validate-length :email :min 3)))
        (long  (-> (cast 'user '(:email "ok") '(:email))
                   (validate-length :email :min 3))))
    (is (not (cs-valid-p short)))
    (is (not (cs-valid-p long)))))

(test validate-confirmation-mismatch
  (let ((cs (-> (cast 'user
                      '(:password "abc" :password-confirmation "xyz")
                      '(:password :password-confirmation))
                (validate-confirmation :password))))
    (is (not (cs-valid-p cs)))
    (is (assoc :password-confirmation (cs-errors cs)))))
```

Pattern: build a changeset, run the validator, assert on
`cs-valid-p` and the error attached to the expected field. Don't
bother stubbing — the changeset is the full state.

---

## traverse-errors tests

`traverse-errors` is what your view layer / API will call. Test
its shape with cases your UI cares about:

```lisp
(test traverse-groups-by-field
  (let ((cs (-> (cast 'user '() '())
                (add-error :email "can't be blank")
                (add-error :email "is invalid format"))))
    (let ((errs (traverse-errors cs)))
      (let ((entry (cdr (assoc :email errs))))
        (is (find "can't be blank" entry :test #'string=))
        (is (find "is invalid format" entry :test #'string=))))))

(test traverse-applies-mapper
  (let ((cs (-> (cast 'user '() '())
                (add-error :email "blank"))))
    (let ((errs (traverse-errors cs
                                 (lambda (f m) (format nil "[~a] ~a" f m)))))
      (is (find "[EMAIL] blank" (cdr (assoc :email errs))
                :test #'string=)))))
```

---

## Query AST tests

Queries are plain structs — test them by introspecting their
slots, or compile them and assert on the SQL.

### Struct inspection

```lisp
(test query-where-accumulates
  (let ((q (-> (from :users)
               (where '(= :active t))
               (where '(>= :age 18)))))
    (is (eq :users (query-table q)))
    (is (= 2 (length (query-wheres q))))))

(test where-if-skips-when-falsy
  (let ((q (-> (from :users)
               (where-if nil '(= :active t)))))
    (is (null (query-wheres q)))))
```

### SQL inspection

When the rendered SQL is what matters, compile the query against
an adapter and assert on the string:

```lisp
(test query-compiles-with-limit-offset
  (let ((q (-> (from :users)
               (where '(= :active t))
               (limit 10)
               (offset 20)))
        (a (make-sqlite-adapter ":memory:")))
    (multiple-value-bind (sql params) (to-sql a q)
      (is (search "WHERE" sql))
      (is (search "LIMIT 10" sql))
      (is (search "OFFSET 20" sql))
      (is (equal '(t) params)))))
```

The SQLite adapter doesn't actually need to open a real
database for compilation — `make-sqlite-adapter ":memory:"`
creates a fully-functional adapter against a transient DB. If
you want compilation without any DB at all, mock the adapter
class.

---

## Repo (integration) tests

For end-to-end behavior — inserts, updates, constraint errors,
preloading — use an in-memory SQLite database:

```lisp
(defparameter *test-repo* nil)

(defun setup-test-repo ()
  (setf *test-repo* (make-repo (make-sqlite-adapter ":memory:")))
  (repo-execute *test-repo*
                "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT,
                                     inserted_at TEXT, updated_at TEXT)")
  (repo-execute *test-repo*
                "CREATE UNIQUE INDEX users_email_idx ON users(email)"))

(defun teardown-test-repo ()
  (when *test-repo*
    (sqlite-close (repo-adapter *test-repo*))
    (setf *test-repo* nil)))

;; fiveam has :around for test fixtures
(def-fixture test-repo ()
  (setup-test-repo)
  (unwind-protect (&body)
    (teardown-test-repo)))

(test insert-returns-row
  (with-fixture test-repo ()
    (multiple-value-bind (row err)
        (repo-insert *test-repo*
                     (cast 'user (list :email "a@b") '(:email)))
      (is (null err))
      (is (equal "a@b" (getf row :email)))
      (is (integerp (getf row :id))))))

(test duplicate-email-errors-via-constraint
  (with-fixture test-repo ()
    (repo-insert *test-repo*
                 (cast 'user (list :email "a@b") '(:email)))
    (multiple-value-bind (row err)
        (repo-insert *test-repo*
                     (-> (cast 'user (list :email "a@b") '(:email))
                         (unique-constraint :email)))
      (is (null row))
      (is (assoc :email (cs-errors err))))))
```

The `:memory:` database is recreated per test (because each test
gets a fresh adapter), so there's no cross-test contamination.

---

## Transaction tests

```lisp
(test transaction-rolls-back-on-error
  (with-fixture test-repo ()
    (ignore-errors
      (repo-transaction (*test-repo*)
        (repo-insert *test-repo*
                     (cast 'user (list :email "a@b") '(:email)))
        (error "boom")))
    (is (null (repo-one *test-repo* (from :users))))))

(test rollback-aborts-without-error
  (with-fixture test-repo ()
    (repo-transaction (*test-repo*)
      (repo-insert *test-repo*
                   (cast 'user (list :email "a@b") '(:email)))
      (rollback))
    (is (null (repo-one *test-repo* (from :users))))))
```

The first asserts "any signalled condition rolls back." The
second asserts "explicit `rollback` rolls back without raising."

---

## Telemetry tests

`*telemetry*` is dynamic — bind it in your test to capture events:

```lisp
(test telemetry-fires-on-query
  (with-fixture test-repo ()
    (let ((events nil))
      (let ((clecto:*telemetry*
             (lambda (e p) (push (list e (getf p :sql)) events))))
        (repo-all *test-repo* (from :users)))
      (is (= 1 (length events)))
      (is (eq :query (first (first events))))
      (is (search "SELECT" (second (first events)))))))
```

---

## Test layout

The clecto suite uses `fiveam`:

```lisp
(defpackage #:clecto/tests
  (:use #:cl #:fiveam #:clecto)
  (:shadowing-import-from #:clecto #:union))

(in-package #:clecto/tests)

(def-suite :clecto)
(in-suite :clecto)

(test schema-... ...)
(test changeset-... ...)
(test query-... ...)
(test repo-... ...)
```

Run from the REPL:

```lisp
(asdf:test-system :clecto)
;; or:
(fiveam:run! :clecto)
```

From the shell:

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :clecto/tests)' \
     --eval '(asdf:test-system :clecto)'
```

---

## What NOT to test

- **The SQL string verbatim.** Test what the SQL *does* (via
  `repo-all` against `:memory:`) or assert on substrings
  (`(is (search "ORDER BY" sql))`). Exact-string tests break
  whenever the compiler tightens its output, without catching
  any real bug.

- **Adapter internals.** Treat the adapter as the protocol it
  exposes. Don't reach into `(sqlite-db a)` from your tests.

- **`clecto:db-error` wrapping behavior.** It's a property of the
  repo, not your code. If your test fails because a constraint
  isn't being translated, declare the constraint — don't assert
  on `db-error`.

---

## Quick reference

| What you want to test            | How |
| -------------------------------- | --- |
| Schema field metadata            | `(field-virtual-p (find :x (schema-fields ...) ...))` |
| Cast coerces a value             | `(is (= 20 (get-change (cast ...) :age)))` |
| Validator adds an error          | `(is (assoc :field (cs-errors cs)))` |
| `traverse-errors` shape          | inspect the alist directly |
| Query AST contents               | `(query-wheres q)`, `(query-limit q)` |
| Rendered SQL contains a clause   | `(is (search "JOIN" sql))` |
| Insert produces a row            | `:memory:` repo, assert on `:id` / fields |
| Constraint becomes a field error | Declare `unique-constraint`, then double-insert |
| Transaction rolls back           | Wrap in `ignore-errors` + `repo-transaction` |
| Telemetry fires                  | Bind `*telemetry*`, accumulate events |
