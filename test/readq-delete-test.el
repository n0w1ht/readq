;;; readq-delete-test.el --- Deleting extracts with their highlights -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-delete-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The PDF file test needs pdf-tools (READQ_EPDFINFO); EPUB tests need
;; nov.el and zip; the multi-region test needs multi-region 0.2.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-highlight-test)

(defmacro readq-dtest--yes (&rest body)
  "Run BODY answering yes to every question."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
             ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
     ,@body))

(defun readq-dtest--org-has (item)
  "Return non-nil when the Org file of ITEM still has its entry."
  (and (file-exists-p (readq--get item :file))
       (string-match-p (concat ":READQ_ID: " (regexp-quote (readq--get item :id)))
                       (readq-xtest--org-text item))))

;;;; Text books

(ert-deftest readq-dtest-epub-highlight-at-point ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-htest--with-epub
    (let* ((range (readq-htest--range "Blood[ \n]+provides" "the[ \n]+lungs,"))
           (x (progn (readq-htest--select range) (readq-extract))))
      (should (readq-dtest--org-has x))
      ;; Point on the highlight: that extract is the one.
      (goto-char (+ (car range) 20))
      (should (eq (readq--extract-to-delete) x))
      (readq-dtest--yes (readq-delete-extract (readq--extract-to-delete)))
      (should-not (readq-htest--highlights))
      (should-not (readq-dtest--org-has x))
      (should-not (memq x (readq--books)))
      ;; And it stays gone when the chapter is shown again.
      (nov-goto-document 1)
      (should-not (readq-htest--highlights)))))

(ert-deftest readq-dtest-not-on-a-highlight ()
  (readq-ftest--with-db
    (let ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20)))
      (readq-open book)
      (goto-char (point-min))
      (should-error (readq--extract-to-delete) :type 'user-error))))

(ert-deftest readq-dtest-declining-keeps-everything ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20))
           (transient-mark-mode t))
      (readq-open book)
      (readq-ftest--select "Systole is the phase[^.]*\\.")
      (let ((x (readq-extract)))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
          (readq-delete-extract x))
        (should (memq x (readq--books)))
        (should (readq-dtest--org-has x))
        (should (readq-htest--highlights))))))

(ert-deftest readq-dtest-combined-extract ()
  (skip-unless (fboundp 'multi-region-selections))
  (readq-ftest--with-db
    (let ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20)))
      (readq-open book)
      (multi-region-mode 1)
      (let ((r1 (readq-htest--range "The heart pumps" "blood\\."))
            (r2 (readq-htest--range "The lungs" "gases\\.")))
        (multi-region--add (car r1) (cdr r1))
        (multi-region--add (car r2) (cdr r2))
        (let ((x (readq-extract)))
          (should (= (length (readq-htest--highlights)) 2))
          ;; From either passage, the whole extract goes.
          (goto-char (1+ (car r2)))
          (let (question)
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (q) (setq question q) t)))
              (readq-delete-extract (readq--extract-to-delete)))
            (should (string-match-p "(2 passages)" question)))
          (should-not (readq-htest--highlights))
          (should-not (readq-dtest--org-has x)))))))

(ert-deftest readq-dtest-sub-extracts-go-too ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20))
           (x (readq--create-extract book "Alpha beta gamma." :point 3))
           (sub (readq--create-extract x "beta" :point 3))
           (subsub (readq--create-extract sub "be" :point 3)))
      (should (equal (readq--extract-descendants x) (list sub subsub)))
      ;; From the extract's own Org entry.
      (readq--put x :due (readq--today))
      (readq-open x)
      (readq-dtest--yes (readq-delete-extract (readq--extract-to-delete)))
      (should-not readq-review-mode)
      (dolist (it (list x sub subsub))
        (should-not (memq it (readq--books)))
        (should-not (readq-dtest--org-has it))))))

(ert-deftest readq-dtest-dashboard ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20))
           (x (readq--create-extract book "The lungs exchange gases." :point 150)))
      (readq)
      (readq-dashboard-toggle-all-folds)
      (goto-char (point-min))
      (search-forward "The lungs exchange")
      (should (eq (readq--extract-to-delete) x))
      ;; D in the dashboard deletes an extract the same way.
      (readq-dtest--yes (readq-remove-book (readq--target-book)))
      (should-not (memq x (readq--books)))
      (should-not (readq-dtest--org-has x))
      (should (memq book (readq--books)))
      (kill-buffer "*readq*"))))

;;;; PDFs

(ert-deftest readq-dtest-pdf-file-real ()
  (skip-unless (readq-xtest--pdf-tools-p))
  (readq-xtest--with-db
    (let* ((file (readq-xtest--copy-fixture "highlighted.pdf" "heart.pdf"))
           (book (readq-add-book file 40 "Heart"))
           (markups (lambda ()
                      (ignore-errors (pdf-info-close file))
                      (prog1 (cl-count-if (lambda (a) (memq (cdr (assq 'type a))
                                                            '(highlight underline)))
                                          (pdf-info-getannots nil file))
                        (ignore-errors (pdf-info-close file))))))
      (should (= (readq-import-highlights book) 3))
      (should (= (funcall markups) 3))
      (let ((red (cl-find "The first heart sound is caused by closure of the AV valves."
                          (readq--extracts-of book t)
                          :key (lambda (x) (readq--get x :snippet)) :test #'equal)))
        (readq-dtest--yes (readq-delete-extract red))
        ;; The highlight is gone from the PDF file itself (as Okular sees it).
        (should (= (funcall markups) 2))
        (should-not (readq-dtest--org-has red))
        (should (= (length (readq--extracts-of book t)) 2))
        ;; Nothing comes back on the next import...
        (should (= (readq-import-highlights book) 0))
        ;; ...and the spot is not blocked: a new highlight there would be imported.
        (should-not (readq--known-highlight-p book 2 (readq--get red :edges) nil))))))

(ert-deftest readq-dtest-pdf-buffer ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "book.pdf") 30))
           (here '((0.1 0.1 0.5 0.2)))
           (x (readq--create-extract book "On page 2." :page 2 :edges here))
           (other (readq--create-extract book "On page 3." :page 3 :edges '((0.1 0.5 0.5 0.6))))
           deleted saved)
      (with-temp-buffer
        (pdf-view-mode)
        (setq readq--book-id (readq--get book :id))
        (cl-letf (((symbol-function 'image-mode-window-get) (lambda (&rest _) 2))
                  ((symbol-function 'readq--pdf-info-available-p) (lambda () t))
                  ((symbol-function 'readq--pdf-buffer-visiting) (lambda (_) (current-buffer)))
                  ((symbol-function 'require) (lambda (&rest _) t))
                  ((symbol-function 'pdf-annot-getannots)
                   (lambda (page &rest _)
                     (list `((page . ,page) (type . highlight) (id . match)
                             (markup-edges . ((0.1 0.1 0.5 0.2))))
                           `((page . ,page) (type . highlight) (id . elsewhere)
                             (markup-edges . ((0.1 0.8 0.5 0.9))))
                           `((page . ,page) (type . text) (id . note)
                             (edges . (0.1 0.1 0.5 0.2))))))
                  ((symbol-function 'pdf-annot-delete)
                   (lambda (a) (push (cdr (assq 'id a)) deleted)))
                  ((symbol-function 'save-buffer) (lambda (&rest _) (setq saved t))))
          ;; On page 2 the extract of page 2 is the one.
          (should (eq (readq--extract-to-delete) x))
          (readq-dtest--yes (readq-delete-extract x))
          ;; Only the matching highlight went, and the PDF was saved.
          (should (equal deleted '(match)))
          (should saved))
        (setq readq--book-id nil))
      (should-not (memq x (readq--books)))
      (should (memq other (readq--books))))))

(provide 'readq-delete-test)
;;; readq-delete-test.el ends here
