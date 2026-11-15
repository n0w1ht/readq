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
             (book (readq-add-book (readq-test--touch "guyton.pdf") 30 "Guyton"))
             (row (lambda (x)
                    (let ((up (readq--dashboard-parent x)))
                      (if (eq up book) 'book (readq--get up :title))))))
        (should (equal (funcall row (readq--create-extract book "In valves." :page 25))
                       "Heart"))
        (should (equal (funcall row (readq--create-extract book "In the preface." :page 5))
                       "Cardio"))
        (should (equal (funcall row (readq--create-extract book "In renal." :page 150))
                       "Renal"))
        (should (eq (funcall row (readq--create-extract book "Past the end." :page 300))
                    'book))
        ;; The notes sort by page in the folder: no chapter in their names.
        (should (equal (sort (mapcar (lambda (x)
                                       (and (string-match "==\\([^-]+\\)--"
                                                          (readq--get x :file))
                                            (match-string 1 (readq--get x :file))))
                                     (readq--extracts-of book))
                             #'string<)
                       '("guyton=p0005" "guyton=p0025" "guyton=p0150" "guyton=p0300")))))))

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
