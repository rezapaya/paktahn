(defsystem :paktahn
  :name "Paktahn"
  :description "A package management wrapper to replace Yaourt on Arch Linux"
  :version "0.9.8"
  :author "Leslie Polzer"
  :license "GPL"
  :pathname "src/"
  :depends-on (:md5 :trivial-backtrace :cl-store :cl-json
               :drakma :cffi :alexandria :metatilities
               :unix-options :cl-ppcre :py-configparser
               :split-sequence
               #+sbcl :sb-posix)
  :serial t
  :components ((:file "packages")
               (:file "pyconfig-fix")
               (:file "safe-foreign-string")
               (:file "readline")
               (:file "term")
               (:file "util")
               (:file "alpm")
               (:file "customizepkg")
               (:file "checksums")
               (:file "pkgbuild")
               (:file "aur")
               (:file "cache")
               (:file "main"))
  :in-order-to ((test-op (load-op paktahn-tests)))
  :perform (test-op :after (op c)
                    (funcall (intern "RUN!" :paktahn-tests))))

(defsystem #:paktahn-tests
  :depends-on (paktahn fiveam)
  :pathname "tests/"
  :components ((:file "tests")))

(defmethod operation-done-p ((op test-op)
                             (c (eql (find-system :paktahn))))
  (values nil))
