
(in-package :pak)


(define-foreign-library libalpm
  (:unix (:or "libalpm.so.3" "libalpm.so"))
  (t (:default "libalpm")))

(use-foreign-library libalpm)

(defcfun "alpm_initialize" :int)
(defcfun "alpm_option_set_root" :int (root :string))
(defcfun "alpm_option_set_dbpath" :int (root :string))

(defcfun "alpm_db_register_local" :pointer)
(defcfun "alpm_db_register_sync" :pointer (name :string))

(defcfun "alpm_list_next" :pointer (pkg-iterator :pointer))
(defcfun "alpm_list_getdata" :pointer (pkg-iterator :pointer))

(defun init-alpm ()
  (alpm-initialize)
  (alpm-option-set-root "/")
  (alpm-option-set-dbpath "/var/lib/pacman"))

(init-alpm)

(defun get-pacman-config ()
  (py-configparser:read-files
    (py-configparser:make-config) '("/etc/pacman.conf")))

(defun get-enabled-repositories (&optional (config (get-pacman-config)))
  (remove "options" (reverse (py-configparser:sections config))
                :test #'equalp))

(defun init-local-db ()
  (cons "local" (alpm-db-register-local)))

(defun init-sync-dbs ()
  (mapcar (lambda (name)
            (cons name (alpm-db-register-sync name)))
          (get-enabled-repositories)))

(defparameter *local-db* (init-local-db))
(defparameter *sync-dbs* (init-sync-dbs))

;;;; packages
(defcfun "alpm_db_get_pkgcache" :pointer (db :pointer))

(defcfun "alpm_pkg_get_name" :string (pkg :pointer))
(defcfun "alpm_pkg_get_version" :string (pkg :pointer))
(defcfun "alpm_pkg_get_desc" :string (pkg :pointer))

(defun map-db-packages (fn &key (db-list *sync-dbs*))
  "Search a database for packages. FN will be called for each
matching package object. DB-LIST must be a list of database
objects."
  (flet ((map-db (db-spec)
           (loop for pkg-iter = (alpm-db-get-pkgcache (cdr db-spec))
                 then (alpm-list-next pkg-iter)
                 until (null-pointer-p pkg-iter)
                 do (let ((pkg (alpm-list-getdata pkg-iter)))
                      (funcall fn db-spec pkg)))))
    (dolist (db-spec db-list)
      (map-db db-spec))))


;;;; groups
(defcfun "alpm_db_get_grpcache" :pointer (db :pointer))
(defcfun "alpm_grp_get_name" :string (grp :pointer))

(defun map-groups (fn &key (db-list *sync-dbs*))
  "Search a database for groups. FN will be called for each
matching package group object. DB-LIST must be a list of database
objects."
  (flet ((map-db (db-spec)
           (loop for grp-iter = (alpm-db-get-grpcache (cdr db-spec))
                 then (alpm-list-next grp-iter)
                 until (null-pointer-p grp-iter)
                 do (let ((grp (alpm-list-getdata grp-iter)))
                      (funcall fn db-spec grp)))))
    (dolist (db-spec db-list)
      (map-db db-spec))))


;;;; Pacman
(defparameter *pacman-lock* "/var/lib/pacman/db.lck")
(defparameter *pacman-binary* "pacman")

(defmacro with-pacman-lock (&body body)
  `(let (notified)
     (tagbody again
       (when (probe-file *pacman-lock*)
         (unless notified
           (info "Pacman is currently in use, waiting for it to finish...")
           (setf notified t))
         (sleep 1) ; maybe there's a better way? some ioctl?
         (go again)))
     ,@body))

(defun run-pacman (args &key capture-output-p)
  (with-pacman-lock
    ;; --noconfirm is a kludge because of SBCL's run-program bug.
    ;; The fix for this problem is not in upstream yet.
    (run-program "sudo" (append (list *pacman-binary*
                                      #-run-program-fix "--noconfirm"
                                      "--needed")
                                args)
                 :capture-output-p capture-output-p)))
                 

;;;; Lisp interface
(defun install-binary-package (db-name pkg-name)
  "Use Pacman to install a package."
  ;; TODO: check whether it's installed already
  ;; TODO: take versions into account
  (when (equalp db-name "local")
    ;; TODO offer restarts: skip, reinstall from elsewhere
    (error "Can't install an already installed package."))
  (flet ((check-return-value (value)
           (unless (zerop value)
             (error "Pacman exited with non-zero status ~D" value))))
    (cond
      ((eq db-name 'group)
       (info "Installing group ~S.~%" pkg-name)
       (let ((return-value (run-pacman (list "-S" pkg-name))))
         (check-return-value return-value)))
      (t
       (info "Installing binary package ~S from repository ~S.~%"
             pkg-name db-name)
       (let* ((fully-qualified-pkg-name (format nil "~A/~A" db-name pkg-name))
              (return-value (run-pacman (list "-S" fully-qualified-pkg-name))))
         (check-return-value return-value))))
    t))

