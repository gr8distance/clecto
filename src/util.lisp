(in-package #:clecto)

(defmacro define-copier (name &key copier accessor-prefix slots)
  "Define a functional copier: (NAME orig &rest plist-overrides).
Generates an ECASE over SLOTS, dispatching to the standard struct setters
named by ACCESSOR-PREFIX. Example:

  (define-copier copy-cs
    :copier copy-changeset
    :accessor-prefix cs-
    :slots (data changes errors))"
  (flet ((acc (slot)
           (intern (concatenate 'string
                                (string accessor-prefix) (string slot))
                   (symbol-package name))))
    `(defun ,name (orig &rest overrides)
       (let ((c (,copier orig)))
         (loop for (slot val) on overrides by #'cddr do
           (ecase slot
             ,@(mapcar (lambda (s)
                         `((,(alexandria:make-keyword s))
                           (setf (,(acc s) c) val)))
                       slots)))
         c))))
