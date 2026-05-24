# schema

A schema describes the **shape** of a table: which fields exist,
their types, primary key, associations to other tables, whether
timestamps are managed automatically. Schemas are values registered
under a name; lookups happen by name throughout the rest of clecto
(`repo-get repo 'user 1`, `cast 'user attrs ...`).

There are no CLOS objects backing rows. A "user record" is a plist
like `(:id 1 :email "a@b" :inserted-at "...")` — same as anything
else.

---

## `defschema`

```lisp
(defschema NAME TABLE
  &body SPECS)
```

NAME is a symbol you'll refer to in `cast`, `repo-get`, etc. TABLE
is the SQL table name (a string).

```lisp
(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:age   :integer)
  (:timestamps))
```

After expansion this `defparameter`-equivalent stores the schema
under the global registry `*schemas*`. `(find-schema 'user)`
retrieves it.

Each body form is one of:

| Form | Meaning |
| ---- | ------- |
| `(:field-name :type ...options)` | a field declaration |
| `(:assoc-name :kind target ...options)` | an association declaration |
| `(:timestamps)` (or bare `:timestamps`) | auto inserted-at / updated-at |

The macro normalises everything into a `schema` struct: `:fields`,
`:assocs`, `:primary-key`, `:timestamps-p`.

---

## Field types

Built-in field types and their casting behavior:

| Type | CL values accepted | Cast behavior |
| ---- | ------------------ | ------------- |
| `:integer`        | integer / string of digits  | string → integer via `parse-integer` (length-capped) |
| `:float`          | number / numeric string     | coerced to `double-float` |
| `:decimal`        | rational / numeric string   | kept as rational, accepts `"n/m"` too |
| `:string`         | anything                    | stringified if not already a string |
| `:boolean`        | `t`, `:true`, `"true"`, `"t"`, `1` → `t`; `nil`, `:false`, `"false"`, `"f"`, `0` → `nil` | strict membership |
| `:naive-datetime` | string                      | passed through (no parsing) |
| `:utc-datetime`   | string                      | passed through |
| `:date`           | string                      | passed through |
| `:binary-id`      | string                      | passed through |
| `:enum` (with `:values`) | symbol / string             | case-insensitive match against allowed values |

Cast happens in `cast` (the changeset entry point) — see
[changeset](./changeset.md). Cast that *can't* convert sets an
`is invalid` error on the field; it doesn't signal.

For `:integer` and `:float` casts from strings, two safety caps
apply:

- `*numeric-string-cap*` (default 64) — strings longer than this
  are rejected outright. Stops an attacker from sending a
  megabyte-long digit string that would build a giant bignum.
- `*numeric-exponent-cap*` (default 1000) — `1e1000` is already a
  very large bignum; anything past is rejected.

Both are exposed as parameters; raise or lower per app.

---

## Field options

After the type, any number of `:option value` pairs:

| Option | Behavior |
| ------ | -------- |
| `:primary-key t` | This field is the PK. The first field marked wins; default is `:id` if no field is marked. |
| `:virtual t`     | Skipped at insert/update. Useful for `:password` / `:password-confirmation` — present on the changeset, never reaches SQL. |
| `:values '(...)`  | For `:enum` fields, the allowed values |

Other options are stored on the field's `:options` plist; future
versions may use more of them. Anything you put there now will be
preserved without complaint.

```lisp
(defschema user "users"
  (:id                    :integer :primary-key t)
  (:email                 :string)
  (:password-hash         :string)
  (:password              :string :virtual t)
  (:password-confirmation :string :virtual t)
  (:status                :enum   :values '(:draft :active :archived))
  (:timestamps))
```

---

## Associations

Five kinds, declared as fields with the association kind in second
position:

```lisp
(defschema user "users"
  (:id :integer :primary-key t)
  (:email :string)
  ;; one-to-many: this user has many posts
  (:posts :has-many post :foreign-key :user-id)
  ;; one-to-one: this user has one bio row
  (:bio   :has-one  bio  :foreign-key :user-id)
  ;; one-to-one in the other direction: bio belongs to a user
  ;; (declared on bio's schema instead)
  ;; (:user :belongs-to user :foreign-key :user-id)
  ;; embedded JSON: stored as a JSON column on this row
  (:address :embeds-one  address)
  (:tags    :embeds-many tag)
  (:timestamps))
```

| Kind | Storage | Notes |
| ---- | ------- | ----- |
| `:has-many`    | other table | uses `:foreign-key` on the *other* table to look up children |
| `:has-one`     | other table | uses `:foreign-key` on the *other* table, expects one row |
| `:belongs-to`  | this table  | uses `:foreign-key` on *this* table pointing at the other's PK |
| `:embeds-one`  | this table  | JSON-encoded into a single column |
| `:embeds-many` | this table  | JSON array encoded into a single column |

Associations don't change how rows are read from the DB — they're
metadata for `repo-preload` (which fetches them in a separate
query) and for `cast-assoc` / `cast-embed` (which validate child
changesets).

clecto deliberately doesn't auto-load associations. You ask for
them via `repo-preload`. See [repo](./repo.md).

---

## Timestamps

Adding `(:timestamps)` does three things:

1. Adds `:inserted-at` and `:updated-at` fields (`:naive-datetime`).
2. Auto-populates both on `repo-insert`.
3. Updates `:updated-at` on `repo-update`.

The values come from `(now-naive-datetime)` — the local-time string
`"YYYY-MM-DD HH:MM:SS"`. For UTC, override per-field or wrap your
own helper.

Without `(:timestamps)`, the columns aren't auto-managed. Useful
when you have a table where created_at semantics differ (e.g. a
log table whose timestamp is the event time, not the row creation
time).

---

## The schema registry

`defschema` calls `register-schema`, which stores the schema in
the module-global `*schemas*` hash-table keyed by name (a symbol).

- `(find-schema 'user)` → schema struct, or error if not registered.
- Re-evaluating a `defschema` form **replaces** the old definition.
  Convenient at the REPL; production apps load schemas once at
  startup.

You can inspect what's registered with `(alexandria:hash-table-keys
*schemas*)` — useful in tests / sanity checks.

---

## Inspecting a schema

The struct accessors are exported:

```lisp
(let ((s (find-schema 'user)))
  (schema-name s)        ; -> USER
  (schema-table s)       ; -> "users"
  (schema-primary-key s) ; -> :ID
  (schema-fields s)      ; -> list of field structs
  (schema-assocs s)      ; -> list of association structs
  (schema-timestamps-p s)) ; -> T or NIL
```

For each field struct:

```lisp
(field-name field)        ; -> :EMAIL
(field-type field)        ; -> :STRING
(field-options field)     ; -> plist
(field-virtual-p field))  ; -> T if :virtual t
```

For each association:

```lisp
(association-name a)         ; -> :POSTS
(association-kind a)         ; -> :HAS-MANY
(association-target a)       ; -> POST  (symbol)
(association-foreign-key a)) ; -> :USER-ID
```

`(schema-assoc s :posts)` retrieves an association by name without
walking the list manually.

---

## Identifier conversion

DB columns are kept in **snake_case** (`user_id`); CL keywords are
**kebab-case** (`:user-id`). Conversion happens at the adapter
boundary:

- `clecto::lispify-column "user_id"` → `:USER-ID`
- `clecto::sqlify-column :user-id` → `"user_id"`

You write keywords throughout your code; the adapter renders them
as DB-quoted snake_case identifiers when assembling SQL. This
keeps the convention consistent across CL/SQL with no manual
spelling.

---

## Schema-level helpers

These live in the schema module because they pair with field
types but are exported for general use:

### `(now-naive-datetime) → STRING`

Local-time `"YYYY-MM-DD HH:MM:SS"`. What `(:timestamps)` uses.

### `(now-utc-datetime) → STRING`

UTC `"YYYY-MM-DD HH:MM:SSZ"`. Use this for cross-system audit
timestamps and any `:utc-datetime` columns.

### `(generate-uuid) → STRING`

RFC 4122 v4 UUID. Bytes come from the OS CSPRNG
(`/dev/urandom`). Safe for security-sensitive identifiers (session
tokens, password-reset links).

Signals `secure-random-unavailable` if `/dev/urandom` can't be
read — do **not** catch this and silently fall back to a PRNG.
That would silently downgrade security guarantees.

### `(generate-secure-token &key (byte-length 32)) → STRING`

URL-safe-ish hex token. Default 32 bytes = 256 bits = 64 hex
characters. For session IDs, CSRF tokens, password-reset codes.

Same CSPRNG behavior as `generate-uuid` — including the same
condition on unavailability.

---

## Snippets

**A minimal lookup table:**

```lisp
(defschema country "countries"
  (:id   :integer :primary-key t)
  (:code :string)
  (:name :string))
```

**A schema with virtual + enum + embedded:**

```lisp
(defschema user "users"
  (:id                    :integer :primary-key t)
  (:email                 :string)
  (:password-hash         :string)
  (:password              :string :virtual t)
  (:password-confirmation :string :virtual t)
  (:role                  :enum :values '(:user :moderator :admin))
  (:profile               :embeds-one profile)
  (:timestamps))

(defschema profile "profiles"
  (:display-name :string)
  (:bio          :string))
```

Profile is `:embeds-one` — when you insert a user with a profile
attached, the profile gets JSON-encoded into the `profile` column
of `users`. There's no separate `profiles` table for this
association. See [changeset](./changeset.md) for how to
`cast-embed`.

**A relational graph:**

```lisp
(defschema user "users"
  (:id    :integer :primary-key t)
  (:email :string)
  (:posts :has-many   post :foreign-key :user-id)
  (:bio   :has-one    bio  :foreign-key :user-id))

(defschema bio "bios"
  (:id      :integer :primary-key t)
  (:user-id :integer)
  (:text    :string)
  (:user    :belongs-to user :foreign-key :user-id))

(defschema post "posts"
  (:id      :integer :primary-key t)
  (:user-id :integer)
  (:title   :string)
  (:user    :belongs-to user :foreign-key :user-id))
```

A `repo-preload` call would fetch `:posts`, `:bio`, or `:user` on
demand. See [repo](./repo.md).
