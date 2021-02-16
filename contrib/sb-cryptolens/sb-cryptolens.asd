;;; -*-  Lisp -*-

(defsystem "sb-cryptolens"
  :version "0.1"
  :depends-on ("asdf")
  #+sb-building-contrib :pathname
  #+sb-building-contrib #p"SYS:CONTRIB;SB-CRYPTOLENS;"
  :components ((:file "defpackage")
               (:file "bindings")
;               (:file "def-to-lisp" :depends-on ("defpackage"))
;               (:file "foreign-glue" :depends-on ("defpackage"))
               )
  :perform (load-op :after (o c) (provide 'sb-cryptolens))
  :perform (test-op (o c) t))
