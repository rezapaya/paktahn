
(in-package :pak)

;;; setup simplified json->lisp translation
(defun simplified-camel-case-to-lisp (camel-string)
  "We don't want + and * all over the place."
  (declare (string camel-string))
  (let ((*print-pretty* nil))
    (with-output-to-string (result)
      (loop for c across camel-string
            with last-was-lowercase
            when (and last-was-lowercase
                      (upper-case-p c))
              do (princ "-" result)
            if (lower-case-p c)
              do (setf last-was-lowercase t)
            else
              do (setf last-was-lowercase nil)
            do (princ (char-upcase c) result)))))

(setf json:*json-identifier-name-to-lisp* #'simplified-camel-case-to-lisp)

;;; tell Drakma to handle JSON as strings
(pushnew '("application" . "json") drakma:*text-content-types*
         :test (lambda (x y)
                 (and (equalp (car x) (car y))
                      (equalp (cdr x) (cdr y)))))

(defun parse-proxy-spec (http-proxy)
  (let ((regex "((http|https)://[^/?#]+):([0-9]{1,5})?(.*)"))
    (let ((matches (nth-value 1 (cl-ppcre:scan-to-strings regex http-proxy))))
      (cond ((null (aref matches 2)) http-proxy)
	    (t (list (concatenate 'string (aref matches 0) (aref matches 3))
		     (parse-integer (aref matches 2))))))))

(defun check-for-aur-proxy ()
  (let ((no-proxies (environment-variable "no_proxy"))
	(http-proxy (environment-variable "http_proxy")))
    (and http-proxy
         (or (null no-proxies) (not (search "archlinux.org" no-proxies)))
         (parse-proxy-spec http-proxy))))

(defun map-aur-packages (fn query)
  "Search AUR for a string"
  (let ((json:*json-symbols-package* #.*package*)
	(proxy (check-for-aur-proxy)))
    (json:with-decoder-simple-clos-semantics
      (let* (network-error-p
             (json
               (handler-bind ((usocket:socket-error
                               (lambda (e)
                                 (setf network-error-p t)
                                 (error "Socket error connecting to AUR: ~A" e)))
                              (usocket:ns-condition
                               (lambda (e)
                                 (setf network-error-p t)
                                 (error "Name resolution error connecting to AUR: ~A" e))))
                 (retrying
                   (restart-case
                       (drakma:http-request "http://aur.archlinux.org/rpc.php"
					    :proxy proxy
                                            :parameters `(("type" . "search")
                                                          ("arg" . ,query)))
                     (retry ()
                       :test (lambda (c) (declare (ignore c)) network-error-p)
                       :report (lambda (s) (format s "Retry network connection."))
                       (setf network-error-p nil)
                       (retry))
                     (ignore ()
                       :test (lambda (c) (declare (ignore c)) network-error-p)
                       :report (lambda (s) (format s "Ignore this error and continue, skipping packages from AUR."))
                       (return-from map-aur-packages nil)))))))
	(check-type json string)
	(let* ((response (json:decode-json-from-string json))
	       (results (slot-value response 'results)))
	  (if (equalp (slot-value response 'type) "search")
	      (dolist (match (sort (coerce results 'list) #'string<
				   :key (lambda (result)
					  (slot-value result 'name))))
		(funcall fn match))
              #+(or)
	      (note "AUR message: ~A" results)))))))

;; TODO: Will this install packages as-deps properly when called
;; from INSTALL-AUR-PACKAGE? Was it before?
(defun install-dependencies (deps)
  (mapcar #'(lambda (pkg)
              (let ((installed-version (package-installed-p pkg))
                    (remote-version (package-remote-version pkg)))
                (if (and installed-version
                         (version= installed-version
                                   remote-version))
                    (with-term-colors/id :info
                      (format t "Dependency: ~A is up to date.~%" pkg))
                    (install-package pkg)))) deps))

(defun aur-tarball-uri (pkg-name)
  (format nil "http://aur.archlinux.org/packages/~(~A~)/~(~A~).tar.gz"
          pkg-name pkg-name))

(defun aur-tarball-name (pkg-name)
  (format nil "~(~A~).tar.gz" pkg-name))

(defun ensure-makepkg-deps ()
  (loop for pkg in '("gcc" "make" "fakeroot") do
       (unless (package-installed-p pkg)
         (when (ask-y/n
                (format nil "Running makepkg requires ~a. Install it?" pkg) t)
           (install-binary-package "core" pkg)))))

(defun run-makepkg ()
  "Run makepkg in the current working directory"
  (ensure-makepkg-deps)
  (retrying
    (restart-case
        (check-pkgbuild-arch)
      (add-arch ()
          :report (lambda (s)
                    (format s "Add ~S to the PKGBUILD's arch field" (get-carch)))
        (add-carch-to-pkgbuild)
        (retry))))
  (let ((return-value (run-program "makepkg" nil)))
    (unless (zerop return-value)
      ;; TODO restarts?
      (error "Makepkg failed (status ~D)" return-value))
    t))

(defun prompt-user-review (filename) ;; ask user whether they wish to edit a file
  (let ((str (concatenate 'string "Review/edit " filename)))
    (when (ask-y/n str t)
      (launch-editor filename))))

(defun install-aur-package (pkg-name &key as-dep)
  (info "Installing package ~S from AUR.~%" pkg-name)
  (when (rootp)
    (error "You're running Paktahn as root; makepkg will not work.~%~
            Try running as a normal user and Paktahn will invoke `sudo' as necessary."))
  (with-tmp-dir ((tempdir) (current-directory))
    (get-pkgbuild-from-aur pkg-name)
    (with-tmp-dir ((merge-pathnames (ensure-trailing-slash pkg-name)) (current-directory))
      (load-checksums)
      (compare-checksums pkg-name)
      (save-checksums)
      (when (customize-p pkg-name)
        (apply-customizations))
      (let ((input (continue-building-p pkg-name)))
        (loop while (eql input :review) do
             (launch-editor "PKGBUILD")
             (setf input (continue-building-p pkg-name)))
        (ecase input
          (:cancel (return-from install-aur-package))
          (:continue (multiple-value-bind (deps make-deps) (get-pkgbuild-dependencies)
                       (install-dependencies (append deps make-deps)))
                     (run-makepkg)
                     (install-pkg-tarball :as-dep as-dep)))))
    (cleanup-temp-files pkg-name))
  t)

(defun continue-building-p (pkg-name)
  (flet ((prompt-user ()
           (format t "~&Continue building ~a? (y/n/(r)eview PKGBUILD: " pkg-name)
           (force-output)
           (peek-char)))
    (loop do (prompt-user) thereis
         (case (char-downcase (read-char))
           (#\Newline :continue)
           (#\y :continue)
           (#\n :cancel)
           (#\r :review)))))

(defun aur-package-p (pkg-name)
  (not (find-package-by-name pkg-name :search-aur nil)))
