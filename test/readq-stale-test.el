;;; readq-stale-test.el --- Tests for stale extracts -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-stale-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defmacro readq-sttest--with-extracts (&rest body)
  "Run BODY with a book `book' and extracts `x1', `x2', `x3' of it."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq--focus nil)
           (readq-stale-reviews 5)
           (readq-stale-days 60))
       (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
              (x1 (readq--create-extract book "Systole is the phase of contraction."
                                         :page 57 :comment "Key definition"))
              (x2 (readq--create-extract book "Diastole is the phase of relaxation."
                                         :page 58))
              (x3 (readq--create-extract book "Cardiac output is stroke volume times rate."
                                         :page 60)))
         (ignore book x1 x2 x3)
         ,@body))))

(defun readq-sttest--age (item reviews days)
  "Give ITEM REVIEWS reviews, made DAYS ago."
  (readq--put item :sessions reviews :added (readq--date-in (- days))))

(defun readq-sttest--org (item)
  "Return the contents of ITEM's Org file."
  (with-temp-buffer (insert-file-contents (readq--get item :file)) (buffer-string)))

;;;; What is stale

(ert-deftest readq-sttest-stale-p ()
  (readq-sttest--with-extracts
    (should-not (readq--stale-extracts))
    ;; Reviewed often.
    (readq-sttest--age x1 5 3)
    ;; Old and reviewed twice.
    (readq-sttest--age x2 2 61)
    ;; Old but reviewed once only.
    (readq-sttest--age x3 1 90)
    (should (equal (readq--stale-extracts) (list x1 x2)))
    ;; Ready for a card, dismissed or paused: acted on.
    (readq--put x1 :status 'ready)
    (readq--put x2 :status 'finished)
    (should-not (readq--stale-extracts))))

(ert-deftest readq-sttest-sub-extracts-are-progress ()
  (readq-sttest--with-extracts
    (readq-sttest--age x1 8 3)
    (should (equal (readq--stale-extracts) (list x1)))
    (readq--create-extract x1 "phase of contraction")
    (should-not (readq--stale-extracts))))

(ert-deftest readq-sttest-options ()
  (readq-sttest--with-extracts
    (readq-sttest--age x1 5 3)
    (readq-sttest--age x2 2 61)
    (let ((readq-stale-reviews nil))
      (should (equal (readq--stale-extracts) (list x2))))
    (let ((readq-stale-days nil))
      (should (equal (readq--stale-extracts) (list x1))))
    (let ((readq-stale-reviews 10) (readq-stale-days 100))
      (should-not (readq--stale-extracts)))))

(ert-deftest readq-sttest-tags ()
  (readq-sttest--with-extracts
    (readq-sttest--age x1 5 3)
    (readq-set-tags x1 '("exam"))
    (readq-sttest--age x2 5 3)
    (should (equal (readq--stale-extracts '("exam")) (list x1)))
    (should (= (length (readq--stale-extracts)) 2))))

(ert-deftest readq-sttest-keep ()
  (readq-sttest--with-extracts
    (readq-sttest--age x1 5 90)
    (readq--keep-extract x1)
    (should-not (readq--stale-extracts))
    ;; Stale again after as many reviews again...
    (readq--put x1 :sessions 10)
    (should (readq--stale-extracts))
    ;; ...or, with two reviews, as many days.
    (readq--put x1 :sessions 7 :kept (list :date (readq--date-in -61) :sessions 5))
    (should (readq--stale-extracts))
    (readq--put x1 :sessions 6)
    (should-not (readq--stale-extracts))))

(ert-deftest readq-sttest-dashboard-summary ()
  (readq-sttest--with-extracts
    (should-not (string-match-p "stale" (readq--dashboard-summary)))
    (readq-sttest--age x1 5 3)
    (should (string-match-p "1 stale" (readq--dashboard-summary)))))

;;;; Merging

(ert-deftest readq-sttest-merge ()
  (readq-sttest--with-extracts
    (should (equal (readq--org-entry-body x2)
                   (string-trim (readq--org-entry-body x2))))
    (should (string-match-p "Diastole" (readq--org-entry-body x2)))
    (readq-merge-extract x2 x1)
    (should-not (memq x2 (readq--books)))
    (should (memq x1 (readq--books)))
    (let ((org (readq-sttest--org x1)))
      ;; One entry fewer, its text now under x1.
      (should-not (string-match-p (regexp-quote (readq--get x2 :id)) org))
      (should (string-match-p "Merged from: Diastole" org))
      (should (string-match-p "Diastole is the phase of relaxation" org))
      ;; Its source link now points to its page in the book.
      (should (string-match-p (format "\\[\\[readq:%s::p58\\]" (readq--get book :id)) org))
      (with-temp-buffer
        (insert org)
        (org-mode)
        (goto-char (org-find-property "READQ_ID" (readq--get x1 :id)))
        (let ((body (buffer-substring (point) (save-excursion (org-end-of-subtree t) (point)))))
          (should (string-match-p "Systole" body))
          (should (string-match-p "Key definition" body))
          (should (string-match-p "Diastole" body))
          (should-not (string-match-p "Cardiac output" body)))))))

(ert-deftest readq-sttest-merge-refuses ()
  (readq-sttest--with-extracts
    (should-error (readq-merge-extract x1 x1) :type 'user-error)
    (should-error (readq-merge-extract book x1) :type 'user-error)
    (readq--create-extract x1 "phase of contraction")
    (should-error (readq-merge-extract x1 x2) :type 'user-error)))

(ert-deftest readq-sttest-merge-target-order ()
  (readq-sttest--with-extracts
    (let* ((other (readq-add-book (readq-test--touch "gray.pdf") 20 "Gray"))
           (y (readq--create-extract other "Another book's extract." :page 1))
           seen)
      (ignore y)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq seen (all-completions "" table))
                   (car seen))))
        (readq--read-merge-target x1))
      ;; x1 itself isn't offered; its book's extracts come first.
      (should (= (length seen) 3))
      (should (string-match-p "Diastole" (nth 0 seen)))
      (should (string-match-p "Another book" (nth 2 seen))))))

;;;; The walk-through

(defmacro readq-sttest--answers (answers &rest body)
  "Run BODY answering `read-multiple-choice' with ANSWERS in turn."
  (declare (indent 1))
  `(let ((answers ,answers))
     (cl-letf (((symbol-function 'read-multiple-choice)
                (lambda (_prompt choices &rest _)
                  (assq (pop answers) choices)))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       ,@body)))

(ert-deftest readq-sttest-walk-through ()
  (readq-sttest--with-extracts
    (let ((readq-stale-priority-step 20))
      (readq-sttest--age x1 9 3)
      (readq-sttest--age x2 7 3)
      (readq-sttest--age x3 6 3)
      ;; Most reviewed first: card x1, dismiss x2, lower x3.
      (readq-sttest--answers '(?c ?d ?l)
        (readq-stale-extracts))
      (should (eq (readq--get x1 :status) 'ready))
      (should (eq (readq--get x2 :status) 'finished))
      (should (eq (readq--get x3 :status) 'active))
      (should (= (readq--get x3 :priority) 40))
      (should-not (readq--stale-extracts))
      (should-error (readq-stale-extracts) :type 'user-error))))

(ert-deftest readq-sttest-walk-through-merge-delete-quit ()
  (readq-sttest--with-extracts
    (readq-sttest--age x1 9 3)
    (readq-sttest--age x2 7 3)
    (readq-sttest--age x3 6 3)
    (cl-letf (((symbol-function 'readq--read-merge-target) (lambda (_) x3)))
      (readq-sttest--answers '(?m ?D)
        (readq-stale-extracts)))
    (should-not (memq x1 (readq--books)))
    (should-not (memq x2 (readq--books)))
    (should (string-match-p "Merged from: Systole" (readq-sttest--org x3)))
    (should-not (string-match-p "Diastole" (readq-sttest--org x3)))
    ;; x3 is still stale; stopping leaves it so.
    (readq-sttest--answers '(?q)
      (readq-stale-extracts))
    (should (equal (readq--stale-extracts) (list x3)))
    (readq-sttest--answers '(?e)
      (readq-stale-extracts))
    (should (equal (org-entry-get nil "READQ_ID") (readq--get x3 :id)))))

(provide 'readq-stale-test)
;;; readq-stale-test.el ends here
