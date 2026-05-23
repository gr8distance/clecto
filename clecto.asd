(defsystem "clecto"
  :description "An Ecto-flavored, immutable, functional data layer for Common Lisp."
  :version "0.1.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("alexandria" "sqlite" "jonathan")
  :pathname "src/"
  :components ((:file "package")
               (:file "util"       :depends-on ("package"))
               (:file "schema"     :depends-on ("package"))
               (:file "changeset"  :depends-on ("schema" "util"))
               (:file "query"      :depends-on ("package" "util"))
               (:file "adapter"    :depends-on ("package"))
               (:file "sql"          :depends-on ("query" "adapter"))
               (:file "sql-expr"     :depends-on ("sql"))
               (:file "sql-select"   :depends-on ("sql-expr"))
               (:file "sql-mutation" :depends-on ("sql-expr"))
               (:module "adapters" :depends-on ("adapter" "sql-select" "sql-mutation")
                :components ((:file "sqlite")))
               (:file "repo"       :depends-on ("adapter" "sql-select" "sql-mutation"
                                                "changeset" "schema")))
  :in-order-to ((test-op (test-op "clecto/tests"))))

(defsystem "clecto/tests"
  :depends-on ("clecto" "fiveam")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :clecto)))
