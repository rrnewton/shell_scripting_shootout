#lang typed/racket

(require racket/list
         "model.rkt")

(provide make-plan)

(define-type PrMap (HashTable PrNumber (Listof PrNumber)))

(: pr-map-get (-> PrMap PrNumber (Listof PrNumber)))
(define (pr-map-get table key)
  (hash-ref table key (lambda () '())))

(: add-pr! (-> PrMap PrNumber PrNumber Void))
(define (add-pr! table key value)
  (define current (pr-map-get table key))
  (unless (pr-list-member? value current)
    (hash-set! table key (cons value current))))

(: pair=?
   (-> (Pairof PrNumber PrNumber) (Pairof PrNumber PrNumber) Boolean))
(define (pair=? left right)
  (and (pr=? (car left) (car right))
       (pr=? (cdr left) (cdr right))))

(: ordering-edges (-> AnalysisInput (Listof OrderingEdge)))
(define (ordering-edges input)
  (define by-head : (HashTable String PrNumber) (make-hash))
  (for ([pr (in-list (AnalysisInput-prs input))])
    (hash-set! by-head (PullRequest-head-ref pr) (PullRequest-number pr)))
  (define edges
    : (HashTable (Pairof PrNumber PrNumber) OrderingEdge)
    (make-hash))
  (for ([pr (in-list (AnalysisInput-prs input))])
    (define parent (hash-ref by-head (PullRequest-base-ref pr) (lambda () #f)))
    (when (and parent (not (pr=? parent (PullRequest-number pr))))
      (define key (cons parent (PullRequest-number pr)))
      (hash-set! edges key
                 (OrderingEdge parent (PullRequest-number pr) 'base-ref))))
  (for ([pair (in-list (AnalysisInput-ancestry-edges input))])
    (unless (hash-has-key? edges pair)
      (hash-set! edges pair (OrderingEdge (car pair) (cdr pair) 'ancestry))))
  (sort (hash-values edges) ordering<?))

(: string-intersection (-> (Listof String) (Listof String) (Listof String)))
(define (string-intersection left right)
  (sort (filter (lambda ([value : String]) (member value right)) left) string<?))

(: file-overlaps (-> (Listof PullRequest) (Listof ConflictEdge)))
(define (file-overlaps prs)
  (for*/list : (Listof ConflictEdge)
    ([left (in-list prs)]
     [right (in-list prs)]
     #:when (pr<? (PullRequest-number left) (PullRequest-number right))
     [shared (in-value (string-intersection (PullRequest-files left)
                                            (PullRequest-files right)))]
     #:when (pair? shared))
    (ConflictEdge (PullRequest-number left) (PullRequest-number right) shared)))

(: has-path?
   (-> PrMap PrNumber PrNumber (Pairof PrNumber PrNumber) Boolean))
(define (has-path? adjacency start target skip)
  (let loop ([pending : (Listof PrNumber) (list start)]
             [seen : (Listof PrNumber) '()])
    (cond
      [(null? pending) #f]
      [else
       (define current (car pending))
       (define rest (cdr pending))
       (if (pr-list-member? current seen)
           (loop rest seen)
           (let inspect ([children : (Listof PrNumber)
                          (pr-map-get adjacency current)]
                         [next : (Listof PrNumber) rest])
             (cond
               [(null? children) (loop next (cons current seen))]
               [else
                (define child (car children))
                (define edge (cons current child))
                (cond
                  [(pair=? edge skip) (inspect (cdr children) next)]
                  [(pr=? child target) #t]
                  [else (inspect (cdr children) (cons child next))])])))])))

(: stacks (-> (Listof OrderingEdge) (Listof (Listof PrNumber))))
(define (stacks edges)
  (define adjacency : PrMap (make-hash))
  (for ([edge (in-list edges)])
    (add-pr! adjacency (OrderingEdge-before edge) (OrderingEdge-after edge)))
  (define reduced
    (filter
     (lambda ([edge : OrderingEdge])
       (not (has-path? adjacency
                       (OrderingEdge-before edge)
                       (OrderingEdge-after edge)
                       (cons (OrderingEdge-before edge)
                             (OrderingEdge-after edge)))))
     edges))
  (define children : PrMap (make-hash))
  (define parents : PrMap (make-hash))
  (define involved : (Listof PrNumber) '())
  (for ([edge (in-list reduced)])
    (add-pr! children (OrderingEdge-before edge) (OrderingEdge-after edge))
    (add-pr! parents (OrderingEdge-after edge) (OrderingEdge-before edge))
    (unless (pr-list-member? (OrderingEdge-before edge) involved)
      (set! involved (cons (OrderingEdge-before edge) involved)))
    (unless (pr-list-member? (OrderingEdge-after edge) involved)
      (set! involved (cons (OrderingEdge-after edge) involved))))
  (define roots
    (filter (lambda ([number : PrNumber])
              (null? (pr-map-get parents number)))
            (pr-sort involved)))
  (: paths-from (-> PrNumber (Listof PrNumber) (Listof (Listof PrNumber))))
  (define (paths-from node path)
    (define descendants (pr-sort (pr-map-get children node)))
    (if (null? descendants)
        (if (> (length path) 1) (list path) '())
        (append*
         (for/list : (Listof (Listof (Listof PrNumber)))
           ([child (in-list descendants)])
           (if (pr-list-member? child path)
               '()
               (paths-from child (append path (list child))))))))
  (append*
   (for/list : (Listof (Listof (Listof PrNumber))) ([root (in-list roots)])
     (paths-from root (list root)))))

(: held-prs
   (-> (Listof PullRequest) (Listof OrderingEdge) (Listof HeldPullRequest)))
(define (held-prs prs ordering)
  (define reasons : (HashTable PrNumber (Listof String)) (make-hash))
  (for ([pr (in-list prs)])
    (define values : (Listof String) '())
    (when (PullRequest-draft pr)
      (set! values (append values (list "draft"))))
    (when (pair? (PullRequest-base-conflict-paths pr))
      (set! values (append values (list "local-base-conflict"))))
    (when (eq? (PullRequest-mergeable pr) 'conflicting)
      (set! values (append values (list "github-base-conflicting"))))
    (hash-set! reasons (PullRequest-number pr) values))
  (let propagate ()
    (define changed : Boolean #f)
    (for ([edge (in-list ordering)])
      (define before (hash-ref reasons (OrderingEdge-before edge)))
      (define after (hash-ref reasons (OrderingEdge-after edge)))
      (when (and (pair? before) (null? after))
        (hash-set! reasons (OrderingEdge-after edge)
                   (list (format "depends-on-held:#~a"
                                 (PrNumber-value (OrderingEdge-before edge)))))
        (set! changed #t)))
    (when changed (propagate)))
  (for/list : (Listof HeldPullRequest)
    ([number (in-list (pr-sort (hash-keys reasons)))]
     #:when (pair? (hash-ref reasons number)))
    (HeldPullRequest number (hash-ref reasons number))))

(: intersection-size (-> (Listof PrNumber) (Listof PrNumber) Natural))
(define (intersection-size left right)
  (for/sum : Natural ([value (in-list left)]
                      #:when (pr-list-member? value right))
    1))

(: descendant-count (-> PrNumber PrMap Natural))
(define (descendant-count number children)
  (let loop ([pending : (Listof PrNumber) (pr-map-get children number)]
             [seen : (Listof PrNumber) '()])
    (cond
      [(null? pending) (length seen)]
      [(pr-list-member? (car pending) seen) (loop (cdr pending) seen)]
      [else
       (define current (car pending))
       (loop (append (pr-map-get children current) (cdr pending))
             (cons current seen))])))

(: landing-batches
   (-> (Listof PullRequest)
       (Listof OrderingEdge)
       (Listof ConflictEdge)
       BatchPlan))
(define (landing-batches prs ordering conflicts)
  (define numbers (map PullRequest-number prs))
  (if (null? numbers)
      (BatchPlan '() '())
      (let ()
        (define by-number : (HashTable PrNumber PullRequest) (make-hash))
        (define conflict-map : PrMap (make-hash))
        (define predecessors : PrMap (make-hash))
        (define children : PrMap (make-hash))
        (for ([pr (in-list prs)])
          (hash-set! by-number (PullRequest-number pr) pr)
          (hash-set! conflict-map (PullRequest-number pr) '())
          (hash-set! predecessors (PullRequest-number pr) '())
          (hash-set! children (PullRequest-number pr) '()))
        (for ([edge (in-list conflicts)]
              #:when (and (pr-list-member? (ConflictEdge-a edge) numbers)
                          (pr-list-member? (ConflictEdge-b edge) numbers)))
          (add-pr! conflict-map (ConflictEdge-a edge) (ConflictEdge-b edge))
          (add-pr! conflict-map (ConflictEdge-b edge) (ConflictEdge-a edge)))
        (for ([edge (in-list ordering)]
              #:when (and (pr-list-member? (OrderingEdge-before edge) numbers)
                          (pr-list-member? (OrderingEdge-after edge) numbers)))
          (add-pr! predecessors (OrderingEdge-after edge)
                   (OrderingEdge-before edge))
          (add-pr! children (OrderingEdge-before edge)
                   (OrderingEdge-after edge)))
        (: available<?
           (-> (Listof PrNumber) PrNumber PrNumber Boolean))
        (define (available<? remaining left right)
          (define left-pr (hash-ref by-number left))
          (define right-pr (hash-ref by-number right))
          (define left-desc (descendant-count left children))
          (define right-desc (descendant-count right children))
          (define left-conflicts
            (intersection-size (pr-map-get conflict-map left) remaining))
          (define right-conflicts
            (intersection-size (pr-map-get conflict-map right) remaining))
          (define left-size
            (+ (PullRequest-additions left-pr) (PullRequest-deletions left-pr)))
          (define right-size
            (+ (PullRequest-additions right-pr) (PullRequest-deletions right-pr)))
          (cond
            [(not (= left-desc right-desc)) (> left-desc right-desc)]
            [(not (= left-conflicts right-conflicts))
             (< left-conflicts right-conflicts)]
            [(not (= left-size right-size)) (< left-size right-size)]
            [(not (string=? (PullRequest-created-at left-pr)
                            (PullRequest-created-at right-pr)))
             (string<? (PullRequest-created-at left-pr)
                       (PullRequest-created-at right-pr))]
            [else (pr<? left right)]))
        (let place ([remaining : (Listof PrNumber) numbers]
                    [placed : (Listof PrNumber) '()]
                    [batches : (Listof (Listof PrNumber)) '()])
          (cond
            [(null? remaining) (BatchPlan (reverse batches) '())]
            [else
             (define available
               (sort
                (filter
                 (lambda ([number : PrNumber])
                   (andmap (lambda ([parent : PrNumber])
                             (pr-list-member? parent placed))
                           (pr-map-get predecessors number)))
                 remaining)
                (lambda ([left : PrNumber] [right : PrNumber])
                  (available<? remaining left right))))
             (if (null? available)
                 (let ([cycles (pr-sort remaining)])
                   (BatchPlan
                    (append (reverse batches)
                            (map (lambda ([number : PrNumber]) (list number))
                                 cycles))
                    cycles))
                 (let ([batch
                        (for/fold ([selected : (Listof PrNumber) '()])
                                  ([candidate (in-list available)])
                          (if (andmap
                               (lambda ([peer : PrNumber])
                                 (not (pr-list-member?
                                       peer
                                       (pr-map-get conflict-map candidate))))
                               selected)
                              (append selected (list candidate))
                              selected))])
                   (place
                    (filter (lambda ([number : PrNumber])
                              (not (pr-list-member? number batch)))
                            remaining)
                    (append placed batch)
                    (cons batch batches))))])))))

(: rebase-plan
   (-> (Listof (Listof PrNumber))
       (Listof OrderingEdge)
       (Listof ConflictEdge)
       (Listof RebaseEntry)))
(define (rebase-plan batches ordering conflicts)
  (define batch-of : (HashTable PrNumber Natural) (make-hash))
  (for ([batch (in-list batches)] [index (in-naturals)])
    (for ([number (in-list batch)])
      (hash-set! batch-of number (assert index exact-nonnegative-integer?))))
  (define dependencies : PrMap (make-hash))
  (define reasons : (HashTable PrNumber (Listof RebaseReason)) (make-hash))
  (: add-reason! (-> PrNumber PrNumber RebaseReason Void))
  (define (add-reason! later earlier reason)
    (add-pr! dependencies later earlier)
    (define current (hash-ref reasons later (lambda () '())))
    (unless (memq reason current)
      (hash-set! reasons later (cons reason current))))
  (for ([edge (in-list ordering)])
    (define before-batch (hash-ref batch-of (OrderingEdge-before edge)
                                   (lambda () #f)))
    (define after-batch (hash-ref batch-of (OrderingEdge-after edge)
                                  (lambda () #f)))
    (when (and before-batch after-batch (< before-batch after-batch))
      (add-reason! (OrderingEdge-after edge) (OrderingEdge-before edge)
                   'stack-dependency)))
  (for ([edge (in-list conflicts)])
    (define a-batch (hash-ref batch-of (ConflictEdge-a edge) (lambda () #f)))
    (define b-batch (hash-ref batch-of (ConflictEdge-b edge) (lambda () #f)))
    (when (and a-batch b-batch (not (= a-batch b-batch)))
      (if (< a-batch b-batch)
          (add-reason! (ConflictEdge-b edge) (ConflictEdge-a edge)
                       'pair-conflict)
          (add-reason! (ConflictEdge-a edge) (ConflictEdge-b edge)
                       'pair-conflict))))
  (sort
   (for/list : (Listof RebaseEntry) ([number (in-list (hash-keys dependencies))])
     (define item-reasons (hash-ref reasons number))
     (RebaseEntry number
                  (pr-sort (pr-map-get dependencies number))
                  (filter (lambda ([reason : RebaseReason])
                            (memq reason item-reasons))
                          '(pair-conflict stack-dependency))))
   (lambda ([left : RebaseEntry] [right : RebaseEntry])
     (define left-batch (hash-ref batch-of (RebaseEntry-pr left)))
     (define right-batch (hash-ref batch-of (RebaseEntry-pr right)))
     (or (< left-batch right-batch)
         (and (= left-batch right-batch)
              (pr<? (RebaseEntry-pr left) (RebaseEntry-pr right)))))))

(: make-plan (-> AnalysisInput Plan))
(define (make-plan input)
  (define ordering (ordering-edges input))
  (define conflicts (sort (AnalysisInput-conflict-edges input) conflict<?))
  (define held (held-prs (AnalysisInput-prs input) ordering))
  (define held-numbers (map HeldPullRequest-pr held))
  (define suggested
    (landing-batches (AnalysisInput-prs input) ordering conflicts))
  (define ready-prs
    (filter (lambda ([pr : PullRequest])
              (not (pr-list-member? (PullRequest-number pr) held-numbers)))
            (AnalysisInput-prs input)))
  (define ready (landing-batches ready-prs ordering conflicts))
  (Plan (AnalysisInput-repository input)
        (AnalysisInput-prs input)
        conflicts
        (file-overlaps (AnalysisInput-prs input))
        ordering
        (stacks ordering)
        (BatchPlan-batches suggested)
        (rebase-plan (BatchPlan-batches suggested) ordering conflicts)
        (BatchPlan-batches ready)
        (if (pair? (BatchPlan-batches ready))
            (car (BatchPlan-batches ready))
            '())
        held
        (BatchPlan-cycles suggested)))
