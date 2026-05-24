# telemetry

clecto emits a telemetry event around every database call. You
hook in by setting `*telemetry*` to a function; clecto calls it
with an event name and a payload. No backends shipped — bring
your own logger / metrics / tracer.

---

## The hook

### `*telemetry*`

A function `(event payload)` called around every database call.
Defaults to `NIL` (disabled).

Set it once at startup:

```lisp
(setf clecto:*telemetry*
      (lambda (event payload)
        (format t "[clecto] ~a ~a~%" event payload)))
```

Two events are emitted:

- `:query` — fired **after** a successful call. Payload
  includes timing.
- `:error` — fired when the call signals. Payload includes
  timing and the condition; clecto re-raises immediately after.

A bad handler is contained: if your callback signals, clecto
prints a warning the first time and silently no-ops afterwards
so a mis-wired backend doesn't go completely silent or break the
request.

### `*telemetry-include-params*`

Defaults to `NIL`. When `T`, the `:params` key in the payload
contains the actual parameter list passed to the SQL. When
`NIL`, the key is set to `NIL` — the parameters never leave the
adapter.

The default is conservative because params often contain
passwords (during register / authenticate flows), tokens (during
session creation), and PII. Flipping this on in development is
useful; in production, leave it off or pre-process the payload
to scrub sensitive values.

```lisp
(setf clecto:*telemetry-include-params* t)
;; → :query payloads now include :params (alice@example.com ...)
```

---

## Payload shape

Both events get a plist payload with these keys:

| Key | Value |
| --- | ----- |
| `:sql`     | the rendered SQL string |
| `:params`  | the parameter list (or NIL when `*telemetry-include-params*` is NIL) |
| `:duration` | seconds elapsed (real number, fractional) |
| `:adapter` | the adapter object |

`:error` events also carry:

| Key | Value |
| --- | ----- |
| `:condition` | the condition that was signalled |

The `:condition` is the *original* error from the adapter —
**not** a `clecto:db-error` wrapper. You see the raw driver
condition here, even when the repo would later wrap it.

---

## Quick wiring examples

### Print every query

```lisp
(setf clecto:*telemetry*
      (lambda (event payload)
        (format t "[~a] ~6,1fms ~a~%"
                event
                (* 1000 (getf payload :duration))
                (getf payload :sql))))
```

Useful in development to see what queries the repo emits.

### Log slow queries

```lisp
(defparameter *slow-query-threshold-ms* 100)

(setf clecto:*telemetry*
      (lambda (event payload)
        (let ((ms (* 1000 (getf payload :duration))))
          (when (and (eq event :query) (> ms *slow-query-threshold-ms*))
            (log:warn "slow query: ~6,1fms ~a"
                      ms (getf payload :sql))))))
```

### Forward to a metrics library

```lisp
(setf clecto:*telemetry*
      (lambda (event payload)
        (case event
          (:query
           (statsd:timing "db.query"
                          (* 1000 (getf payload :duration))))
          (:error
           (statsd:incr  "db.error")
           (log:error "db.error: ~a" (getf payload :condition))))))
```

### Structured per-request logging with a request id

If your web layer threads a request ID through dynamic state,
include it in payload-emitted logs:

```lisp
(defvar *current-request-id* nil)

(setf clecto:*telemetry*
      (lambda (event payload)
        (log:info "~a ~a ~a (~6,1fms)"
                  (or *current-request-id* "-")
                  event
                  (getf payload :sql)
                  (* 1000 (getf payload :duration)))))
```

Bind `*current-request-id*` at the top of each request (e.g. via
`clug`'s `request-id`), and every clecto event during that
request carries the correlation ID.

---

## Composing multiple subscribers

`*telemetry*` is a single function. If you want multiple
subscribers (one for logging, one for metrics), compose them
yourself:

```lisp
(defparameter *telemetry-subscribers* nil)

(defun multi-telemetry (event payload)
  (dolist (sub *telemetry-subscribers*)
    (handler-case (funcall sub event payload)
      (error (e)
        (log:warn "telemetry subscriber ~a errored: ~a" sub e)))))

(setf clecto:*telemetry* #'multi-telemetry)

(push (lambda (e p) ...) *telemetry-subscribers*)
(push (lambda (e p) ...) *telemetry-subscribers*)
```

Each subscriber handles its own errors (clecto's outer guard
will catch propagation, but per-subscriber `handler-case` is
cleaner).

---

## What's covered

Telemetry fires for:

- `repo-all`, `repo-one`, `repo-get`, `repo-get-by`, `repo-exists-p`
- `repo-insert`, `repo-update`, `repo-delete`
- `repo-insert-all`, `repo-update-all`, `repo-delete-all`
- `repo-execute` (raw SQL)
- Transaction `BEGIN` / `COMMIT` / `ROLLBACK` — NOT currently
  emitted as separate events; they go through the adapter
  without a telemetry wrapper. (This is a known gap; if you
  need txn timing, wrap `repo-transaction` calls in your own
  instrumentation.)

Anything that goes through `adapter-execute` /
`adapter-execute-returning` via the repo emits events. Adapter
calls outside the repo (if you're driving the adapter directly)
do not.

---

## Performance overhead

The hook is a single dynamic variable lookup and (when set) one
function call per query. With `*telemetry*` unset, the
overhead is effectively zero — `(when *telemetry* ...)` short-
circuits to the call.

`get-internal-real-time` is called twice per query regardless,
because the macro that wraps adapter calls always records start
and end times. On modern hardware that's nanoseconds; you won't
see it in a benchmark.

---

## Snippets

**Toggle telemetry per request:**

```lisp
(defun with-trace (thunk)
  (let ((events nil))
    (let ((clecto:*telemetry*
           (lambda (e p) (push (list e p) events))))
      (funcall thunk))
    (nreverse events)))

(with-trace (lambda () (repo-all *repo* (from :users))))
;; → ((:query (:sql "SELECT * FROM \"users\"" :params NIL :duration 0.00012 ...)))
```

Useful in tests for "what queries did this code path emit?"
assertions.

**Capture into a thread-local trace buffer:**

```lisp
(defvar *traced-queries* nil)

(defun start-tracing () (setf *traced-queries* nil))
(defun stop-tracing  () (nreverse *traced-queries*))

(setf clecto:*telemetry*
      (lambda (event payload)
        (declare (ignore event))
        (push (getf payload :sql) *traced-queries*)))
```

**Pretty-print to a file:**

```lisp
(with-open-file (s "/tmp/clecto.log"
                   :direction :output
                   :if-exists :append
                   :if-does-not-exist :create)
  (let ((clecto:*telemetry*
         (lambda (event payload)
           (format s "[~a] ~,2fms ~a~%"
                   event (* 1000 (getf payload :duration))
                   (getf payload :sql))
           (force-output s))))
    (do-work-that-runs-queries)))
```

---

## Why not a backend?

Logger preferences vary: log4cl, log4cl-extras, vom, cl-log, just
`format`. Metrics backends vary: statsd, Prometheus textfile,
OpenTelemetry. Tracing backends vary: Datadog, Honeycomb,
Jaeger.

Picking one would mean either a forced dependency or a half-built
abstraction over all of them. Instead, `*telemetry*` is a single
callable — small enough that wiring it to any of the above is a
five-line lambda.
