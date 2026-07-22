#lang typed/racket

(require racket/list
         racket/string
         "model.rkt")

(provide render-json render-human)

(struct JsonObject ([fields : (Listof (Pairof String JsonValue))]) #:transparent)
(struct JsonArray ([values : (Listof JsonValue)]) #:transparent)
(define-type JsonValue (U String Integer Boolean JsonObject JsonArray))

(: hex4 (-> Integer String))
(define (hex4 value)
  (define raw (string-downcase (number->string value 16)))
  (string-append (make-string (max 0 (- 4 (string-length raw))) #\0) raw))

(: escaped-string (-> String String))
(define (escaped-string value)
  (define output (open-output-string))
  (write-char #\" output)
  (for ([character (in-string value)])
    (define code (char->integer character))
    (cond
      [(char=? character #\") (display "\\\"" output)]
      [(char=? character #\\) (display "\\\\" output)]
      [(char=? character #\backspace) (display "\\b" output)]
      [(char=? character #\page) (display "\\f" output)]
      [(char=? character #\newline) (display "\\n" output)]
      [(char=? character #\return) (display "\\r" output)]
      [(char=? character #\tab) (display "\\t" output)]
      [(< code #x20) (display (string-append "\\u" (hex4 code)) output)]
      [(<= code #x7e) (write-char character output)]
      [(<= code #xffff) (display (string-append "\\u" (hex4 code)) output)]
      [else
       (define adjusted (- code #x10000))
       (define high (+ #xd800 (quotient adjusted #x400)))
       (define low (+ #xdc00 (remainder adjusted #x400)))
       (display (string-append "\\u" (hex4 high) "\\u" (hex4 low)) output)]))
  (write-char #\" output)
  (get-output-string output))

(: indent (-> Natural String))
(define (indent count)
  (make-string count #\space))

(: render-value (-> JsonValue Natural String))
(define (render-value value depth)
  (cond
    [(string? value) (escaped-string value)]
    [(integer? value) (number->string value)]
    [(boolean? value) (if value "true" "false")]
    [(JsonArray? value)
     (define values (JsonArray-values value))
     (if (null? values)
         "[]"
         (string-append
          "[\n"
          (string-join
           (map (lambda ([item : JsonValue])
                  (string-append (indent (+ depth 2))
                                 (render-value item (+ depth 2))))
                values)
           ",\n")
          "\n" (indent depth) "]"))]
    [else
     (define fields (JsonObject-fields value))
     (if (null? fields)
         "{}"
         (string-append
          "{\n"
          (string-join
           (map (lambda ([field : (Pairof String JsonValue)])
                  (string-append (indent (+ depth 2))
                                 (escaped-string (car field))
                                 ": "
                                 (render-value (cdr field) (+ depth 2))))
                fields)
           ",\n")
          "\n" (indent depth) "}"))]))

(: jarray (-> (Listof JsonValue) JsonArray))
(define (jarray values) (JsonArray values))

(: numbers (-> (Listof PrNumber) JsonArray))
(define (numbers values)
  (jarray (map (lambda ([value : PrNumber]) (PrNumber-value value)) values)))

(: strings (-> (Listof String) JsonArray))
(define (strings values)
  (jarray values))

(: node-json (-> PullRequest JsonValue))
(define (node-json pr)
  (JsonObject
   (list
    (cons "pr" (PrNumber-value (PullRequest-number pr)))
    (cons "title" (PullRequest-title pr))
    (cons "author" (or (PullRequest-author pr) "unknown"))
    (cons "head_ref" (PullRequest-head-ref pr))
    (cons "base_ref" (PullRequest-base-ref pr))
    (cons "draft" (PullRequest-draft pr))
    (cons "mergeable" (mergeable->string (PullRequest-mergeable pr)))
    (cons "review_decision"
          (review-decision->string (PullRequest-review-decision pr)))
    (cons "additions" (PullRequest-additions pr))
    (cons "deletions" (PullRequest-deletions pr))
    (cons "files_count" (length (PullRequest-files pr)))
    (cons "base_conflict_paths" (strings (PullRequest-base-conflict-paths pr))))))

(: conflict-json (-> ConflictEdge JsonValue))
(define (conflict-json edge)
  (JsonObject
   (list (cons "a" (PrNumber-value (ConflictEdge-a edge)))
         (cons "b" (PrNumber-value (ConflictEdge-b edge)))
         (cons "paths" (strings (ConflictEdge-paths edge))))))

(: ordering-json (-> OrderingEdge JsonValue))
(define (ordering-json edge)
  (JsonObject
   (list (cons "before" (PrNumber-value (OrderingEdge-before edge)))
         (cons "after" (PrNumber-value (OrderingEdge-after edge)))
         (cons "reason" (order-reason->string (OrderingEdge-reason edge))))))

(: held-json (-> HeldPullRequest JsonValue))
(define (held-json item)
  (JsonObject
   (list (cons "pr" (PrNumber-value (HeldPullRequest-pr item)))
         (cons "reasons" (strings (HeldPullRequest-reasons item))))))

(: rebase-json (-> RebaseEntry JsonValue))
(define (rebase-json item)
  (JsonObject
   (list
    (cons "pr" (PrNumber-value (RebaseEntry-pr item)))
    (cons "after" (numbers (RebaseEntry-after item)))
    (cons "reasons"
          (strings (map rebase-reason->string (RebaseEntry-reasons item)))))))

(: plan-json (-> Plan JsonValue))
(define (plan-json plan)
  (JsonObject
   (list
    (cons "repository" (Plan-repository plan))
    (cons "nodes" (jarray (map node-json (Plan-nodes plan))))
    (cons "conflict_edges"
          (jarray (map conflict-json (Plan-conflict-edges plan))))
    (cons "file_overlap_edges"
          (jarray (map conflict-json (Plan-file-overlap-edges plan))))
    (cons "ordering_edges"
          (jarray (map ordering-json (Plan-ordering-edges plan))))
    (cons "stacks" (jarray (map numbers (Plan-stacks plan))))
    (cons "suggested_landing_batches"
          (jarray (map numbers (Plan-suggested-landing-batches plan))))
    (cons "suggested_rebase_plan"
          (jarray (map rebase-json (Plan-suggested-rebase-plan plan))))
    (cons "ready_landing_batches"
          (jarray (map numbers (Plan-ready-landing-batches plan))))
    (cons "ready_now" (numbers (Plan-ready-now plan)))
    (cons "held_prs" (jarray (map held-json (Plan-held-prs plan))))
    (cons "ordering_cycles" (numbers (Plan-ordering-cycles plan))))))

(: render-json (-> Plan String))
(define (render-json plan)
  (string-append (render-value (plan-json plan) 0) "\n"))

(: pr-list (-> (Listof PrNumber) String))
(define (pr-list values)
  (if (null? values)
      "(none)"
      (string-join
       (map (lambda ([number : PrNumber])
              (format "#~a" (PrNumber-value number)))
            values)
       ", ")))

(: batch-lines (-> String (Listof (Listof PrNumber)) (Listof String)))
(define (batch-lines heading batches)
  (cons heading
        (if (null? batches)
            (list "  (none)")
            (for/list : (Listof String)
              ([batch (in-list batches)] [index (in-naturals 1)])
              (format "  ~a: ~a" index (pr-list batch))))))

(: render-human (-> Plan String))
(define (render-human plan)
  (define held-lines
    (cons
     "Held pull requests:"
     (if (null? (Plan-held-prs plan))
         (list "  (none)")
         (map (lambda ([item : HeldPullRequest])
                (format "  #~a: ~a"
                        (PrNumber-value (HeldPullRequest-pr item))
                        (string-join (HeldPullRequest-reasons item) ", ")))
              (Plan-held-prs plan)))))
  (define cycle-lines
    (list "Ordering cycles:"
          (if (null? (Plan-ordering-cycles plan))
              "  (none)"
              (string-append "  " (pr-list (Plan-ordering-cycles plan))))))
  (define rebase-lines
    (cons
     "Suggested rebase plan:"
     (if (null? (Plan-suggested-rebase-plan plan))
         (list "  (none)")
         (map
          (lambda ([item : RebaseEntry])
            (format "  #~a after ~a: ~a"
                    (PrNumber-value (RebaseEntry-pr item))
                    (pr-list (RebaseEntry-after item))
                    (string-join
                     (map rebase-reason->string (RebaseEntry-reasons item))
                     ", ")))
          (Plan-suggested-rebase-plan plan)))))
  (string-append
   (string-join
    (append
     (list (format "Repository: ~a" (Plan-repository plan))
           (format "Pull requests: ~a" (length (Plan-nodes plan))))
     held-lines
     cycle-lines
     (batch-lines "Suggested landing batches:"
                  (Plan-suggested-landing-batches plan))
     (batch-lines "Ready landing batches:" (Plan-ready-landing-batches plan))
     (list (string-append "Ready now: " (pr-list (Plan-ready-now plan))))
     rebase-lines)
    "\n")
   "\n"))
