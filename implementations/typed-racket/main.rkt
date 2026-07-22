#lang typed/racket

(require "git-analysis.rkt"
         "planner.rkt"
         "render.rkt"
         "validation.rkt")

(provide run)

(define-type Mode (U 'pure 'git))

(struct CliOptions
  ([mode : Mode]
   [input : Path-String]
   [git-directory : (Option Path-String)]
   [human : Boolean])
  #:transparent)

(: usage (-> Output-Port Void))
(define (usage output)
  (displayln "usage: pr-plan <pure|git> --input FILE [--git-dir DIR] [--human]" output)
  (displayln "" output)
  (displayln "Build deterministic pull-request conflict and landing plans." output)
  (displayln "" output)
  (displayln "commands:" output)
  (displayln "  pure  plan from validated precomputed graph data" output)
  (displayln "  git   analyze a local Git repository and plan" output))

(: cli-error (-> String Nothing))
(define (cli-error message)
  (raise-user-error 'pr-plan message))

(: parse-options (-> Mode (Listof String) CliOptions))
(define (parse-options mode arguments)
  (let loop ([remaining : (Listof String) arguments]
             [input : (Option Path-String) #f]
             [git-directory : (Option Path-String) #f]
             [human : Boolean #f])
    (cond
      [(null? remaining)
       (unless input (cli-error "--input is required"))
       (when (and (eq? mode 'git) (not git-directory))
         (cli-error "--git-dir is required in git mode"))
       (CliOptions mode input git-directory human)]
      [(string=? (car remaining) "--human")
       (when human (cli-error "--human may only be supplied once"))
       (loop (cdr remaining) input git-directory #t)]
      [(string=? (car remaining) "--input")
       (when input (cli-error "--input may only be supplied once"))
       (when (null? (cdr remaining)) (cli-error "--input requires FILE"))
       (loop (cddr remaining) (cadr remaining) git-directory human)]
      [(string=? (car remaining) "--git-dir")
       (unless (eq? mode 'git)
         (cli-error "--git-dir is only valid in git mode"))
       (when git-directory (cli-error "--git-dir may only be supplied once"))
       (when (null? (cdr remaining)) (cli-error "--git-dir requires DIR"))
       (loop (cddr remaining) input (cadr remaining) human)]
      [(or (string=? (car remaining) "--help")
           (string=? (car remaining) "-h"))
       (usage (current-output-port))
       (exit 0)]
      [else (cli-error (format "unknown argument: ~a" (car remaining)))])))

(: execute (-> CliOptions Void))
(define (execute options)
  (define initial (load-document (CliOptions-input options)
                                 (CliOptions-mode options)))
  (define analyzed
    (if (eq? (CliOptions-mode options) 'git)
        (let ([directory (CliOptions-git-directory options)])
          (if directory
              (analyze-repository initial directory)
              (cli-error "--git-dir is required in git mode")))
        initial))
  (define plan (make-plan analyzed))
  (display (if (CliOptions-human options)
               (render-human plan)
               (render-json plan))))

(: run (-> (Listof String) Integer))
(define (run arguments)
  (cond
    [(or (equal? arguments '("--help"))
         (equal? arguments '("-h")))
     (usage (current-output-port))
     0]
    [(null? arguments)
     (usage (current-error-port))
     2]
    [else
     (with-handlers
         ([InputError?
           (lambda ([error : InputError])
             (eprintf "pr-plan: error: ~a\n" (exn-message error))
             1)]
          [GitError?
           (lambda ([error : GitError])
             (eprintf "pr-plan: error: ~a\n" (exn-message error))
             1)]
          [exn:fail:user?
           (lambda ([error : exn:fail:user])
             (eprintf "pr-plan: error: ~a\n" (exn-message error))
             2)])
       (define mode
         (cond
           [(string=? (car arguments) "pure") 'pure]
           [(string=? (car arguments) "git") 'git]
           [else (cli-error (format "unknown command: ~a" (car arguments)))]))
       (execute (parse-options mode (cdr arguments)))
       0)]))

(module+ main
  (exit (run (vector->list (current-command-line-arguments)))))
