;;; readq-chapter-test.el --- Extracts grouped under chapters -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-chapter-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-chtest--org
  "* Part I
Intro of part I.
** Heart
The heart pumps.
*** Valves
Valves close.
** Lungs
Gas exchange.
* Part II
** Kidney
Filtering.
")

(defmacro readq-chtest--with-book (&rest body)
  "Run BODY with `book', an Org book with parts and chapters."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((file (expand-file-name "physio.org" readq-test--dir))
            (book (progn (with-temp-file file (insert readq-chtest--org))
                         (readq-add-book file 30 "Physio")))
            (readq-chapter-depth 2))
       (clrhash readq--chapter-cache)
       ,@body)))

(defun readq-chtest--extract (book section text)
  "Make an extract of TEXT in SECTION of BOOK."
  (readq--create-extract book text :point 1 :section section))

(defun readq-chtest--outline (book)
  "Return the headings of BOOK's extracts file as strings: stars and title."
  (with-temp-buffer
    (insert-file-contents (readq--get book :extracts-file))
    (let (result)
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+ .*\\)$" nil t)
        (push (match-string 1) result))
      (nreverse result))))

;;;; Extracts files

(ert-deftest readq-chtest-org-file ()
  (readq-chtest--with-book
    (readq-chtest--extract book "Kidney" "Filtering.")
    (readq-chtest--extract book "Valves" "Valves close.")
    (readq-chtest--extract book "Lungs" "Gas exchange.")
    (readq-chtest--extract book "Heart" "The heart pumps.")
    (readq-chtest--extract book "Part I" "Intro of part I.")
    (readq-chtest--extract book nil "Somewhere.")
    ;; In book order; a part's own extracts before its chapters; a
    ;; section deeper than `readq-chapter-depth' in its chapter.
    (should (equal (readq-chtest--outline book)
                   '("* Part I"
                     "** Intro of part I."
                     "** Heart"
                     "*** Valves close."
                     "*** The heart pumps."
                     "** Lungs"
                     "*** Gas exchange."
                     "* Part II"
                     "** Kidney"
                     "*** Filtering."
                     "* Somewhere.")))
    ;; Chapter headings are marked as such, extracts still have their ids.
    (with-current-buffer (find-file-noselect (readq--get book :extracts-file))
      (goto-char (point-min))
      (search-forward "* Part I")
      (should (equal (org-entry-get (point) "READQ_CHAPTER") "Part I #1"))
      (should-not (org-entry-get (point) "READQ_ID"))
      (search-forward "Valves close.")
      (should (readq--extract-at-point)))))

(ert-deftest readq-chtest-sub-extract-and-depth ()
  (readq-chtest--with-book
    (let ((readq-chapter-depth nil))
      (let* ((x (readq-chtest--extract book "Valves" "Valves close."))
             (sub (readq--create-extract x "close")))
        (ignore sub)
        (should (equal (readq-chtest--outline book)
                       '("* Part I" "** Heart" "*** Valves" "**** Valves close."
                         "***** close")))))))

(ert-deftest readq-chtest-no-chapters ()
  (readq-chtest--with-book
    (let ((readq-chapter-depth 0))
      (readq-chtest--extract book "Kidney" "Filtering.")
      (should (equal (readq-chtest--outline book) '("* Filtering."))))))

(ert-deftest readq-chtest-delete-prunes ()
  (readq-chtest--with-book
    (let ((kidney (readq-chtest--extract book "Kidney" "Filtering."))
          (lungs (readq-chtest--extract book "Lungs" "Gas exchange."))
          (heart (readq-chtest--extract book "Heart" "The heart pumps.")))
      (ignore heart)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (readq-delete-extract kidney)
        (should (equal (readq-chtest--outline book)
                       '("* Part I" "** Heart" "*** The heart pumps."
                         "** Lungs" "*** Gas exchange.")))
        (readq-delete-extract lungs)
        (should (equal (readq-chtest--outline book)
                       '("* Part I" "** Heart" "*** The heart pumps.")))))))

(ert-deftest readq-chtest-group-existing ()
  (readq-chtest--with-book
    (let* ((readq-chapter-depth 0)
           (kidney (readq-chtest--extract book "Kidney" "Filtering."))
           (valves (readq-chtest--extract book "Valves" "Valves close."))
           (sub (readq--create-extract valves "close" :comment "My note"))
           (other (readq-chtest--extract book nil "Somewhere.")))
      (ignore kidney sub other)
      (should (equal (readq-chtest--outline book)
                     '("* Filtering." "* Valves close." "** close" "* Somewhere.")))
      (let ((readq-chapter-depth 2))
        (should (= (readq-group-extracts book) 2))
        (should (equal (readq-chtest--outline book)
                       '("* Part I" "** Heart" "*** Valves close." "**** close"
                         "* Part II" "** Kidney" "*** Filtering."
                         "* Somewhere.")))
        ;; Notes and properties came along.
        (with-current-buffer (find-file-noselect (readq--get book :extracts-file))
          (goto-char (point-min))
          (search-forward "Note: My note")
          (should (equal (readq--extract-at-point) sub)))
        ;; Grouping again changes nothing.
        (should (= (readq-group-extracts book) 0))))))

;;;; PDFs

(ert-deftest readq-chtest-pdf-pages ()
  ;; In a PDF, the deepest chapter holding the extract's page.
  (readq-xtest--with-db
    (clrhash readq--chapter-cache)
    (cl-letf (((symbol-function 'readq--book-outline)
               (lambda (_)
                 (list (list :title "Cardio" :depth 1 :start 1 :end 100)
                       (list :title "Heart" :depth 2 :start 10 :end 50)
                       (list :title "Valves" :depth 3 :start 20 :end 30)
                       (list :title "Renal" :depth 1 :start 101 :end 200)))))
      (let* ((readq-chapter-depth 2)
             (book (readq-add-book (readq-test--touch "guyton.pdf") 30 "Guyton")))
        (readq--create-extract book "In valves." :page 25)
        (readq--create-extract book "In the preface." :page 5)
        (readq--create-extract book "In renal." :page 150)
        (readq--create-extract book "Past the end." :page 300)
        (should (equal (readq-chtest--outline book)
                       '("* Cardio" "** In the preface." "** Heart" "*** In valves."
                         "* Renal" "** In renal." "* Past the end.")))))))

;;;; Dashboard

(ert-deftest readq-chtest-dashboard ()
  (readq-chtest--with-book
    (let* ((valves (readq-chtest--extract book "Valves" "Valves close."))
           (kidney (readq-chtest--extract book "Kidney" "Filtering."))
           (heart-row (readq--dashboard-parent valves))
           (part-row (readq--dashboard-parent heart-row)))
      (should (readq--chapter-p heart-row))
      (should (equal (readq--get heart-row :title) "Heart"))
      (should (equal (readq--get part-row :title) "Part I"))
      (should (eq (readq--dashboard-parent part-row) book))
      (should (equal (readq--get (readq--dashboard-parent kidney) :title) "Kidney"))
      ;; Drawn as rows, chapters in book order.
      (readq--put valves :due (readq--today))
      (readq--put kidney :due (readq--today))
      (let* ((readq-dashboard-show-extracts t)
             (rows (mapcar (lambda (r) (readq--get r :title)) (readq--dashboard-tree))))
        (should (equal (cl-remove-if-not
                        (lambda (title) (member title '("Physio" "Part I" "Heart" "Part II" "Kidney")))
                        rows)
                       '("Physio" "Part I" "Heart" "Part II" "Kidney"))))
      ;; A section made from a chapter takes the chapter's place.
      (let ((sec (readq--make-section
                  book (cl-find "Heart" (readq--book-outline book)
                                :key (lambda (e) (plist-get e :title)) :test #'equal)
                  20)))
        (should (eq (readq--dashboard-parent valves) sec))
        (should (equal (readq--get (readq--dashboard-parent sec) :title) "Part I"))))))

(ert-deftest readq-chtest-subset-of-chapter ()
  (readq-chtest--with-book
    (let* ((valves (readq-chtest--extract book "Valves" "Valves close."))
           (lungs (readq-chtest--extract book "Lungs" "Gas exchange."))
           (kidney (readq-chtest--extract book "Kidney" "Filtering."))
           (part (readq--dashboard-parent (readq--dashboard-parent valves))))
      (ignore kidney)
      (should (equal (readq--get part :title) "Part I"))
      (should (equal (sort (mapcar (lambda (x) (readq--get x :title)) (readq--subset-of part))
                           #'string<)
                     (sort (list (readq--get valves :title) (readq--get lungs :title))
                           #'string<))))))

(provide 'readq-chapter-test)
;;; readq-chapter-test.el ends here
