#lang typed/racket

(provide (all-defined-out))

(struct PrNumber ([value : Positive-Integer]) #:transparent)
(struct GitRevision ([value : String]) #:transparent)
(struct ObjectId ([value : String]) #:transparent)

(define-type Mergeable (U 'mergeable 'conflicting 'unknown))
(define-type ReviewDecision
  (U 'approved 'changes-requested 'review-required 'none))
(define-type OrderReason (U 'base-ref 'ancestry))
(define-type RebaseReason (U 'pair-conflict 'stack-dependency))

(struct PullRequest
  ([number : PrNumber]
   [title : String]
   [author : (Option String)]
   [head-ref : String]
   [base-ref : String]
   [draft : Boolean]
   [mergeable : Mergeable]
   [review-decision : ReviewDecision]
   [created-at : String]
   [updated-at : String]
   [additions : Nonnegative-Integer]
   [deletions : Nonnegative-Integer]
   [files : (Listof String)]
   [base-conflict-paths : (Listof String)]
   [git-head : (Option GitRevision)]
   [git-base : (Option GitRevision)])
  #:transparent)

(struct ConflictEdge
  ([a : PrNumber] [b : PrNumber] [paths : (Listof String)])
  #:transparent)

(struct OrderingEdge
  ([before : PrNumber] [after : PrNumber] [reason : OrderReason])
  #:transparent)

(struct HeldPullRequest
  ([pr : PrNumber] [reasons : (Listof String)])
  #:transparent)

(struct RebaseEntry
  ([pr : PrNumber]
   [after : (Listof PrNumber)]
   [reasons : (Listof RebaseReason)])
  #:transparent)

(struct AnalysisInput
  ([repository : String]
   [prs : (Listof PullRequest)]
   [conflict-edges : (Listof ConflictEdge)]
   [ancestry-edges : (Listof (Pairof PrNumber PrNumber))])
  #:transparent)

(struct BatchPlan
  ([batches : (Listof (Listof PrNumber))]
   [cycles : (Listof PrNumber)])
  #:transparent)

(struct Plan
  ([repository : String]
   [nodes : (Listof PullRequest)]
   [conflict-edges : (Listof ConflictEdge)]
   [file-overlap-edges : (Listof ConflictEdge)]
   [ordering-edges : (Listof OrderingEdge)]
   [stacks : (Listof (Listof PrNumber))]
   [suggested-landing-batches : (Listof (Listof PrNumber))]
   [suggested-rebase-plan : (Listof RebaseEntry)]
   [ready-landing-batches : (Listof (Listof PrNumber))]
   [ready-now : (Listof PrNumber)]
   [held-prs : (Listof HeldPullRequest)]
   [ordering-cycles : (Listof PrNumber)])
  #:transparent)

(: pr<? (-> PrNumber PrNumber Boolean))
(define (pr<? left right)
  (< (PrNumber-value left) (PrNumber-value right)))

(: pr=? (-> PrNumber PrNumber Boolean))
(define (pr=? left right)
  (= (PrNumber-value left) (PrNumber-value right)))

(: pr-list-member? (-> PrNumber (Listof PrNumber) Boolean))
(define (pr-list-member? number values)
  (ormap (lambda ([value : PrNumber]) (pr=? number value)) values))

(: pr-sort (-> (Listof PrNumber) (Listof PrNumber)))
(define (pr-sort values)
  (sort values pr<?))

(: conflict<? (-> ConflictEdge ConflictEdge Boolean))
(define (conflict<? left right)
  (or (pr<? (ConflictEdge-a left) (ConflictEdge-a right))
      (and (pr=? (ConflictEdge-a left) (ConflictEdge-a right))
           (pr<? (ConflictEdge-b left) (ConflictEdge-b right)))))

(: ordering<? (-> OrderingEdge OrderingEdge Boolean))
(define (ordering<? left right)
  (or (pr<? (OrderingEdge-before left) (OrderingEdge-before right))
      (and (pr=? (OrderingEdge-before left) (OrderingEdge-before right))
           (pr<? (OrderingEdge-after left) (OrderingEdge-after right)))))

(: mergeable->string (-> Mergeable String))
(define (mergeable->string value)
  (case value
    [(mergeable) "MERGEABLE"]
    [(conflicting) "CONFLICTING"]
    [(unknown) "UNKNOWN"]))

(: review-decision->string (-> ReviewDecision String))
(define (review-decision->string value)
  (case value
    [(approved) "APPROVED"]
    [(changes-requested) "CHANGES_REQUESTED"]
    [(review-required) "REVIEW_REQUIRED"]
    [(none) "NONE"]))

(: order-reason->string (-> OrderReason String))
(define (order-reason->string value)
  (case value
    [(base-ref) "base-ref"]
    [(ancestry) "ancestry"]))

(: rebase-reason->string (-> RebaseReason String))
(define (rebase-reason->string value)
  (case value
    [(pair-conflict) "pair-conflict"]
    [(stack-dependency) "stack-dependency"]))
