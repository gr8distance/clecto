(defpackage #:clecto
  (:use #:cl)
  (:shadow #:union #:intersection #:set-difference)
  (:export
   ;; schema
   #:defschema #:schema #:find-schema
   #:schema-name #:schema-table #:schema-fields #:schema-primary-key
   #:schema-assocs #:schema-assoc #:schema-timestamps-p
   #:now-naive-datetime #:generate-uuid
   #:field-name #:field-type #:field-options #:field-virtual-p
   #:association
   #:association-name #:association-kind
   #:association-target #:association-foreign-key
   ;; changeset
   #:changeset #:changeset-p #:make-changeset
   #:cs-data #:cs-changes #:cs-errors #:cs-valid-p #:cs-schema
   #:cs-constraints #:cs-action
   #:traverse-errors #:apply-action
   #:cast-embed #:cast-assoc
   #:unique-constraint #:foreign-key-constraint
   #:cast #:put-change #:get-change #:get-field
   #:add-error
   #:validate-required #:validate-format #:validate-number #:validate-length
   #:validate-inclusion #:validate-exclusion #:validate-subset
   #:validate-confirmation #:validate-acceptance
   #:apply-changes
   ;; query
   #:query #:from #:where #:select #:order-by #:limit #:offset
   #:join #:group-by #:having #:distinct
   #:subquery #:subquery-p #:with-cte
   #:union #:union-all #:intersect #:except
   #:lock #:with-prefix
   #:where-if #:and-filters
   #:query-table #:query-wheres #:query-selects
   #:query-orders #:query-joins #:query-groups #:query-havings
   #:query-limit #:query-offset
   ;; adapter
   #:adapter #:adapter-execute #:adapter-execute-returning
   #:adapter-quote-identifier #:adapter-placeholder
   #:adapter-last-insert-id
   ;; sql
   #:to-sql
   ;; sqlite adapter
   #:sqlite-adapter #:make-sqlite-adapter #:sqlite-close
   ;; repo
   #:repo #:make-repo #:repo-adapter
   #:repo-all #:repo-one #:repo-get #:repo-get-by #:repo-exists-p
   #:repo-insert #:repo-update #:repo-delete
   #:repo-insert-all #:repo-update-all #:repo-delete-all
   #:repo-preload
   #:repo-execute
   #:repo-transaction #:rollback))
