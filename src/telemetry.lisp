(in-package #:clecto)

;;; Lightweight telemetry. Set *telemetry* to a function of (event payload).
;;; The repo emits :query and :error events around adapter-execute calls.
;;;
;;; Payload plist keys:
;;;   :sql      string
;;;   :params   list
;;;   :duration seconds (real number)
;;;   :rows     number of rows returned / affected (when applicable)
;;;   :adapter  the adapter that ran the query
;;;   :condition (only on :error)
;;;
;;; Users plug in logging / metrics / tracing without us picking a backend.

(defvar *telemetry* nil
  "Function (event payload) called around adapter-execute. NIL to disable.")

(defvar *telemetry-include-params* nil
  "Default NIL. Params often contain passwords, tokens, PII — they only
appear in telemetry payloads when this is explicitly set to T.")

(defvar *telemetry-handler-failed* nil
  "Set the first time the telemetry callback signals an error, so a
mis-wired backend doesn't go completely silent.")

(defun emit-event (event payload)
  (when *telemetry*
    (handler-case (funcall *telemetry* event payload)
      (error (e)
        (unless *telemetry-handler-failed*
          (setf *telemetry-handler-failed* t)
          (format *error-output*
                  "~&clecto: telemetry handler raised ~a; ~
                   silencing further telemetry errors~%" e))
        nil))))

(defun build-payload (adapter sql params start &optional condition)
  (let ((base (list :sql sql
                    :params (when *telemetry-include-params* params)
                    :duration (/ (- (get-internal-real-time) start)
                                 internal-time-units-per-second)
                    :adapter adapter)))
    (if condition (append base (list :condition condition)) base)))

(defmacro with-telemetry ((adapter sql params) &body body)
  "Wrap BODY (an adapter-execute call) with telemetry events."
  (let ((start (gensym))
        (result (gensym))
        (cond-sym (gensym)))
    `(let ((,start (get-internal-real-time)))
       (handler-case
           (let ((,result (progn ,@body)))
             (emit-event :query (build-payload ,adapter ,sql ,params ,start))
             ,result)
         (error (,cond-sym)
           (emit-event :error
                       (build-payload ,adapter ,sql ,params ,start ,cond-sym))
           (error ,cond-sym))))))
