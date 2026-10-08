;;; readq-multi-region-test.el --- readq with multi-region -*- lexical-binding: t; -*-

;; Run with multi-region on the load path:
;;   emacs -Q --batch -L . -L test -L /path/to/multi-region \
;;     -l test/readq-multi-region-test.el -f ert-run-tests-batch-and-exit
;;
;; Tests are skipped without multi-region (0.2 or later); the EPUB test
;; also needs nov.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'multi-region nil t)

(defun readq-mtest--available-p ()
  "Return non-nil when multi-region with `multi-region-selections' is loaded."
  (fboundp 'multi-region-selections))

(defconst readq-mtest--org
  "* Heart
Systole is contraction. Diastole is relaxation. The first heart sound is S1.
")

(defun readq-mtest--select (&rest regexps)
  "Add a multi-region selection for the first match of each of REGEXPS."
  (dolist (re regexps)
    (goto-char (point-min))
    (re-search-forward re)
    (multi-region--add (match-beginning 0) (match-end 0))))

(defun readq-mtest--overlay-texts ()
  "Return the texts readq highlights as extracted in this buffer."
  (sort (mapcar (lambda (o) (buffer-substring-no-properties (overlay-start o) (overlay-end o)))
                (cl-remove-if-not (lambda (o) (overlay-get o 'readq-extract))
                                  (overlays-in (point-min) (point-max))))
        #'string<))

(defmacro readq-mtest--with-org-book (&rest body)
  "Run BODY in an Org book buffer with `multi-region-mode' on."
  (declare (indent 0))
  `(readq-ftest--with-db
     (let ((book (readq-add-book (readq-ftest--write "lib/heart.org" readq-mtest--org)
                                 20 "Heart")))
       (readq-open book)
       (multi-region-mode 1)
       ,@body)))

;;;; Text books

(ert-deftest readq-mtest-combine-by-default ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (readq-mtest--select "The first heart sound is S1\\." "Systole is contraction\\.")
    (let ((x (readq-extract)))
      (should (readq--extract-p x))
      ;; In reading order, as separate paragraphs.
      (should (equal (readq--get x :snippet)
                     "Systole is contraction.\n\nThe first heart sound is S1."))
      (should (equal (readq--get x :title)
                     "Systole is contraction. The first heart sound is S1."))
      (should (= (length (readq--get x :parts)) 2))
      (should (string-match-p "#\\+begin_quote\nSystole is contraction\\.\n\nThe first heart sound is S1\\.\n#\\+end_quote"
                              (readq-xtest--org-text x)))
      ;; Selections are gone; each passage is highlighted on its own.
      (should-not (multi-region-selections))
      (should (equal (readq-mtest--overlay-texts)
                     '("Systole is contraction." "The first heart sound is S1."))))))

(ert-deftest readq-mtest-separate-with-two-prefixes ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (readq-mtest--select "Systole is contraction\\." "Diastole is relaxation\\.")
    (let ((xs (readq-extract '(16))))
      (should (= (length xs) 2))
      (should (equal (mapcar (lambda (x) (readq--get x :snippet)) xs)
                     '("Systole is contraction." "Diastole is relaxation.")))
      (should-not (readq--get (car xs) :parts)))))

(ert-deftest readq-mtest-separate-as-default ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (let ((readq-extract-multiple 'separate))
      (readq-mtest--select "Systole is contraction\\." "Diastole is relaxation\\.")
      (should (= (length (readq-extract)) 2))
      (readq-mtest--select "Systole is contraction\\." "Diastole is relaxation\\.")
      ;; Two prefixes: the other way, combined.
      (should (readq--extract-p (readq-extract '(16)))))))

(ert-deftest readq-mtest-ask-priority-once ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (let ((asked 0)
          (readq-extract-multiple 'separate))
      (readq-mtest--select "Systole is contraction\\." "Diastole is relaxation\\.")
      (cl-letf (((symbol-function 'read-number)
                 (lambda (&rest _) (setq asked (1+ asked)) 7)))
        (let ((xs (readq-extract '(4))))
          (should (= asked 1))
          (should (equal (mapcar (lambda (x) (readq--get x :priority)) xs) '(7 7))))))))

(ert-deftest readq-mtest-region-plus-selections ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (readq-mtest--select "Systole is contraction\\.")
    ;; An active region counts as one more selection.
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (re-search-forward "Diastole is relaxation\\.")
      (set-mark (match-beginning 0))
      (activate-mark)
      (let ((x (readq-extract)))
        (should (equal (readq--get x :snippet)
                       "Systole is contraction.\n\nDiastole is relaxation."))))))

(ert-deftest readq-mtest-without-selections ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    ;; A plain region still works, and nothing selected is still an error.
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (re-search-forward "Diastole is relaxation\\.")
      (set-mark (match-beginning 0))
      (activate-mark)
      (should (equal (readq--get (readq-extract) :snippet) "Diastole is relaxation.")))
    (should-error (readq-extract) :type 'user-error)))

(ert-deftest readq-mtest-sub-extract-combined ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (let* ((book (readq--buffer-book))
           (x (readq--create-extract book "Alpha beta gamma. Delta epsilon zeta." :point 3)))
      (readq--put x :due (readq--today))
      (should (readq-open x))
      (multi-region-mode 1)
      (readq-mtest--select "Alpha beta" "epsilon zeta")
      (let ((sub (readq-extract)))
        (should (equal (readq--get sub :parent) (readq--get x :id)))
        (should (equal (readq--get sub :snippet) "Alpha beta\n\nepsilon zeta"))))))

(ert-deftest readq-mtest-remove-remembers-all-parts ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-org-book
    (let* ((book (readq--buffer-book))
           (x (readq--create-extract
               book "a\n\nb" :page 2
               :parts '((:page 2 :edges ((0.1 0.1 0.5 0.2)) :key "k1")
                        (:page 5 :edges ((0.1 0.6 0.5 0.7)) :key "k2")))))
      (should (readq--known-highlight-p book 5 '((0.1 0.6 0.5 0.7)) nil))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (readq-remove-book x))
      ;; Both passages stay known, so their highlights are not imported.
      (should (readq--known-highlight-p book 2 '((0.1 0.1 0.5 0.2)) nil))
      (should (readq--known-highlight-p book 5 nil "k2")))))

;;;; EPUB, across chapters (real nov.el)

(ert-deftest readq-mtest-epub-across-chapters ()
  (skip-unless (and (readq-mtest--available-p) (require 'nov nil t)
                    (executable-find "zip")))
  (readq-xtest--with-db
    (let* ((nov-save-place-file nil)
           (f (expand-file-name "test.epub" readq-test--dir))
           (filler (mapconcat #'identity (make-list 40 "lorem ipsum") " ")))
      (readq-test--make-epub
       f (list (concat filler " The aorta carries blood. " filler)
               (concat filler " The vena cava returns blood. " filler)))
      (let ((book (readq-add-book f 15))
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist)))
        (readq-mode 1)
        (readq-open book)
        (multi-region-mode 1)
        (nov-goto-document 1)
        (readq-mtest--select "The[ \n]+aorta[ \n]+carries[ \n]+blood\\.")
        (nov-goto-document 2)
        (readq-mtest--select "The[ \n]+vena[ \n]+cava[ \n]+returns[ \n]+blood\\.")
        (let ((x (readq-extract)))
          (should (equal (readq--get x :snippet)
                         "The aorta carries blood.\n\nThe vena cava returns blood."))
          (should (= (readq--get x :page) 1))
          (should (equal (mapcar (lambda (p) (plist-get p :page)) (readq--get x :parts))
                         '(1 2)))
          ;; Each chapter highlights its own passage.
          (should (equal (mapcar #'readq--unfill (readq-mtest--overlay-texts))
                         '("The vena cava returns blood.")))
          (nov-goto-document 1)
          (should (equal (mapcar #'readq--unfill (readq-mtest--overlay-texts))
                         '("The aorta carries blood."))))
        (kill-buffer (current-buffer))))))

;;;; PDF (pdf-tools imitated), across pages

(defvar readq-mtest--annotations nil)

(defmacro readq-mtest--with-pdf (&rest body)
  "Run BODY in an imitation pdf-tools buffer of a queued book.
pdf-tools is imitated in its current form, where the region is
\(PAGE . EDGES)."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((book (readq-add-book (readq-test--touch "book.pdf") 30 "Book"))
           (readq-mtest--annotations nil)
           (page 1))
       (with-temp-buffer
         (pdf-view-mode)
         (setq readq--book-id (readq--get book :id))
         (defvar pdf-view-active-region)
         (setq-local pdf-view-active-region nil)
         (cl-letf (((symbol-function 'image-mode-window-get) (lambda (&rest _) page))
                   ((symbol-function 'pdf-info-gettext)
                    (lambda (pg edges &rest _) (format "Text %d at %s." pg (nth 1 edges))))
                   ((symbol-function 'pdf-view-active-region-p)
                    (lambda () (and pdf-view-active-region t)))
                   ((symbol-function 'pdf-view-active-region)
                    (lambda (&rest _) pdf-view-active-region))
                   ((symbol-function 'pdf-view-active-region-text)
                    (lambda () (mapcar (lambda (e) (format "Text %d at %s."
                                                           (car pdf-view-active-region)
                                                           (nth 1 e)))
                                       (cdr pdf-view-active-region))))
                   ((symbol-function 'pdf-view-deactivate-region)
                    (lambda () (setq pdf-view-active-region nil)))
                   ((symbol-function 'pdf-view-display-region) #'ignore)
                   ((symbol-function 'pdf-annot-add-markup-annotation)
                    (lambda (region type color)
                      (push (list region type color) readq-mtest--annotations)
                      `((markup-edges . ,(mapcar (lambda (e) (mapcar (lambda (n) (+ n 0.001)) e))
                                                 (cdr region))))))
                   ((symbol-function 'save-buffer) #'ignore))
           ,@body)
         (setq readq--book-id nil)))))

(ert-deftest readq-mtest-pdf-across-pages ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-pdf
    (multi-region-mode 1)
    (setq pdf-view-active-region '(1 (0.1 0.1 0.5 0.2) (0.1 0.5 0.5 0.6)))
    ;; Turn to page 4 and select there too.
    (multi-region--pdf-save)
    (setq pdf-view-active-region nil page 4)
    (setq pdf-view-active-region '(4 (0.2 0.3 0.6 0.4)))
    (let ((x (readq-extract)))
      (should (equal (readq--get x :snippet)
                     "Text 1 at 0.1.\n\nText 1 at 0.5.\n\nText 4 at 0.3."))
      (should (= (readq--get x :page) 1))
      ;; Each passage was highlighted on its own page.
      (should (equal (sort (mapcar (lambda (a) (car (car a))) readq-mtest--annotations) #'<)
                     '(1 1 4)))
      ;; The highlights' edges are kept, so importing them adds nothing.
      (should (equal (mapcar (lambda (p) (plist-get p :page)) (readq--get x :parts))
                     '(1 1 4)))
      (let ((book (readq--book-by-id (readq--get x :book))))
        (should (readq--known-highlight-p book 4 '((0.201 0.301 0.601 0.401)) nil))
        (should (readq--known-highlight-p book 1 '((0.101 0.501 0.501 0.601)) nil)))
      (should-not pdf-view-active-region)
      (should (= (multi-region--count) 0)))))

(ert-deftest readq-mtest-pdf-tools-c-drag-without-multi-region ()
  (skip-unless (readq-mtest--available-p))
  (readq-mtest--with-pdf
    ;; pdf-tools alone: drag, then C-drag, on one page.
    (setq pdf-view-active-region '(2 (0.1 0.1 0.5 0.2) (0.1 0.7 0.5 0.8)))
    (let ((x (readq-extract)))
      (should (equal (readq--get x :snippet) "Text 2 at 0.1.\n\nText 2 at 0.7."))
      (should (= (length readq-mtest--annotations) 2)))
    (setq pdf-view-active-region '(2 (0.1 0.1 0.5 0.2) (0.1 0.7 0.5 0.8)))
    (should (= (length (readq-extract '(16))) 2))))

(provide 'readq-multi-region-test)
;;; readq-multi-region-test.el ends here
