#lang typed/racket

(require racket/list
         racket/string
         typed/json
         "model.rkt")

(provide InputError
         InputError?
         decode-document
         load-document)

(struct InputError exn:fail () #:transparent)

(: fail-input (-> String String Nothing))
(define (fail-input path message)
  (raise (InputError (string-append path ": " message)
                     (current-continuation-marks))))

(define-type Mode (U 'pure 'git))

(define pure-root-keys
  '(schema_version repository prs conflict_edges ancestry_edges))
(define git-root-keys '(schema_version repository prs))
(define common-pr-keys
  '(number title author head_ref base_ref draft mergeable review_decision
           created_at updated_at additions deletions))
(define pure-pr-keys
  (append common-pr-keys '(files base_conflict_paths)))
(define git-pr-keys
  (append common-pr-keys '(git_head git_base)))

(: json-object (-> JSExpr String (HashTable Symbol JSExpr)))
(define (json-object value path)
  (if (hash? value)
      value
      (fail-input path "expected an object")))

(: json-array (-> JSExpr String (Listof JSExpr)))
(define (json-array value path)
  (if (list? value)
      value
      (fail-input path "expected an array")))

(: exact-keys! (-> (HashTable Symbol JSExpr) (Listof Symbol) String Void))
(define (exact-keys! object expected path)
  (define keys : (Listof Symbol) (hash-keys object))
  (define missing
    (sort (filter (lambda ([key : Symbol]) (not (memq key keys))) expected)
          symbol<?))
  (define unknown
    (sort (filter (lambda ([key : Symbol]) (not (memq key expected))) keys)
          symbol<?))
  (cond
    [(pair? missing)
     (fail-input path
                 (format "missing field(s): ~a"
                         (string-join (map symbol->string missing) ", ")))]
    [(pair? unknown)
     (fail-input path
                 (format "unknown field(s): ~a"
                         (string-join (map symbol->string unknown) ", ")))]
    [else (void)]))

(: required (-> (HashTable Symbol JSExpr) Symbol JSExpr))
(define (required object key)
  (hash-ref object key))

(: json-string (->* (JSExpr String) (#:nonempty Boolean) String))
(define (json-string value path #:nonempty [nonempty #t])
  (unless (string? value)
    (fail-input path "expected a string"))
  (when (and nonempty (string=? value ""))
    (fail-input path "must not be empty"))
  (when (regexp-match? #px"\u0000" value)
    (fail-input path "must not contain NUL"))
  value)

(: optional-string (-> JSExpr String (Option String)))
(define (optional-string value path)
  (if (eq? value 'null)
      #f
      (json-string value path)))

(: nonnegative-integer (-> JSExpr String Nonnegative-Integer))
(define (nonnegative-integer value path)
  (unless (exact-integer? value)
    (fail-input path "expected an integer"))
  (when (< value 0)
    (fail-input path "must not be negative"))
  (assert value exact-nonnegative-integer?))

(: positive-pr-number (-> JSExpr String PrNumber))
(define (positive-pr-number value path)
  (unless (exact-integer? value)
    (fail-input path "expected an integer"))
  (when (<= value 0)
    (fail-input path "must be positive"))
  (PrNumber (assert value exact-positive-integer?)))

(: json-boolean (-> JSExpr String Boolean))
(define (json-boolean value path)
  (if (boolean? value)
      value
      (fail-input path "expected a boolean")))

(: leap-year? (-> Integer Boolean))
(define (leap-year? year)
  (or (zero? (modulo year 400))
      (and (zero? (modulo year 4))
           (not (zero? (modulo year 100))))))

(: days-in-month (-> Integer Integer Integer))
(define (days-in-month year month)
  (case month
    [(1 3 5 7 8 10 12) 31]
    [(4 6 9 11) 30]
    [(2) (if (leap-year? year) 29 28)]
    [else 0]))

(: matched-integer (-> (Listof (Option String)) Natural Integer))
(define (matched-integer captures index)
  (define value (list-ref captures index))
  (if value (assert (string->number value) exact-integer?) 0))

(: timestamp (-> JSExpr String String))
(define (timestamp value path)
  (define text (json-string value path))
  (define matched
    (or (regexp-match
         #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"
         text)
        (fail-input path "expected an RFC 3339 timestamp")))
  (define captures : (Listof (Option String))
    (cdr matched))
  (define year (matched-integer captures 0))
  (define month (matched-integer captures 1))
  (define day (matched-integer captures 2))
  (define hour (matched-integer captures 3))
  (define minute (matched-integer captures 4))
  (define second (matched-integer captures 5))
  (define zone (list-ref captures 6))
  (unless (and (<= 1 month 12)
               (<= 1 day (days-in-month year month))
               (<= 0 hour 23)
               (<= 0 minute 59)
               (<= 0 second 60))
    (fail-input path "expected an RFC 3339 timestamp"))
  (when (and zone (not (string=? zone "Z")))
    (define zone-hour (assert (string->number (substring zone 1 3)) exact-integer?))
    (define zone-minute (assert (string->number (substring zone 4 6)) exact-integer?))
    (unless (and (<= 0 zone-hour 23) (<= 0 zone-minute 59))
      (fail-input path "expected an RFC 3339 timestamp")))
  text)

(: mergeable (-> JSExpr String Mergeable))
(define (mergeable value path)
  (define text (json-string value path))
  (cond
    [(string=? text "MERGEABLE") 'mergeable]
    [(string=? text "CONFLICTING") 'conflicting]
    [(string=? text "UNKNOWN") 'unknown]
    [else (fail-input path "expected one of: CONFLICTING, MERGEABLE, UNKNOWN")]))

(: review-decision (-> JSExpr String ReviewDecision))
(define (review-decision value path)
  (define text (json-string value path))
  (cond
    [(string=? text "APPROVED") 'approved]
    [(string=? text "CHANGES_REQUESTED") 'changes-requested]
    [(string=? text "REVIEW_REQUIRED") 'review-required]
    [(string=? text "NONE") 'none]
    [else
     (fail-input path
                 "expected one of: APPROVED, CHANGES_REQUESTED, NONE, REVIEW_REQUIRED")]))

(: paths (-> JSExpr String (Listof String)))
(define (paths value path)
  (define decoded
    (for/list : (Listof String) ([item (in-list (json-array value path))]
                                 [index (in-naturals)])
      (define item-path (format "~a[~a]" path index))
      (define text (json-string item item-path))
      (when (string-prefix? text "/")
        (fail-input item-path "expected a repository-relative path"))
      text))
  (unless (= (length decoded) (length (remove-duplicates decoded)))
    (fail-input path "paths must be unique"))
  (sort decoded string<?))

(: revision (-> JSExpr String GitRevision))
(define (revision value path)
  (define text (json-string value path))
  (when (string-prefix? text "-")
    (fail-input path "revision must not start with '-'"))
  (when (regexp-match? #px"[\u0000-\u001f\u007f]" text)
    (fail-input path "revision must not contain control characters"))
  (GitRevision text))

(: decode-pull-request (-> JSExpr Natural Mode PullRequest))
(define (decode-pull-request value index mode)
  (define path (format "$.prs[~a]" index))
  (define item (json-object value path))
  (exact-keys! item (if (eq? mode 'pure) pure-pr-keys git-pr-keys) path)
  (define number (positive-pr-number (required item 'number)
                                     (string-append path ".number")))
  (define-values (files base-conflicts git-head git-base)
    (if (eq? mode 'pure)
        (values (paths (required item 'files) (string-append path ".files"))
                (paths (required item 'base_conflict_paths)
                       (string-append path ".base_conflict_paths"))
                #f
                #f)
        (values '()
                '()
                (revision (required item 'git_head)
                          (string-append path ".git_head"))
                (revision (required item 'git_base)
                          (string-append path ".git_base")))))
  (PullRequest
   number
   (json-string (required item 'title) (string-append path ".title"))
   (optional-string (required item 'author) (string-append path ".author"))
   (json-string (required item 'head_ref) (string-append path ".head_ref"))
   (json-string (required item 'base_ref) (string-append path ".base_ref"))
   (json-boolean (required item 'draft) (string-append path ".draft"))
   (mergeable (required item 'mergeable) (string-append path ".mergeable"))
   (review-decision (required item 'review_decision)
                    (string-append path ".review_decision"))
   (timestamp (required item 'created_at) (string-append path ".created_at"))
   (timestamp (required item 'updated_at) (string-append path ".updated_at"))
   (nonnegative-integer (required item 'additions)
                        (string-append path ".additions"))
   (nonnegative-integer (required item 'deletions)
                        (string-append path ".deletions"))
   files base-conflicts git-head git-base))

(: known-pr (-> JSExpr String (Listof PrNumber) PrNumber))
(define (known-pr value path known)
  (define number (positive-pr-number value path))
  (unless (pr-list-member? number known)
    (fail-input path (format "unknown pull request #~a" (PrNumber-value number))))
  number)

(: decode-conflicts (-> JSExpr (Listof PrNumber) (Listof ConflictEdge)))
(define (decode-conflicts value known)
  (define seen : (Listof (Pairof PrNumber PrNumber)) '())
  (define decoded
    (for/list : (Listof ConflictEdge)
      ([raw (in-list (json-array value "$.conflict_edges"))]
       [index (in-naturals)])
      (define path (format "$.conflict_edges[~a]" index))
      (define item (json-object raw path))
      (exact-keys! item '(a b paths) path)
      (define first (known-pr (required item 'a) (string-append path ".a") known))
      (define second (known-pr (required item 'b) (string-append path ".b") known))
      (when (pr=? first second)
        (fail-input path "a conflict edge must join two different pull requests"))
      (define a (if (pr<? first second) first second))
      (define b (if (pr<? first second) second first))
      (when (ormap (lambda ([pair : (Pairof PrNumber PrNumber)])
                     (and (pr=? a (car pair)) (pr=? b (cdr pair))))
                   seen)
        (fail-input path
                    (format "duplicate conflict edge #~a/#~a"
                            (PrNumber-value a) (PrNumber-value b))))
      (set! seen (cons (cons a b) seen))
      (ConflictEdge a b
                    (paths (required item 'paths) (string-append path ".paths")))))
  (sort decoded conflict<?))

(: decode-ancestry
   (-> JSExpr (Listof PrNumber) (Listof (Pairof PrNumber PrNumber))))
(define (decode-ancestry value known)
  (define seen : (Listof (Pairof PrNumber PrNumber)) '())
  (define decoded
    (for/list : (Listof (Pairof PrNumber PrNumber))
      ([raw (in-list (json-array value "$.ancestry_edges"))]
       [index (in-naturals)])
      (define path (format "$.ancestry_edges[~a]" index))
      (define item (json-object raw path))
      (exact-keys! item '(before after) path)
      (define before
        (known-pr (required item 'before) (string-append path ".before") known))
      (define after
        (known-pr (required item 'after) (string-append path ".after") known))
      (when (pr=? before after)
        (fail-input path "an ancestry edge must join two different pull requests"))
      (when (ormap (lambda ([pair : (Pairof PrNumber PrNumber)])
                     (and (pr=? before (car pair)) (pr=? after (cdr pair))))
                   seen)
        (fail-input path
                    (format "duplicate ancestry edge #~a -> #~a"
                            (PrNumber-value before) (PrNumber-value after))))
      (define pair (cons before after))
      (set! seen (cons pair seen))
      pair))
  (sort decoded
        (lambda ([left : (Pairof PrNumber PrNumber)]
                 [right : (Pairof PrNumber PrNumber)])
          (or (pr<? (car left) (car right))
              (and (pr=? (car left) (car right))
                   (pr<? (cdr left) (cdr right)))))))

(: decode-document (-> JSExpr Mode AnalysisInput))
(define (decode-document value mode)
  (define root (json-object value "$"))
  (exact-keys! root (if (eq? mode 'pure) pure-root-keys git-root-keys) "$")
  (define version (nonnegative-integer (required root 'schema_version)
                                       "$.schema_version"))
  (unless (= version 1)
    (fail-input "$.schema_version" "only schema version 1 is supported"))
  (define repository (json-string (required root 'repository) "$.repository"))
  (define prs
    (sort
     (for/list : (Listof PullRequest)
       ([item (in-list (json-array (required root 'prs) "$.prs"))]
        [index (in-naturals)])
       (decode-pull-request item (assert index exact-nonnegative-integer?) mode))
     (lambda ([left : PullRequest] [right : PullRequest])
       (pr<? (PullRequest-number left) (PullRequest-number right)))))
  (define numbers (map PullRequest-number prs))
  (unless (= (length numbers) (length (remove-duplicates numbers)))
    (fail-input "$.prs" "pull request numbers must be unique"))
  (define heads (map PullRequest-head-ref prs))
  (unless (= (length heads) (length (remove-duplicates heads)))
    (fail-input "$.prs" "head_ref values must be unique"))
  (if (eq? mode 'pure)
      (AnalysisInput repository prs
                     (decode-conflicts (required root 'conflict_edges) numbers)
                     (decode-ancestry (required root 'ancestry_edges) numbers))
      (AnalysisInput repository prs '() '())))

(: load-document (-> Path-String Mode AnalysisInput))
(define (load-document path mode)
  (define display-path (if (path? path) (path->string path) path))
  (define value
    (with-handlers ([exn:fail:filesystem?
                     (lambda ([error : exn:fail:filesystem])
                       (fail-input display-path (exn-message error)))]
                    [exn:fail:read?
                     (lambda ([error : exn:fail:read])
                       (fail-input display-path
                                   (string-append "invalid JSON: "
                                                  (exn-message error))))])
      (call-with-input-file
       path
       (lambda ([input : Input-Port])
         (define first (read-json input))
         (unless (eof-object? first)
           (define trailing (read-json input))
           (unless (eof-object? trailing)
             (fail-input display-path "invalid JSON: trailing value")))
         first))))
  (if (eof-object? value)
      (fail-input display-path "invalid JSON: unexpected end of input")
      (decode-document value mode)))
