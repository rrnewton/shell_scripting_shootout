#lang typed/racket

(require racket/file
         racket/string
         typed/rackunit
         "git-analysis.rkt"
         "model.rkt"
         "planner.rkt"
         "render.rkt"
         "validation.rkt")

(: decode-text (-> String Symbol AnalysisInput))
(define (decode-text text mode)
  (define path (make-temporary-file "pr-plan-input-~a.json"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file path
        #:exists 'truncate
        (lambda ([output : Output-Port]) (display text output)))
      (load-document path (if (eq? mode 'git) 'git 'pure)))
    (lambda () (delete-file path))))

(define single-pr
  (string-append
   "{\"number\":1,\"title\":\"First\",\"author\":null,"
   "\"head_ref\":\"feature/one\",\"base_ref\":\"main\","
   "\"draft\":false,\"mergeable\":\"MERGEABLE\","
   "\"review_decision\":\"APPROVED\","
   "\"created_at\":\"2026-01-01T00:00:00Z\","
   "\"updated_at\":\"2026-01-02T00:00:00Z\","
   "\"additions\":1,\"deletions\":0,"
   "\"files\":[\"one.txt\"],\"base_conflict_paths\":[]}"))

(: pure-document (-> String String))
(define (pure-document pr)
  (format
   "{\"schema_version\":1,\"repository\":\"acme/widgets\",\"prs\":[~a],\"conflict_edges\":[],\"ancestry_edges\":[]}"
   pr))

(define single-plan (make-plan (decode-text (pure-document single-pr) 'pure)))
(check-equal? (map PrNumber-value (Plan-ready-now single-plan)) '(1))
(check-equal? (Plan-suggested-landing-batches single-plan)
              (list (list (PrNumber 1))))
(check-true (string-contains? (render-json single-plan) "\"title\": \"First\""))
(check-true (string-contains? (render-human single-plan) "Ready now: #1"))

(define empty-plan
  (make-plan
   (decode-text
    "{\"schema_version\":1,\"repository\":\"empty/repo\",\"prs\":[],\"conflict_edges\":[],\"ancestry_edges\":[]}"
    'pure)))
(check-equal? (Plan-nodes empty-plan) '())
(check-equal? (Plan-ready-now empty-plan) '())
(check-equal? (Plan-suggested-landing-batches empty-plan) '())

(check-exn
 InputError?
 (lambda ()
   (decode-text
    "{\"schema_version\":1,\"repository\":7,\"prs\":[],\"conflict_edges\":[],\"ancestry_edges\":[]}"
    'pure)))

(check-exn InputError? (lambda () (decode-text "" 'pure)))
(check-exn InputError?
           (lambda ()
             (decode-text (string-append (pure-document single-pr) " null")
                          'pure)))

(check-exn
 InputError?
 (lambda ()
   (decode-text
    (pure-document (string-replace single-pr "\"number\":1" "\"number\":\"1\""))
    'pure)))

(check-exn
 InputError?
 (lambda ()
   (decode-text
    (pure-document
     (string-replace single-pr
                     "\"files\":[\"one.txt\"]"
                     "\"files\":[\"same\",\"same\"]"))
    'pure)))

(check-exn
 InputError?
 (lambda ()
   (decode-text
    (pure-document
     (string-replace single-pr
                     "2026-01-01T00:00:00Z"
                     "2026-01-01T00:00:00"))
    'pure)))

(define fixture-plan
  (make-plan (load-document "../../fixtures/pure-input.json" 'pure)))
(check-equal? (render-json fixture-plan)
              (file->string "../../fixtures/expected/pure-output.json"))
(check-equal? (render-json fixture-plan) (render-json fixture-plan))

(define git-directory (make-temporary-file "pr-plan-git-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (run-git git-directory '("init" "--quiet"))
    (define expected
      (run-git git-directory '("rev-parse" "--verify" "missing")
               #:expected '(0 128)))
    (check-equal? (CommandResult-status expected) 128)
    (check-exn
     GitError?
     (lambda ()
       (run-git git-directory '("rev-parse" "--verify" "missing")))))
  (lambda () (delete-directory/files git-directory)))
