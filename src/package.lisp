(defpackage #:clecto
  (:use #:cl)
  (:shadow #:union #:intersection #:set-difference)

  ;; --- schema ---
  (:export
   #:defschema #:schema #:find-schema
   #:schema-name #:schema-table #:schema-fields #:schema-primary-key
   #:schema-assocs #:schema-assoc #:schema-timestamps-p
   #:field-name #:field-type #:field-options #:field-virtual-p
   #:association
   #:association-name #:association-kind
   #:association-target #:association-foreign-key
   #:now-naive-datetime #:generate-uuid)

  ;; --- changeset ---
  (:export
   #:changeset #:changeset-p #:make-changeset
   #:cs-data #:cs-changes #:cs-errors #:cs-valid-p #:cs-schema
   #:cs-constraints #:cs-action
   #:cast #:put-change #:get-change #:get-field
   #:add-error #:apply-changes
   #:validate-required #:validate-format #:validate-number #:validate-length
   #:validate-inclusion #:validate-exclusion #:validate-subset
   #:validate-confirmation #:validate-acceptance
   #:traverse-errors #:apply-action
   #:cast-embed #:cast-assoc
   #:unique-constraint #:foreign-key-constraint #:check-constraint)

  ;; --- query ---
  (:export
   #:query #:from #:where #:select #:order-by #:limit #:offset
   #:join #:group-by #:having #:distinct
   #:subquery #:subquery-p #:with-cte
   #:union #:union-all #:intersect #:except
   #:lock #:with-prefix
   #:where-if #:and-filters
   #:query-table #:query-wheres #:query-selects
   #:query-orders #:query-joins #:query-groups #:query-havings
   #:query-limit #:query-offset)

  ;; --- adapter protocol ---
  (:export
   #:adapter #:adapter-execute #:adapter-execute-returning
   #:adapter-quote-identifier #:adapter-placeholder
   #:adapter-last-insert-id
   #:adapter-begin #:adapter-commit #:adapter-rollback
   #:adapter-translate-constraint-error)

  ;; --- sql ---
  (:export #:to-sql)

  ;; --- telemetry ---
  (:export #:*telemetry*)

  ;; --- adapters ---
  (:export
   #:sqlite-adapter #:make-sqlite-adapter #:sqlite-close
   #:postgres-adapter #:make-postgres-adapter #:postgres-close)

  ;; --- repo ---
  (:export
   #:repo #:make-repo #:repo-adapter
   #:repo-all #:repo-one #:repo-get #:repo-get-by #:repo-exists-p
   #:repo-insert #:repo-update #:repo-delete
   #:repo-insert-all #:repo-update-all #:repo-delete-all
   #:repo-preload
   #:repo-execute
   #:repo-transaction #:rollback))
