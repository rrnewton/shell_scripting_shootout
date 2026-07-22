#lang typed/racket

(require racket/file
         racket/list
         racket/port
         racket/string
         "model.rkt")

(provide GitError GitError? CommandResult CommandResult-status
         run-git analyze-repository)

(struct GitError exn:fail () #:transparent)
(struct CommandResult
  ([status : Integer] [stdout : Bytes] [stderr : Bytes])
  #:transparent)

(: fail-git (-> String Nothing))
(define (fail-git message)
  (raise (GitError message (current-continuation-marks))))

(: sanitized-environment (-> Environment-Variables))
(define (sanitized-environment)
  (define environment
    (environment-variables-copy (current-environment-variables)))
  (for ([name (in-list
               '(#"GIT_ALTERNATE_OBJECT_DIRECTORIES"
                 #"GIT_COMMON_DIR"
                 #"GIT_CONFIG_COUNT"
                 #"GIT_CONFIG_PARAMETERS"
                 #"GIT_DIR"
                 #"GIT_INDEX_FILE"
                 #"GIT_OBJECT_DIRECTORY"
                 #"GIT_WORK_TREE"))])
    (environment-variables-set! environment name #f))
  (for ([item (in-list
               '((#"GIT_CONFIG_NOSYSTEM" . #"1")
                 (#"GIT_CONFIG_GLOBAL" . #"/dev/null")
                 (#"GIT_OPTIONAL_LOCKS" . #"0")
                 (#"GIT_TERMINAL_PROMPT" . #"0")
                 (#"LC_ALL" . #"C")))])
    (environment-variables-set! environment (car item) (cdr item)))
  environment)

(: executable-git (-> Path))
(define (executable-git)
  (or (find-executable-path "git")
      (fail-git "git executable was not found")))

(: operation-name (-> (Listof String) String))
(define (operation-name arguments)
  (if (pair? arguments) (car arguments) "command"))

(: run-git
   (->* (Path (Listof String)) (#:expected (Listof Integer)) CommandResult))
(define (run-git repository arguments #:expected [expected '(0)])
  (define command-arguments
    (append (list "-C" (path->string repository) "--no-pager") arguments))
  (define-values (process stdout stdin stderr)
    (with-handlers ([exn:fail:filesystem?
                     (lambda ([error : exn:fail:filesystem])
                       (fail-git (format "could not start git ~a: ~a"
                                         (operation-name arguments)
                                         (exn-message error))))])
      (parameterize ([current-environment-variables (sanitized-environment)])
        (apply subprocess #f #f #f (executable-git) command-arguments))))
  (close-output-port stdin)
  (define stdout-box : (Boxof Bytes) (box #""))
  (define stderr-box : (Boxof Bytes) (box #""))
  (define stdout-reader
    (thread (lambda () (set-box! stdout-box (port->bytes stdout)))))
  (define stderr-reader
    (thread (lambda () (set-box! stderr-box (port->bytes stderr)))))
  (unless (sync/timeout 30 process)
    (subprocess-kill process #t)
    (subprocess-wait process)
    (thread-wait stdout-reader)
    (thread-wait stderr-reader)
    (close-input-port stdout)
    (close-input-port stderr)
    (fail-git (format "git ~a timed out after 30 seconds"
                      (operation-name arguments))))
  (subprocess-wait process)
  (thread-wait stdout-reader)
  (thread-wait stderr-reader)
  (close-input-port stdout)
  (close-input-port stderr)
  (define raw-status (subprocess-status process))
  (define status
    (if (exact-integer? raw-status)
        raw-status
        (fail-git (format "git ~a did not report an exit status"
                          (operation-name arguments)))))
  (define result (CommandResult status (unbox stdout-box) (unbox stderr-box)))
  (unless (member status expected)
    (define detail
      (string-trim (bytes->string/utf-8 (CommandResult-stderr result) #\uFFFD)))
    (fail-git
     (format "git ~a exited with status ~a~a"
             (operation-name arguments)
             status
             (if (string=? detail "") "" (string-append ": " detail)))))
  result)

(: valid-object-id (-> String String ObjectId))
(define (valid-object-id operation output)
  (define value (string-trim output))
  (if (regexp-match? #px"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$" value)
      (ObjectId (string-downcase value))
      (fail-git (format "git ~a returned an invalid commit ID" operation))))

(: resolve-commit (-> Path GitRevision ObjectId))
(define (resolve-commit repository revision)
  (define result
    (run-git repository
             (list "rev-parse" "--verify" "--end-of-options"
                   (string-append (GitRevision-value revision) "^{commit}"))))
  (valid-object-id "rev-parse"
                   (bytes->string/utf-8 (CommandResult-stdout result))))

(: merge-base (-> Path ObjectId ObjectId ObjectId))
(define (merge-base repository left right)
  (define result
    (run-git repository
             (list "merge-base" (ObjectId-value left) (ObjectId-value right))))
  (valid-object-id "merge-base"
                   (bytes->string/utf-8 (CommandResult-stdout result))))

(: decoded-path (-> Bytes String))
(define (decoded-path raw)
  (define value (bytes->string/utf-8 raw #\uFFFD))
  (when (or (string-prefix? value "/")
            (regexp-match? #px"\u0000" value))
    (fail-git (format "git returned an invalid repository path: ~s" value)))
  value)

(: path-records (-> (Listof Bytes) (Listof String)))
(define (path-records records)
  (sort
   (remove-duplicates
    (map decoded-path (filter (lambda ([record : Bytes]) (positive? (bytes-length record)))
                              records)))
   string<?))

(: changed-files (-> Path ObjectId ObjectId (Listof String)))
(define (changed-files repository base head)
  (define common (merge-base repository base head))
  (define result
    (run-git repository
             (list "diff" "--name-only" "-z"
                   (ObjectId-value common) (ObjectId-value head) "--")))
  (path-records (regexp-split #rx#"\0" (CommandResult-stdout result))))

(: conflict-paths (-> Path ObjectId ObjectId (Listof String)))
(define (conflict-paths repository left right)
  (define result
    (run-git repository
             (list "merge-tree" "--write-tree" "--name-only"
                   "--no-messages" "-z"
                   (ObjectId-value left) (ObjectId-value right))
             #:expected '(0 1)))
  (if (= (CommandResult-status result) 0)
      '()
      (let ([records (regexp-split #rx#"\0" (CommandResult-stdout result))])
        (if (null? records)
            (fail-git "git merge-tree reported a conflict without output")
            (path-records (cdr records))))))

(: ancestor? (-> Path ObjectId ObjectId Boolean))
(define (ancestor? repository before after)
  (= (CommandResult-status
      (run-git repository
               (list "merge-base" "--is-ancestor"
                     (ObjectId-value before) (ObjectId-value after))
               #:expected '(0 1)))
     0))

(struct ResolvedPullRequest
  ([pr : PullRequest] [head : ObjectId])
  #:transparent)

(: analyze-repository (-> AnalysisInput Path-String AnalysisInput))
(define (analyze-repository input repository-value)
  (define repository (simplify-path (path->complete-path repository-value) #t))
  (unless (directory-exists? repository)
    (fail-git (format "~a: Git directory must be a directory" repository-value)))
  (run-git repository (list "rev-parse" "--git-dir"))
  (define resolved
    (for/list : (Listof ResolvedPullRequest)
      ([pr (in-list (AnalysisInput-prs input))])
      (define head-revision (PullRequest-git-head pr))
      (define base-revision (PullRequest-git-base pr))
      (unless (and head-revision base-revision)
        (fail-git
         (format "internal error: missing Git revisions for PR #~a"
                 (PrNumber-value (PullRequest-number pr)))))
      (define head (resolve-commit repository head-revision))
      (define base (resolve-commit repository base-revision))
      (ResolvedPullRequest
       (struct-copy PullRequest pr
                    [files (changed-files repository base head)]
                    [base-conflict-paths (conflict-paths repository base head)])
       head)))
  (define conflicts : (Listof ConflictEdge) '())
  (define ancestry : (Listof (Pairof PrNumber PrNumber)) '())
  (for* ([left (in-list resolved)]
         [right (in-list resolved)]
         #:when (pr<? (PullRequest-number (ResolvedPullRequest-pr left))
                      (PullRequest-number (ResolvedPullRequest-pr right))))
    (define left-pr (ResolvedPullRequest-pr left))
    (define right-pr (ResolvedPullRequest-pr right))
    (define left-head (ResolvedPullRequest-head left))
    (define right-head (ResolvedPullRequest-head right))
    (define paths (conflict-paths repository left-head right-head))
    (when (pair? paths)
      (set! conflicts
            (cons (ConflictEdge (PullRequest-number left-pr)
                                (PullRequest-number right-pr)
                                paths)
                  conflicts)))
    (when (ancestor? repository left-head right-head)
      (set! ancestry
            (cons (cons (PullRequest-number left-pr)
                        (PullRequest-number right-pr))
                  ancestry)))
    (when (ancestor? repository right-head left-head)
      (set! ancestry
            (cons (cons (PullRequest-number right-pr)
                        (PullRequest-number left-pr))
                  ancestry))))
  (AnalysisInput
   (AnalysisInput-repository input)
   (map ResolvedPullRequest-pr resolved)
   (sort conflicts conflict<?)
   (sort ancestry
         (lambda ([left : (Pairof PrNumber PrNumber)]
                  [right : (Pairof PrNumber PrNumber)])
           (or (pr<? (car left) (car right))
               (and (pr=? (car left) (car right))
                    (pr<? (cdr left) (cdr right))))))))
