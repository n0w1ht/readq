;;; readq-dashboard-test.el --- Tests for the readq dashboard -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-dashboard-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The icon tests need all-the-icons on the load path.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defun readq-dbtest--headers ()
  "Return the column names of the dashboard in this buffer."
  (mapcar #'car tabulated-list-format))

(defun readq-dbtest--line (title)
  "Return the dashboard line showing TITLE."
  (goto-char (point-min))
  (should (search-forward title nil t))
  (buffer-substring (line-beginning-position) (line-end-position)))

(ert-deftest readq-dbtest-columns ()
  (readq-xtest--with-db
    (let ((book (readq-add-book (readq-test--touch "Gray.pdf") 20 "Gray")))
      (readq)
      (with-current-buffer "*readq*"
        ;; No tags or deadlines yet: no columns for them.
        (should (equal (readq-dbtest--headers)
                       '("Pri" "Kind" "Title" "Progress" "Position" "Ext" "Due" "Time")))
        (should (string-match-p "^ +20 pdf +Gray +.*today" (readq-dbtest--line "Gray")))
        (readq-set-tags book '("anatomy"))
        (readq-set-deadline book (readq--date-in 5))
        (should (equal (readq-dbtest--headers)
                       '("Pri" "Kind" "Title" "Tags" "Progress" "Position" "Ext" "Due"
                         "Deadline" "Time")))
        ;; Your own choice of columns.
        (let ((readq-dashboard-columns '(title interval last-read)))
          (readq--refresh-dashboard)
          (should (equal (readq-dbtest--headers) '("Title" "Ivl" "Last read")))
          (should (string-match-p "Gray +1d +never" (readq-dbtest--line "Gray"))))
        ;; `g' sets them again too.
        (revert-buffer)
        (should (member "Deadline" (readq-dbtest--headers)))
        (kill-buffer)))))

(ert-deftest readq-dbtest-icons ()
  (skip-unless (require 'all-the-icons nil t))
  (readq-xtest--with-db
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (let* ((pdf (readq-add-book (readq-test--touch "Gray.pdf") 20 "Gray"))
             (epub (readq-add-book (readq-test--touch "Robbins.epub") 30 "Robbins"))
             (org (readq-add-book (readq-test--touch "notes.org") 40 "Notes"))
             (talk (readq-add-book (readq-test--touch "talk.mp3") 50 "Talk"))
             (x (readq--create-extract pdf "Systole ejects blood." :page 3))
             (icon (lambda (item) (aref (cadr (readq--dashboard-entry item)) 1))))
        (readq--put talk :format 'media)
        (readq--put epub :status 'paused)
        (readq--put org :due (readq--date-in -2))
        (should (readq--icons-p))
        (readq)
        (with-current-buffer "*readq*"
          (should (equal (nth 1 (readq-dbtest--headers)) ""))
          ;; Each kind has its icon, named in its tooltip.
          (should (equal (get-text-property 0 'help-echo (funcall icon epub)) "EPUB"))
          (should (equal (get-text-property 0 'help-echo (funcall icon talk)) "audio"))
          (should (equal (get-text-property 0 'help-echo (funcall icon x)) "extract"))
          (should (equal (get-text-property 0 'help-echo (funcall icon pdf)) "pdf"))
          (should (equal (get-text-property 0 'help-echo (funcall icon org)) "org"))
          (should (equal (funcall icon pdf)
                         (all-the-icons-icon-for-file "Gray.pdf" :v-adjust 0.0 :height 1.0)))
          (readq-set-viewer pdf 'sumatra)
          (should (equal (get-text-property 0 'help-echo (funcall icon pdf))
                         "PDF, read in SumatraPDF"))
          (let ((fig (readq--create-figure pdf (list :data "x" :type 'png) :page 1)))
            (should (equal (get-text-property 0 'help-echo (funcall icon fig))
                           "figure extract")))
          ;; The Due column has an icon before the words.
          (should (string-match-p "today\\'" (readq--due-cell pdf)))
          (should (string-match-p "\\`. 2d late\\'" (readq--due-cell org)))
          (should (eq (get-text-property 2 'face (readq--due-cell org)) 'readq-overdue-face))
          (should (string-match-p "\\`. paused\\'" (readq--due-cell epub)))
          (kill-buffer))
        ;; Turned off, or in a terminal: words.
        (let ((readq-dashboard-icons nil))
          (should-not (readq--icons-p))
          (should (equal (aref (cadr (readq--dashboard-entry epub)) 1) "epub"))
          (should (equal (readq--due-cell epub) (propertize "paused" 'face 'readq-inactive-face))))))))

(defun readq-dbtest--titles ()
  "Return the Title cells of the dashboard, as shown."
  (save-excursion
    (goto-char (point-min))
    (let (titles)
      (while (not (eobp))
        (push (string-trim-right (substring-no-properties
                                  (aref (tabulated-list-get-entry)
                                        (cl-position "Title" (readq-dbtest--headers)
                                                     :test #'equal))))
              titles)
        (forward-line 1))
      (nreverse titles))))

(ert-deftest readq-dbtest-hierarchy ()
  (readq-xtest--with-db
    (let* ((a (readq-add-book (readq-test--touch "a.pdf") 50 "Anatomy"))
           (b (readq-add-book (readq-test--touch "b.pdf") 20 "Biochemistry"))
           (ch (readq-add-section a "Heart" 5 8 60))
           (x1 (readq--create-extract a "First passage." :page 2))
           (x2 (readq--create-extract a "Second passage." :page 3))
           (sub (readq--create-extract x1 "Sub passage." :page 2))
           (lone (readq--create-extract b "Biochemistry passage." :page 9)))
      (dolist (x (list a b x1 x2 sub lone ch)) (readq--put x :due (readq--date-in 3)))
      (readq)
      (with-current-buffer "*readq*"
        ;; Books first, most urgent first; nothing under them is due: folded.
        (should (equal (readq-dbtest--titles) '("▸ Biochemistry" "▸ Anatomy")))
        ;; TAB unfolds a book: its section and extracts, in the order to
        ;; read them (the extracts are more important than the section).
        (readq--dashboard-goto (readq--get a :id))
        (readq-dashboard-toggle-fold)
        (should (equal (tabulated-list-get-id) (readq--get a :id)))
        (should (equal (readq-dbtest--titles)
                       '("▸ Biochemistry" "▾ Anatomy" "  ▸ First passage."
                         "    Second passage." "    Heart")))
        (readq--dashboard-goto (readq--get x1 :id))
        (readq-dashboard-toggle-fold)
        (should (member "      Sub passage." (readq-dbtest--titles)))
        ;; TAB on an item with nothing under it folds its parent.
        (readq--dashboard-goto (readq--get sub :id))
        (readq-dashboard-toggle-fold)
        (should (equal (tabulated-list-get-id) (readq--get x1 :id)))
        (should-not (member "      Sub passage." (readq-dbtest--titles)))
        ;; S-TAB: everything, then nothing.
        (readq-dashboard-toggle-all-folds)
        (should (equal (readq-dbtest--titles) '("▸ Biochemistry" "▸ Anatomy")))
        (readq-dashboard-toggle-all-folds)
        (should (= (length (readq-dbtest--titles)) 7))
        ;; Something due under a folded book opens it, unless you folded it.
        (readq-dashboard-toggle-all-folds)
        (clrhash readq--dashboard-folds)
        (readq--put sub :due (readq--today))
        (readq--refresh-dashboard)
        (should (equal (readq-dbtest--titles)
                       '("▾ Anatomy" "  ▾ First passage." "      Sub passage."
                         "    Second passage." "    Heart" "▸ Biochemistry")))
        ;; Sorting by a column sorts within each level; reversed too.
        (tabulated-list-sort (cl-position "Title" (readq-dbtest--headers) :test #'equal))
        (should (equal (readq-dbtest--titles)
                       '("▾ Anatomy" "  ▾ First passage." "      Sub passage." "    Heart"
                         "    Second passage." "▸ Biochemistry")))
        (tabulated-list-sort (cl-position "Title" (readq-dbtest--headers) :test #'equal))
        (should (equal (readq-dbtest--titles)
                       '("▸ Biochemistry" "▾ Anatomy" "    Second passage." "    Heart"
                         "  ▾ First passage." "      Sub passage.")))
        (kill-buffer)))))

(ert-deftest readq-dbtest-parents-of-shown-items ()
  (readq-xtest--with-db
    (let* ((a (readq-add-book (readq-test--touch "a.pdf") 50 "Done book"))
           (x (readq--create-extract a "Still to review." :page 2)))
      (readq--put a :status 'finished)
      (readq--put x :due (readq--today))
      (readq)
      (with-current-buffer "*readq*"
        ;; A finished book is listed when something under it is.
        (should (equal (readq-dbtest--titles) '("▾ Done book" "    Still to review.")))
        (readq-dashboard-toggle-extracts)
        (should (equal (readq-dbtest--titles) '()))
        (kill-buffer)))))

(provide 'readq-dashboard-test)
;;; readq-dashboard-test.el ends here
