# changeset

A changeset is the value that flows through validation. It carries
the original data, the proposed changes, accumulated errors,
declared constraints, and a `valid-p` flag. Every operation
returns a new changeset — nothing mutates.

The shape is "build it, validate it, hand it to the repo."

---

## Quick example

```lisp
(defun new-user (attrs)
  (-> (cast 'user attrs '(:email :age :password :password-confirmation))
      (validate-required '(:email :password))
      (validate-format    :email "@")
      (validate-length    :password :min 12)
      (validate-confirmation :password)
      (unique-constraint  :email)))

(let ((cs (new-user '(:email "a@b" :age 20
                      :password "x" :password-confirmation "y"))))
  (cs-valid-p cs)        ; -> NIL
  (cs-errors cs)         ; -> alist of (field . message)
  (cs-changes cs))       ; -> plist of accepted-and-cast values

(repo-insert *repo* cs)
;; if valid:   (values record nil)
;; if invalid: (values nil cs-with-action-:insert)
```

---

## The struct

```lisp
(defstruct (changeset (:conc-name cs-))
  schema       ; symbol naming the schema (or NIL for schemaless)
  data         ; plist: the row as it exists (empty on insert)
  changes      ; plist: the cast + put values that will be applied
  errors       ; alist: (field . message) most-recent-first
  constraints  ; list of constraint records (declared for DB-side checks)
  action       ; nil, :insert, :update, :delete, :ignore
  valid-p)     ; convenience flag — recomputed by add-error
```

Accessors: `cs-schema`, `cs-data`, `cs-changes`, `cs-errors`,
`cs-constraints`, `cs-action`, `cs-valid-p`. Plus
`(changeset-p x)` predicate.

You usually don't mutate the struct directly — the helpers below
do it functionally.

---

## `(cast DATA-OR-SCHEMA ATTRS ALLOWED) → CHANGESET`

The entry point. Three arguments:

- **DATA-OR-SCHEMA**: either a symbol naming a schema (for insert)
  or a plist of existing row data with `:__schema__` keying the
  schema (for update).
- **ATTRS**: a plist of incoming values (typically user input).
- **ALLOWED**: a list of field keywords. Only these fields are
  accepted from ATTRS; everything else is silently ignored.

For each `allowed` field that's present in `ATTRS`:

1. Look up the field's type from the schema.
2. Call `cast-value` to coerce the value.
3. If cast succeeds, record the value under `:changes`.
4. If cast fails, add `(field . "is invalid")` to `:errors`.

Cast is **strict but quiet**: it doesn't signal on bad input, it
records an error. The result is always a usable changeset.

```lisp
;; insert: data-or-schema is a schema symbol
(cast 'user '(:email "alice@example.com" :age 20 :uninvited "bad")
            '(:email :age))
;; → changeset with :changes (:age 20 :email "alice@example.com")
;;   ":uninvited" is dropped because it's not in ALLOWED

;; update: data-or-schema is a record with :__schema__ tag
(cast (list :__schema__ 'user :id 1 :email "old@x" :age 19)
      '(:age 20)
      '(:age))
;; → changeset with :data (old row), :changes (:age 20)
```

For updates, the data must carry `:__schema__ 'NAME` so cast
can find the schema. The repo's update helpers (and clauth's
`update-password!` / `update-email!`) do this splice for you when
they build the cast call.

---

## Common changeset operations

### `(put-change CS FIELD VALUE) → CS'`

Force a value into `:changes` regardless of the original `cast`
ALLOWED list. Useful for server-computed fields (`:password-hash`,
`:slug`).

```lisp
(put-change cs :password-hash (hash (get-field cs :password)))
```

If FIELD already had a change, the new value replaces it.

### `(get-change CS FIELD &optional DEFAULT) → VALUE`

Read a value from `:changes`. Returns DEFAULT if absent (does **not**
fall through to `:data`).

### `(get-field CS FIELD &optional DEFAULT) → VALUE`

The "effective" value: change wins, else fall through to `:data`.

This is what validators read internally — a value that wasn't
changed in this call but exists on the row still validates.

### `(add-error CS FIELD MESSAGE) → CS'`

Append an error and set `cs-valid-p` to NIL. Used inside custom
validators.

```lisp
(if (silly-domain-rule (get-field cs :email))
    (add-error cs :email "looks like spam")
    cs)
```

### `(apply-changes CS) → PLIST`

Merge `:changes` onto `:data` and return the result as a plist.
Useful for previewing what the row will look like after persistence.

The repo calls this internally during `repo-insert` / `repo-update`.

---

## Validators

All validators have the shape `(cs ...) → cs` and never raise — they
record errors via `add-error`. Chain them with a threading macro or
`let*`.

### `(validate-required CS FIELDS)`

Each field in FIELDS must be non-`NIL` and non-`""`.

```lisp
(validate-required cs '(:email :password))
```

### `(validate-format CS FIELD SUBSTRING &key message)`

SUBSTRING must appear in the field's value. Crude but enough for
"contains `@`" sort of checks without dragging in a regex library.

```lisp
(validate-format cs :email "@")
```

For real format checks (e.g. enforcing valid email syntax),
implement a custom validator and call from your changeset
constructor. clauth has `valid-email-shape-p` for this.

### `(validate-number CS FIELD &key < <= > >= = message)`

Apply numeric comparisons. The value must be a number, and each
provided bound must pass.

```lisp
(validate-number cs :age :>= 0 :<= 150)
```

### `(validate-length CS FIELD &key min max message)`

String length bounds. Field value must be a string; `min` /
`max` are inclusive.

```lisp
(validate-length cs :password :min 12 :max 1024)
```

### `(validate-inclusion CS FIELD ALLOWED &key message)`

Value must be a member of ALLOWED (compared with `equal`).

```lisp
(validate-inclusion cs :role '(:user :moderator :admin))
```

### `(validate-exclusion CS FIELD DISALLOWED &key message)`

Inverse of inclusion. Useful for reserved-name blocklists.

```lisp
(validate-exclusion cs :username '("admin" "root" "support"))
```

### `(validate-subset CS FIELD ALLOWED &key message)`

The field's value must be a **list** of items, each in ALLOWED.
Useful for multi-select fields.

```lisp
(validate-subset cs :tags '("news" "tech" "design"))
```

### `(validate-confirmation CS FIELD &key message)`

Look for a sibling key named `:<field>-confirmation` (e.g.
`:password-confirmation` matched against `:password`) and check
equality. Standard "type your password again" form pattern.

```lisp
(validate-confirmation cs :password)
```

The error attaches to `:<field>-confirmation`, not the original
field — so your form shows the "does not match" message under the
confirmation input.

### `(validate-acceptance CS FIELD &key message)`

`(get-field cs field)` must be truthy. For "I accept the terms"
checkboxes.

```lisp
(validate-acceptance cs :terms)
```

---

## DB-side constraints

These declare what to do when the database itself rejects an
insert/update (unique violation, foreign key, check constraint).
`repo-insert` / `repo-update` catch the DB error, look up the
matching declared constraint, and attach the error to the
changeset.

Without a declared constraint, a DB error is wrapped in
`clecto:db-error` and re-signalled — the raw message stays out of
the changeset (to avoid leaking row data) but you'll see it
explode if not caught.

### `(unique-constraint CS FIELD &key message column name)`

Declare that a UNIQUE violation on COLUMN (defaults to FIELD)
should appear as an error on FIELD.

```lisp
(unique-constraint cs :email)
;; → on duplicate email insert, changeset gets
;;   (:email . "has already been taken")
```

`:name` is the DB-side constraint name (e.g. `"users_email_key"`).
Useful when the column name doesn't match the index name (which
happens with multi-column unique indexes).

### `(foreign-key-constraint CS FIELD &key message name)`

Declare that a FK violation should error on FIELD.

```lisp
(foreign-key-constraint cs :user-id)
;; → on missing user_id, changeset gets
;;   (:user-id . "does not exist")
```

### `(check-constraint CS FIELD &key message name)`

For DB-level `CHECK (...)` violations. Postgres-specific in
practice; SQLite enforces less.

```lisp
(check-constraint cs :age :name "users_age_positive")
```

---

## Nested data

### `(cast-embed CS FIELD ATTRS CAST-FN) → CS'`

For `:embeds-one` / `:embeds-many` associations: cast a nested
attribute. CAST-FN is called as `(funcall cast-fn child-attrs)`
and must return a changeset.

```lisp
(defun address-changeset (attrs)
  (-> (cast 'address attrs '(:line1 :city :zip))
      (validate-required '(:line1 :city))))

(-> (cast 'user input '(:email))
    (cast-embed :address input #'address-changeset))
```

For `:embeds-many`, ATTRS[FIELD] is a list of plists and CAST-FN
maps over them.

The repo serializes embedded changesets to JSON on insert.

### `(cast-assoc CS FIELD ATTRS CAST-FN) → CS'`

Same shape as `cast-embed` but for row-based associations
(`:has-one` / `:has-many` / `:belongs-to`). Stores child
changesets on the parent; **the repo does not auto-persist them
in v0.2** — you persist children explicitly in a transaction.

---

## `(traverse-errors CS &optional FN) → ALIST`

Walk the changeset's errors and return an alist keyed by field,
each value a list of mapped messages.

```lisp
(traverse-errors cs)
;; -> ((:email "has already been taken")
;;     (:age "is out of range"))

(traverse-errors cs (lambda (field msg)
                      (format nil "[~a] ~a" field msg)))
;; -> ((:email "[email] has already been taken") ...)
```

Use this when building error responses for forms / APIs. The
typical pattern is to map to the user-facing label format your UI
expects.

Errors are kept in **insertion order** by field: the first error
attached to `:email` comes first in `:email`'s list.

---

## `(apply-action CS ACTION) → (values DATA-OR-NIL CS-OR-NIL)`

Validate a changeset without going to the database. If valid,
returns `(values data nil)` where `data` is `(apply-changes cs)`.
Otherwise returns `(values nil cs-with-action)`.

```lisp
(multiple-value-bind (data cs) (apply-action cs :insert)
  (cond
    (data ;; valid — proceed with non-DB work
          ...)
    (t    ;; invalid — render errors
          ...)))
```

Use this for "validate then redirect to confirm page" flows where
you want changeset semantics without yet writing the row.

ACTION is just a tag for the resulting changeset's `:action` slot;
it doesn't affect behavior. Conventionally `:insert`, `:update`,
or `:delete`.

---

## Custom validators

A validator is just `(cs ...) → cs`. Write your own when the
built-ins don't fit:

```lisp
(defun validate-strong-password (cs &key (min 12))
  (let ((p (get-field cs :password)))
    (cond
      ((not (stringp p)) cs)                ; required-check handles this
      ((< (length p) min)
       (add-error cs :password
                  (format nil "must be at least ~a characters" min)))
      ((not (find-if #'upper-case-p p))
       (add-error cs :password "must contain at least one uppercase letter"))
      (t cs))))

;; usage
(-> (cast 'user attrs '(:email :password))
    (validate-required '(:email :password))
    (validate-strong-password :min 12))
```

The rules:

1. Don't signal. Use `add-error`.
2. Don't read the database. If you need a DB lookup, write a
   regular function the controller calls, not a "validator."
3. Return the changeset, even on success.

---

## Patterns

**Multi-stage changeset for password change** — typical flow where
you reuse one changeset constructor for both create and update:

```lisp
(defun password-changeset (cs attrs)
  (-> cs
      (cast attrs '(:password :password-confirmation))
      (validate-required '(:password))
      (validate-length    :password :min 12)
      (validate-confirmation :password)
      (put-change :password-hash (hash (get-field cs :password)))))

(defun register-changeset (attrs)
  (password-changeset
   (-> (cast 'user attrs '(:email))
       (validate-required '(:email))
       (validate-format   :email "@")
       (unique-constraint :email))
   attrs))
```

**Conditional validators** — only validate when the field is
present:

```lisp
(defun maybe-validate (cs field validator)
  (if (get-change cs field) (funcall validator cs) cs))

(-> cs
    (maybe-validate :age (lambda (c) (validate-number c :age :>= 0))))
```

**Schemaless changeset** — build one without a schema for
internal data flows where you don't need cast or constraints:

```lisp
(let ((cs (cast nil attrs '(:foo :bar))))
  ;; :changes :: plist; no type coercion
  ...)
```

`cs-schema` is `NIL`; cast doesn't run cast-value (because there's
no field metadata). Validators still work as long as they're
field-based.
