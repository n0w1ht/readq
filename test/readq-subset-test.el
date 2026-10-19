;;; readq-subset-test.el --- Tests for subset review -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-subset-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defmacro readq-subtest--with-library (&rest body)
  "Run BODY with two PDF books, a section and extracts.
Guyton has the section `heart' (pages 101-200), the extracts `in' (page
150), `sub' (made from `in') and `out' (page 50); Novel has `novel-x'."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((guyton (readq-add-book (readq-test--touch "guyton.pdf") 40 "Guyton" '("cardio")))
            (novel (readq-add-book (readq-test--touch "novel.pdf") 10 "Novel" '("leisure")))
            (heart (readq--make-section guyton (list :title "Heart" :start 101 :end 200) 30))
            (in (readq--create-extract guyton "Systole is contraction." :page 150 :priority 20))
            (sub (readq--create-extract in "Contraction." :priority 50))
            (out (readq--create-extract guyton "Cells are small." :page 50 :priority 60))
            (novel-x (readq--create-extract novel "Once upon a time." :page 3)))
       (ignore guyton novel heart in sub out novel-x)
       ,@body)))

(defun readq-subtest--next ()
  "Run `readq-next' and return the item it opened."
  (let (opened)
    (cl-letf (((symbol-function 'readq-open) (lambda (item) (setq opened item) t)))
      (with-temp-buffer (readq-next)))
    opened))

(defun readq-subtest--titles (items)
  "Return the titles of ITEMS."
  (mapcar (lambda (x) (readq--get x :title)) items))

(ert-deftest readq-subtest-members ()
  (readq-subtest--with-library
    ;; A book: itself, its sections and all its extracts, due or not,
    ;; most important first.
    (should-not (readq--due-p in))
    (should (equal (readq--subset-of guyton) (list in heart guyton sub out)))
    ;; A section: itself and the extracts made in it, sub-extracts too.
    (should (equal (readq--subset-of heart) (list in heart sub)))
    ;; An extract: itself and those made from it.
    (should (equal (readq--subset-of in) (list in sub)))
    (should (equal (readq--subset-of sub) (list sub)))
    ;; A tag: everything that has it, from the book's tags too.
    (should (equal (readq--subset-of "leisure") (list novel novel-x)))
    ;; Paused or finished items are left out.
    (readq--put out :status 'paused)
    (should-not (memq out (readq--subset-of guyton)))
    ;; Only due ones, if you want.
    (let ((readq-subset-due-only t))
      (should (equal (readq--subset-of guyton) (list heart guyton))))))

(ert-deftest readq-subtest-text-section ()
  ;; In text books, an extract belongs to the section of its heading.
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "notes.org") 30 "Notes"))
           (sec (readq--make-section book (list :title "Heart" :level 1) 30))
           (a (readq--create-extract book "Systole." :point 10 :section "Heart" :priority 10))
           (b (readq--create-extract book "Lungs." :point 90 :section "Lungs")))
      (ignore b)
      (should (equal (readq--subset-of sec) (list a sec))))))

(ert-deftest readq-subtest-review ()
  (readq-subtest--with-library
    (let (opened)
      (cl-letf (((symbol-function 'readq-open) (lambda (item) (push item opened) t)))
        (with-temp-buffer (readq-review-subset heart)))
      ;; The first opens right away.
      (should (equal opened (list in)))
      (should (equal (plist-get readq--subset :name) "Guyton › Heart"))
      (should (equal (readq--subset-string) "Guyton › Heart: 2 of 3 left"))
      (should (string-match-p "reviewing Guyton › Heart: 2 of 3 left" (readq--dashboard-summary)))
      ;; The subset is saved with the database.
      (setq readq--subset nil readq--loaded nil readq--books nil)
      (readq--books)
      (should (equal (readq--subset-string) "Guyton › Heart: 2 of 3 left"))
      ;; readq-next follows it, though Novel would come first otherwise.
      (should (equal (readq-subtest--next) (readq--book-by-id (readq--get heart :id))))
      (should (equal (readq--get (readq-subtest--next) :id) (readq--get sub :id)))
      ;; Then it ends, and the queue is back.
      (should-not (readq-subtest--next))
      (should-not readq--subset)
      (should (equal (readq--get (readq-subtest--next) :id) (readq--get novel :id))))))

(ert-deftest readq-subtest-skips-gone-items ()
  (readq-subtest--with-library
    (cl-letf (((symbol-function 'readq-open) (lambda (_) t)))
      (with-temp-buffer (readq-review-subset in)))
    ;; Dismissed or deleted since: skipped.
    (readq--put sub :status 'finished)
    (should-not (readq-subtest--next))
    (should-not readq--subset)))

(ert-deftest readq-subtest-stop ()
  (readq-subtest--with-library
    (cl-letf (((symbol-function 'readq-open) (lambda (_) t)))
      (with-temp-buffer (readq-review-subset guyton)))
    (should readq--subset)
    (readq-review-subset 'stop)
    (should-not readq--subset)
    (should-error (readq-review-subset 'stop) :type 'user-error)
    ;; Nothing to review: an error, and no subset.
    (readq--put novel-x :status 'paused)
    (readq--put novel :status 'paused)
    (should-error (readq-review-subset "leisure") :type 'user-error)
    (should-not readq--subset)))

(ert-deftest readq-subtest-read-target ()
  (readq-subtest--with-library
    ;; The item at point is proposed first; tags are offered too.
    (let (seen)
      (cl-letf (((symbol-function 'readq--item-here) (lambda () heart))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest args)
                   (setq seen (all-completions "" table))
                   (nth 4 args))))
        (should (eq (readq--read-subset-target) heart)))
      (should (string-match-p "Heart" (car seen)))
      (should (member "#cardio" seen)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "#leisure")))
      (should (equal (readq--read-subset-target) "leisure")))))

(provide 'readq-subset-test)
;;; readq-subset-test.el ends here
