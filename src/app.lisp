(defpackage #:github-matrix/app
  (:use #:cl)
  (:import-from #:clack)
  (:import-from #:woo)
  (:import-from #:spinneret)
  (:import-from #:alexandria)
  (:import-from #:github)
  (:import-from #:log4cl-extras/error)
  (:import-from #:log4cl-extras/config)
  (:import-from #:rutils
                #:starts-with
                #:fmt)
  (:import-from #:github-matrix/slynk)
  (:import-from #:cl-ppcre
                #:register-groups-bind)
  (:import-from #:function-cache
                #:defcached)
  (:import-from #:github-matrix/repo)
  (:import-from #:github-matrix/metrika)
  (:import-from #:github-matrix/index)
  (:import-from #:github-matrix/workflow)
  (:import-from #:github-matrix/run-results)
  (:import-from #:github-matrix/base-obj)
  (:import-from #:github-matrix/svg)
  (:export
   #:stop
   #:start
   #:setup-logging-for-dev))
(in-package github-matrix/app)


(defvar *server* nil)

(defvar *debug* nil)

(defvar *last-env* nil)

(defvar *last-document* nil)

(defvar *last-workflows* nil)

(defvar *last-repo* nil)

;; Response will be cached for 15 minutes
(progn
  (defvar *make-svg-response-cache* nil)
  (defparameter *cache-timeout* (* 15 60))
  
  (when *make-svg-response-cache*
    (function-cache:clear-cache *make-svg-response-cache*)
    (setf (function-cache:timeout *make-svg-response-cache*)
          *cache-timeout*)))


(defun extract-user-and-project (uri)
  (register-groups-bind (user project)
      ("^/(.*?)/(.*?)/matrix.svg$" uri)
    (list user project)))


(defun fetch-data (user project)
  (let* ((repo (github-matrix/repo::make-repo user project))
         (workflows (github-matrix/workflow::get-workflows repo))
         (all-runs nil)
         (document
           (loop with root = (github-matrix/container::make-container "All Workflows")
                 for workflow in workflows
                 for runs = (github-matrix/run::get-last-run workflow)
                 for workflow-box = (github-matrix/run-results::runs-to-boxes workflow
                                                                              :runs runs)
                 for workflow-name = (github-matrix/workflow::name workflow)
                 collect runs into collected-runs
                 when workflow-box
                   do (setf (github-matrix/container::child root workflow-name)
                            workflow-box)
                 finally (setf all-runs collected-runs)
                         (return root))))

    (values document
            repo
            (loop for w in workflows
                  for r in all-runs
                  collect (cons w r)))))


(defcached (make-svg-response
            :timeout *cache-timeout*)
    (uri)
  (destructuring-bind (user project)
      (extract-user-and-project uri)
    (multiple-value-bind (document repo workflows-with-runs)
        (fetch-data user project)
          

      (when *debug*
        (setf *last-workflows*
              workflows-with-runs)
        (setf *last-document*
              document)
        (setf *last-repo*
              repo))


      (let* ((width (github-matrix/base-obj::width document))
             (footer-text "Rendered by github-actions.40ants.com")
             (footer-font-family "Helvetica")
             (footer-font-weight "bold")
             (footer-font-size 8)
             (footer-height (* footer-font-size
                               2))
             (font-data (anafanafo:load-data :family footer-font-family
                                             :weight footer-font-weight
                                             :size footer-font-size))
             (footer-width (anafanafo:string-width font-data
                                                   footer-text))
             (height (+ (github-matrix/base-obj::height document)
                         footer-height))
             (svg (cl-svg:make-svg-toplevel 'cl-svg:svg-1.1-toplevel
                                            :width width
                                            :height height)))
        (github-matrix/base-obj::draw document svg)
        
        (github-matrix/svg:text
            (cl-svg:link svg (:xlink-href "https://github-actions.40ants.com/"))
            footer-text
          :x (- width footer-width)
          :y (- height footer-font-size)
          :font-family footer-font-family
          :font-weight footer-font-weight
          :font-size footer-font-size
          :color github-matrix/colors:*link-color*
          :shadow-opacity 0.2)
        
        (with-output-to-string (s)
          (cl-svg:stream-out s svg))))))


(defun parse-params (query-string)
  (when query-string
    (loop for (key . value) in (quri:url-decode-params query-string)
          appending (list (alexandria:make-keyword
                           (string-upcase key))
                          value))))

(defun process-request (env)
  (destructuring-bind (&key
                         path-info
                         query-string
                       &allow-other-keys)
      env
    (let ((params (parse-params query-string)))
      (log4cl-extras/context:with-fields (:uri path-info
                                          :params params)
        (log:info "Processing request")
       
        (log4cl-extras/error:with-log-unhandled ()
          (when (and *debug*
                     (not (starts-with "/debug"
                                       path-info)))
            (setf *last-env*
                  env))
          
          (cond
            ((string= "/" path-info)
             (list 200
                   '(:content-type "text/html")
                   (list (apply 'github-matrix/index:render env params))))
            ((and (string= "/debug" path-info)
                  *debug*)
             (list 200
                   '(:content-type "text/plain")
                   (list (fmt "Last env:~%~S~2&Headers:~%~S"
                              *last-env*
                              (alexandria:hash-table-alist
                               (getf *last-env*
                                     :headers))))))
            ((extract-user-and-project
              path-info)
             ;; Register the hit in the Analytics
             (destructuring-bind (&key demo &allow-other-keys)
                 params
               
               (unless demo
                 (github-matrix/metrika:hit path-info))
               
               ;; Return SVG in response
               (list 200
                     (list :content-type "image/svg+xml;charset=utf-8"
                           :cache-control (fmt "max-age=~A"
                                               *cache-timeout*))
                     (list (make-svg-response path-info)))))
            (t
             (list 404
                   '(:content-type "text/plain")
                   (list (fmt "Path \"~A\" not supported."
                              path-info))))))))))


(defun start (port &key (debug nil))
  (setf github-matrix/metrika:*enabled*
        (not debug))
  
  (setf *server*
        (clack:clackup 'process-request
                       :server :woo
                       :address "0.0.0.0"
                       :debug debug
                       :port port)))

(defun stop ()
  (when *server*
    (clack:stop *server*)
    (setf *server* nil)))


(defun setup-logging-for-prod ()
  (log4cl-extras/config:setup
   '(:level :debug
     ;; Here I want to use :json instead of plain
     ;; but don't know how to use structured logs with Heroku.
     :appenders ((this-console :layout :plain)))))


(defun setup-logging-for-dev ()
  (log4cl-extras/config:setup
   '(:level :debug
     :appenders ((this-console :layout :plain)))))


;; We need this becase Dexador's thread pool is
;; not threadsafe yet. You'll find more details in this issue:
;; https://github.com/fukamachi/dexador/issues/88
(defun dexador:make-connection-pool ()
  (make-hash-table :test 'equal
                   #+sbcl :synchronized #+sbcl t))


(defun cl-user::initialize-application (&key (port 8080))
  (setup-logging-for-prod)

  (setf github:*token*
        (uiop:getenv "GITHUB_TOKEN"))

  (let ((slynk-port (parse-integer (or (uiop:getenv "SLYNK_PORT")
                                       "4005")))
        (slynk-interface (or (uiop:getenv "SLYNK_INTERFACE")
                             "127.0.0.1"))
        (debug (when (uiop:getenv "DEBUG")
                 t)))

    (github-matrix/slynk:start slynk-interface
                               slynk-port)
    
    (log:info "Starting HTTP server on" port "with" debug)
    (start port :debug debug)))


