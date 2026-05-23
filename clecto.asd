(defsystem "clecto"
  :description "An Ecto-flavored, immutable, functional data layer for Common Lisp."
  :version "0.1.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("alexandria" "sqlite" "jonathan")
  :pathname "src/"
  :components ((:file "package")
               (:file "schema"     :depends-on ("package"))
               (:file "changeset"  :depends-on ("schema"))
               (:file "query"      :depends-on ("package"))
               (:file "adapter"    :depends-on ("package"))
               (:file "sql"        :depends-on ("query" "adapter"))
               (:module "adapters" :depends-on ("adapter" "sql")
                :components ((:file "sqlite")))
               (:file "repo"       :depends-on ("adapter" "sql" "changeset" "schema")))
  :in-order-to ((test-op (test-op "clecto/tests"))))

(defsystem "clecto/tests"
  :depends-on ("clecto" "fiveam")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :clecto)))
