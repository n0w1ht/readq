;;; readq-extract-test.el --- Tests for readq extracts -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-extract-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Highlight import tests need pdf-tools: put its lisp directory on the
;; load path and set READQ_EPDFINFO to the epdfinfo program.  EPUB tests
;; need nov.el on the load path.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)

(defconst readq-xtest--fixtures
  (expand-file-name "fixtures" (file-name-directory
                                (or load-file-name buffer-file-name))))

(defmacro readq-xtest--with-db (&rest body)
  "Run BODY with an empty database and extracts directory."
  (declare (indent 0))
  `(readq-test--with-db
     (let ((readq-extracts-directory (expand-file-name "extracts" readq-test--dir))
           (readq-auto-import-highlights nil))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b)
                      (string-prefix-p readq-test--dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))))))

(defun readq-xtest--pdf-tools-p ()
  "Set up pdf-tools if available and return non-nil."
  (let ((server (getenv "READQ_EPDFINFO")))
    (and server (file-executable-p server)
         (require 'pdf-info nil t)
         (progn (setq pdf-info-epdfinfo-program server)
                (readq--pdf-info-available-p)))))

(defun readq-xtest--copy-fixture (name &optional as)
  "Copy fixture NAME into the test directory (as AS) and return its path."
  (let ((dest (expand-file-name (or as name) readq-test--dir)))
    (copy-file (expand-file-name name readq-xtest--fixtures) dest t)
    dest))

(defun readq-xtest--org-text (item)
  "Return the contents of the Org file of extract ITEM."
  (with-temp-buffer
    (insert-file-contents (readq--get item :file))
    (buffer-string)))

(defun readq-xtest--extracts (book)
  "Return BOOK's extracts sorted by page."
  (sort (copy-sequence (readq--extracts-of book t))
        (lambda (a b) (< (readq--get a :page) (readq--get b :page)))))

;;;; Helpers

(ert-deftest readq-xtest-clean-text ()
  (should (equal (readq--clean-text "contrac-\ntion of the\n  ventricles ")
                 "contraction of the ventricles"))
  (should (equal (readq--clean-text "well-\nKnown") "well- Known"))
  (should (equal (readq--text-key "Systole, is  the\nphase!")
                 (readq--text-key "systole is the phase")))
  (should-not (readq--text-key " .,; ")))

(ert-deftest readq-xtest-colors ()
  (should (equal (readq--color-name "#ffff00") "yellow"))
  (should (equal (readq--color-name "#ff0000") "red"))
  (should (equal (readq--color-name "#00ff00") "green"))
  (should (equal (readq--color-name "#3399ff") "blue"))
  (should (equal (readq--color-name "#ffa500") "orange"))
  (should (equal (readq--color-name "#ff00ff") "purple"))
  (should (equal (readq--color-name "#ffffffff0000") "yellow"))
  (should (equal (readq--color-name "#808080") "gray"))
  (should-not (readq--color-name nil))
  (let ((readq-highlight-color-rules '(("red" . 5) ("green" . skip) (t . 70))))
    (should (= (readq--color-action "#ff0000") 5))
    (should (eq (readq--color-action "#00ff00") 'skip))
    (should (= (readq--color-action "#ffff00") 70))))

(ert-deftest readq-xtest-edges-overlap ()
  ;; One big selection rectangle versus the two per-line highlight boxes.
  (should (> (readq--edges-overlap '((0.1 0.1 0.6 0.2))
                                   '((0.1 0.1 0.6 0.15) (0.1 0.15 0.4 0.2)))
             0.9))
  (should (= (readq--edges-overlap '((0.1 0.1 0.6 0.2)) '((0.1 0.5 0.6 0.6))) 0))
  (should (= (readq--edges-overlap nil '((0 0 1 1))) 0)))

(ert-deftest readq-xtest-unfill ()
  (should (equal (readq--unfill "  one\ntwo  three\n\n\nfour\n five\n")
                 "one two three\n\nfour five")))

(ert-deftest readq-xtest-org-escape ()
  (let ((text "* not a heading\n#+begin_src\nplain"))
    (should (equal (readq--org-escape text) ",* not a heading\n,#+begin_src\nplain"))
    (should (equal (readq--org-unescape
                    (concat "#+begin_quote\n" (readq--org-escape text) "\n#+end_quote\n"))
                   text))))

;;;; Creating and reviewing extracts

(ert-deftest readq-xtest-create-and-review ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "gray.pdf") 20 "Gray's Anatomy"))
           (x (readq--create-extract book "* Systole is the phase of contraction."
                                     :page 57 :comment "Key definition"))
           (id (readq--get x :id)))
      (should (readq--extract-p x))
      (should (= (readq--get x :priority) 20))
      (should (equal (readq--get x :due) (readq--date-in 1)))
      ;; A note of its own, named as Denote names notes.
      (should (string-match-p "\\`[0-9]\\{8\\}T[0-9]\\{6\\}\\'" id))
      (should (equal (file-name-nondirectory (readq--get x :file))
                     (concat id "==gray=s=anatomy=p0057--systole-is-the-phase-of-contraction"
                             "__extract.org")))
      (should (equal (file-name-directory (expand-file-name (readq--get x :file)))
                     (file-name-as-directory (expand-file-name readq-extracts-directory))))
      (should (string-match-p
               (concat "\\`#\\+title:      \\* Systole is the phase of contraction\\.\n"
                       "#\\+date:       \\[[0-9-]+ [A-Za-z]+ [0-9:]+\\]\n"
                       "#\\+filetags:   :extract:\n"
                       "#\\+identifier: " id "\n"
                       "#\\+signature:  gray=s=anatomy=p0057\n"
                       "#\\+source:     \\[\\[readq:" id "\\]\\[Gray's Anatomy, p\\. 57\\]\\]\n"
                       "\n"
                       "#\\+begin_quote\n,\\* Systole is the phase of contraction\\.\n#\\+end_quote\n"
                       "Note: Key definition\n\\'")
               (readq-xtest--org-text x)))
      ;; No property drawer anywhere.
      (should-not (string-match-p ":PROPERTIES:" (readq-xtest--org-text x)))
      ;; Not due yet, so the book comes first; then make the extract due.
      (should (eq (car (readq--queue)) book))
      (readq--put x :due (readq--today) :priority 5)
      (should (eq (car (readq--queue)) x))
      ;; Review it.
      (should (readq-open x))
      (should readq-review-mode)
      (should (eq (readq--extract-at-point) x))
      (should (looking-at "#\\+begin_quote"))
      (should (eq (readq--target-book) x))
      ;; A sub-extract from part of the text: a note of its own.
      (goto-char (point-min))
      (search-forward "#+begin_quote")
      (search-forward "Systole")
      (set-mark (match-beginning 0))
      (search-forward "phase")
      (activate-mark)
      (let ((transient-mark-mode t))
        (let ((sub (readq-extract)))
          (should (equal (readq--get sub :parent) id))
          (should (equal (readq--get sub :book) (readq--get book :id)))
          (should (= (readq--get sub :page) 57))
          (should (equal (readq--get sub :title) "Systole is the phase"))
          (should-not (equal (readq--get sub :id) id))
          (should-not (equal (readq--get sub :file) (readq--get x :file)))
          (should (string-match-p
                   (concat "^#\\+parent:     \\[\\[denote:" id "\\]\\[")
                   (readq-xtest--org-text sub)))))
      ;; Renaming the note is picked up when the review ends: the file
      ;; follows its title.
      (goto-char (point-min))
      (re-search-forward "^#\\+title: +\\(.*\\)$")
      (replace-match "Systole" t t nil 1)
      (let ((finished (readq-finish-session)))
        (should (eq finished x)))
      (should-not readq-review-mode)
      (should (equal (readq--get x :title) "Systole"))
      (should (equal (file-name-nondirectory (readq--get x :file))
                     (concat id "==gray=s=anatomy=p0057--systole__extract.org")))
      (should (file-exists-p (readq--get x :file)))
      (should (equal (expand-file-name (readq--get x :file)) (buffer-file-name)))
      (should (= (readq--get x :sessions) 1))
      (should-not (readq--due-p x)))))

(ert-deftest readq-xtest-next-and-dismiss ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "b.epub") 50))
           (x1 (readq--create-extract book "first passage" :page 1 :priority 10))
           (x2 (readq--create-extract book "second passage" :page 2 :priority 20)))
      (readq--put x1 :due (readq--today))
      (readq--put x2 :due (readq--today))
      (readq-next)
      (should (eq (readq--extract-at-point) x1))
      (readq-next)                      ; reviews x1, opens x2
      (should (eq (readq--extract-at-point) x2))
      (should (= (readq--get x1 :sessions) 1))
      (cl-letf (((symbol-function 'readq-open) (lambda (_) t)))
        (readq-dismiss x2))
      (should (eq (readq--get x2 :status) 'finished))
      (should (= (readq--get x2 :sessions) 0))
      (should-not (memq x2 (readq--queue))))))

(ert-deftest readq-xtest-kill-review-buffer ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "k.epub") 50))
           (x (readq--create-extract book "a passage" :page 1)))
      (readq--put x :due (readq--today))
      ;; A glance, then killing the buffer: time is kept, no reschedule.
      (readq-open x)
      (setq readq--session-seconds 5)
      (kill-buffer (current-buffer))
      (should (= (readq--get x :sessions) 0))
      (should (= (readq--get x :seconds) 5))
      (should (readq--due-p x))
      ;; A real review, then killing the buffer: rescheduled.
      (readq-open x)
      (setq readq--session-seconds readq-min-session-seconds)
      (kill-buffer (current-buffer))
      (should (= (readq--get x :sessions) 1))
      (should-not (readq--due-p x))
      ;; Edits count, but a discarded edit is not saved.
      (readq--put x :due (readq--today))
      (readq-open x)
      (goto-char (point-max))
      (insert "unsaved")
      (kill-buffer (current-buffer))
      (should (= (readq--get x :sessions) 2))
      (should-not (string-match-p "unsaved" (readq-xtest--org-text x)))
      ;; Quitting Emacs finishes the review too.
      (readq--put x :due (readq--today))
      (readq-open x)
      (setq readq--session-seconds readq-min-session-seconds)
      (readq--save-all)
      (should-not readq-review-mode)
      (should (= (readq--get x :sessions) 3))
      ;; The database on disk has the update.
      (setq readq--books nil readq--loaded nil)
      (should (= (readq--get (readq--book-by-id (readq--get x :id)) :sessions) 3)))))

(ert-deftest readq-xtest-deleted-heading ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "b.pdf") 50))
           (x (readq--create-extract book "gone soon" :page 3 :edges '((0 0 1 0.1)))))
      (delete-file (readq--get x :file))
      (should-not (readq-open x))
      (should-not (memq x (readq--books)))
      ;; Remembered, so the same highlight is not imported again.
      (should (readq--known-highlight-p book 3 '((0 0 1 0.1)) nil)))))

(ert-deftest readq-xtest-remove-extract ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "b.pdf") 50))
           (x (readq--create-extract book "remove me" :page 1))
           (sub (readq--create-extract x "remove" :page 1))
           (keep (readq--create-extract book "keep me" :page 2))
           (file (expand-file-name (readq--get x :file)))
           (sub-file (expand-file-name (readq--get sub :file))))
      (find-file-noselect file)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (readq-remove-book x))
      (should-not (memq x (readq--books)))
      (should-not (memq sub (readq--books)))
      ;; Its note and its sub-extract's are gone, the others stay.
      (should-not (file-exists-p file))
      (should-not (file-exists-p sub-file))
      (should-not (find-buffer-visiting file))
      (should (file-exists-p (readq--get keep :file))))))

(ert-deftest readq-xtest-dashboard ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "a.pdf") 50 "Alpha")))
      (readq--create-extract book "an extracted sentence" :page 4)
      (readq)
      ;; The extract is under its book, which is folded.
      (should-not (string-match-p "an extracted sentence" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Alpha")
      (should (string-match-p "pdf +▸ Alpha .* 1 " (buffer-substring (line-beginning-position)
                                                                 (line-end-position))))
      (readq-dashboard-toggle-fold)
      (should (string-match-p "extract +  an extracted sentence" (buffer-string)))
      ;; E hides extracts altogether.
      (readq-dashboard-toggle-extracts)
      (should-not (string-match-p "an extracted sentence" (buffer-string)))
      (kill-buffer "*readq*"))))

;;;; Where extracts files go

(ert-deftest readq-xtest-notes-in-one-flat-folder ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Gray's Anatomy.pdf") 20 "Gray"))
           (other (readq-add-book (readq-test--touch "other/Guyton.epub") 20 "Guyton"))
           (x (readq--create-extract book "a passage" :page 1))
           (y (readq--create-extract book "another" :page 2))
           (z (readq--create-extract other "a third" :page 0))
           (dir (file-name-as-directory (expand-file-name readq-extracts-directory))))
      ;; Every extract is a file of its own, all in the same folder.
      (dolist (e (list x y z))
        (should (equal (file-name-directory (expand-file-name (readq--get e :file))) dir)))
      (should (= (length (directory-files dir nil "\\.org\\'")) 3))
      ;; Made in the same second, they still get identifiers of their own.
      (should (= (length (delete-dups (mapcar (lambda (e) (readq--get e :id)) (list x y z))))
                 3))
      (should (string-match-p "==guyton=ch001--a-third__extract\\.org\\'" (readq--get z :file))))))

(ert-deftest readq-xtest-renamed-in-denote ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "gray.pdf") 20 "Gray"))
           (x (readq--create-extract book "a passage" :page 1))
           (id (readq--get x :id))
           (old (expand-file-name (readq--get x :file)))
           (new (expand-file-name (concat id "==gray=p0001--my-own-title__extract_exam.org")
                                  readq-extracts-directory)))
      (readq--put x :due (readq--today))
      ;; Renamed outside readq, with a keyword added: found by its identifier.
      (rename-file old new)
      (should-not (readq--missing-p x))
      (should (equal (expand-file-name (readq--get x :file)) new))
      (should (memq x (readq--queue)))
      (should (readq-open x))
      (should (eq (readq--extract-at-point) x))
      ;; readq renames it after its title again, but keeps your keyword.
      (readq-finish-session)
      (should (equal (file-name-nondirectory (readq--get x :file))
                     (concat id "==gray=p0001--a-passage__exam_extract.org")))
      (should (string-match-p "^#\\+filetags:   :exam:extract:$" (readq-xtest--org-text x))))))

(ert-deftest readq-xtest-extracts-directory-option ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory (expand-file-name "all-extracts/" readq-test--dir))
           (book (readq-add-book (readq-test--touch "lib/b.pdf") 20 "My Book"))
           (x (readq--create-extract book "t" :page 1)))
      (should (equal (file-name-directory (expand-file-name (readq--get x :file)))
                     (expand-file-name "all-extracts/" readq-test--dir))))
    ;; nil: Denote's own folder, when Denote is there.
    (let ((readq-extracts-directory nil))
      (defvar denote-directory)
      (unless (boundp 'denote-directory)
        (should (equal (readq--notes-directory) (expand-file-name "~/notes/"))))
      (let ((denote-directory (expand-file-name "denote" readq-test--dir)))
        (should (equal (readq--notes-directory)
                       (expand-file-name "denote/" readq-test--dir)))))))

(ert-deftest readq-xtest-extracts-directory-default ()
  ;; By default, all notes go to ~/notes/, made when needed; a note of
  ;; yours there is never written into.
  (should (equal (eval (car (get 'readq-extracts-directory 'standard-value))) "~/notes/"))
  (readq-xtest--with-db
    (let* ((notes (expand-file-name "home/notes/" readq-test--dir))
           (readq-extracts-directory notes)
           (book (readq-add-book (readq-test--touch "lib/gray.pdf") 20 "Gray's Anatomy")))
      (should-not (file-exists-p notes))
      (make-directory notes t)
      (with-temp-file (expand-file-name "gray-s-anatomy.org" notes) (insert "* Mine\n"))
      (let ((x (readq--create-extract book "t" :page 1)))
        (should (file-exists-p (readq--get x :file)))
        (with-temp-buffer
          (insert-file-contents (expand-file-name "gray-s-anatomy.org" notes))
          (should (equal (buffer-string) "* Mine\n")))))))

(ert-deftest readq-xtest-tags-and-titles-rename-notes ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "gray.pdf") 20 "Gray"))
           (x (readq--create-extract book "a passage" :page 1 :tags '("heart")))
           (id (readq--get x :id)))
      (should (string-suffix-p "==gray=p0001--a-passage__extract_heart.org" (readq--get x :file)))
      ;; The book's tags are its extracts' keywords too.
      (readq-set-tags book '("Cardio" "year-1"))
      (should (equal (file-name-nondirectory (readq--get x :file))
                     (concat id "==gray=p0001--a-passage__cardio_extract_heart_year1.org")))
      (should (string-match-p "^#\\+filetags:   :cardio:extract:heart:year1:$"
                              (readq-xtest--org-text x)))
      (readq-set-tags x nil)
      (should (string-suffix-p "__cardio_extract_year1.org" (readq--get x :file)))
      ;; Renaming the book changes the signature, renaming the extract the title.
      (readq-edit-title book "Gray's Anatomy")
      (should (string-match-p "==gray=s=anatomy=p0001--a-passage__" (readq--get x :file)))
      (should (string-match-p "^#\\+signature:  gray=s=anatomy=p0001$" (readq-xtest--org-text x)))
      (should (string-match-p "\\[Gray's Anatomy, p\\. 1\\]\\]$" (readq-xtest--org-text x)))
      (readq-edit-title x "Valves")
      (should (string-match-p "--valves__" (readq--get x :file)))
      (should (string-match-p "^#\\+title:      Valves$" (readq-xtest--org-text x)))
      (should (file-exists-p (readq--get x :file)))
      (should (= (length (directory-files readq-extracts-directory nil "\\.org\\'")) 1)))))

(ert-deftest readq-xtest-relocate-keeps-notes ()
  (readq-xtest--with-db
    (let* ((old (readq-test--touch "old/b.pdf"))
           (book (readq-add-book old 20))
           (x (readq--create-extract book "kept passage" :page 1))
           (file (readq--get x :file))
           (new (expand-file-name "new/b.pdf" readq-test--dir)))
      ;; The book moved: its notes stay where they are.
      (make-directory (file-name-directory new) t)
      (rename-file old new)
      (readq-relocate book new)
      (should (equal (readq--get x :file) file))
      (should (readq-open x))
      (should (string-match-p "kept passage" (buffer-string)))
      (readq--end-review))))

;;;; PDF: extracting in pdf-tools (mocked) and importing highlights (real)

(defconst readq-xtest--yellow-edges
  '((0.121008 0.123515 0.579832 0.142518) (0.121008 0.142518 0.408403 0.162708))
  "The two boxes of the yellow highlight on page 2 of highlighted.pdf.")

(ert-deftest readq-xtest-extract-from-pdf-tools ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "book.pdf") 30))
           annotated saved)
      (with-temp-buffer
        (pdf-view-mode)
        (setq readq--book-id (readq--get book :id))
        (cl-letf (((symbol-function 'pdf-view-active-region-p) (lambda () t))
                  ((symbol-function 'pdf-view-active-region)
                   (lambda (&rest _) '(2 . ((0.12 0.12 0.58 0.163)))))
                  ((symbol-function 'pdf-view-active-region-text)
                   (lambda () '("Systole is the phase of contrac-\ntion of the ventricles,")))
                  ((symbol-function 'pdf-view-deactivate-region) #'ignore)
                  ((symbol-function 'pdf-annot-add-markup-annotation)
                   (lambda (region type color)
                     (setq annotated (list region type color))
                     `((markup-edges . ,readq-xtest--yellow-edges))))
                  ((symbol-function 'save-buffer) (lambda (&rest _) (setq saved t))))
          (let ((x (readq-extract)))
            (should (equal annotated '((2 . ((0.12 0.12 0.58 0.163))) highlight "#ffff00")))
            (should saved)
            (should (= (readq--get x :page) 2))
            (should (equal (readq--get x :edges) readq-xtest--yellow-edges))
            (should (equal (readq--get x :title)
                           "Systole is the phase of contraction of the ventricles,"))
            (should (= (readq--get x :priority) 30))))
        (setq readq--book-id nil)))))

(ert-deftest readq-xtest-import-highlights ()
  (skip-unless (readq-xtest--pdf-tools-p))
  (readq-xtest--with-db
    (let* ((file (readq-xtest--copy-fixture "highlighted.pdf" "heart.pdf"))
           (book (readq-add-book file 40 "Heart")))
      (should (= (readq-import-highlights book) 3))
      (let ((xs (readq-xtest--extracts book)))
        ;; Sticky notes are not imported; text under each box is exact.
        (should (equal (mapcar (lambda (x) (readq--get x :snippet)) xs)
                       '("Systole is the phase of contraction of the ventricles, which ejects blood into the aorta"
                         "The first heart sound is caused by closure of the AV valves."
                         "The left coronary artery arises from the left aortic sinus.")))
        (should (equal (mapcar (lambda (x) (readq--get x :page)) xs) '(2 2 3)))
        (should (cl-every (lambda (x) (= (readq--get x :priority) 40)) xs))
        (should (string-match-p "^Note: Key definition" (readq-xtest--org-text (car xs)))))
      ;; Importing again adds nothing.
      (should (= (readq-import-highlights book) 0))
      (should-not (readq--highlights-stale-p book))
      ;; Simulate Okular saving one more highlight into the file.
      (copy-file (expand-file-name "highlighted-more.pdf" readq-xtest--fixtures) file t)
      (set-file-times file (time-add (current-time) 10))
      (should (readq--highlights-stale-p book))
      (let ((readq-auto-import-highlights t))
        (run-hooks 'readq-before-suggest-hook))
      (let ((xs (readq-xtest--extracts book)))
        (should (= (length xs) 4))
        (should (cl-some (lambda (x) (equal (readq--get x :snippet)
                                            "It divides into the anterior interventricular and circumflex branches."))
                         xs)))
      (should-not (readq--highlights-stale-p book)))))

(ert-deftest readq-xtest-import-color-rules-and-dedupe ()
  (skip-unless (readq-xtest--pdf-tools-p))
  (readq-xtest--with-db
    (let* ((file (readq-xtest--copy-fixture "highlighted.pdf" "heart.pdf"))
           (book (readq-add-book file 40 "Heart"))
           (readq-highlight-color-rules '(("red" . 5) ("green" . skip))))
      ;; An extract made earlier in pdf-tools on the yellow highlight.
      (readq--create-extract book "Systole is the phase of contrac- tion"
                             :page 2 :edges readq-xtest--yellow-edges)
      (should (= (readq-import-highlights book) 1))
      (let ((xs (readq-xtest--extracts book)))
        (should (= (length xs) 2))
        (should (= (readq--get (cadr xs) :priority) 5))
        (should (equal (readq--get (cadr xs) :color) "#ff0000"))
        ;; Removing an imported extract keeps it from coming back.
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (readq-remove-book (cadr xs))))
      (readq--put book :annots-mtime nil)
      (should (= (readq-import-highlights book) 0)))))

(ert-deftest readq-xtest-native-file-name ()
  (let ((system-type 'windows-nt))
    (should (equal (readq--native-file-name "/Books/A B.pdf") "\\Books\\A B.pdf"))))

(ert-deftest readq-xtest-windows-file-case ()
  (let ((system-type 'windows-nt))
    (should (readq--same-file-p "c:/Books/Gray.pdf" "C:/books/gray.PDF")))
  (let ((system-type 'gnu/linux))
    (should-not (readq--same-file-p "/b/Gray.pdf" "/b/gray.pdf"))))

;;;; Org links

(ert-deftest readq-xtest-org-links ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "a.pdf") 50))
           (x (readq--create-extract book "text" :page 9))
           visited)
      (cl-letf (((symbol-function 'readq--visit-location)
                 (lambda (&rest args) (setq visited args))))
        (readq--org-follow (format "%s::p12" (readq--get book :id)))
        (should (equal visited (list book 12)))
        (readq--org-follow (format "%s::c3:120" (readq--get book :id)))
        (should (equal visited (list book 3 120)))
        (readq--org-follow (readq--get x :id))
        (should (equal visited (list book 9 nil "text"))))
      (should-error (readq--org-follow "nope") :type 'user-error))))

;;;; EPUB with the real nov.el

(ert-deftest readq-xtest-nov-extract-and-source ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-xtest--with-db
    (let* ((nov-save-place-file nil)
           (f (expand-file-name "test.epub" readq-test--dir))
           (para (mapconcat #'identity (make-list 120 "lorem ipsum dolor") " ")))
      (readq-test--make-epub
       f (list para (concat para " The mitral valve has two cusps. " para) para))
      (let ((book (readq-add-book f 15))
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist))
            (transient-mark-mode t))
        (readq-open book)
        (nov-goto-document 2)
        (goto-char (point-min))
        (re-search-forward "The[ \n]+mitral[ \n]+valve[ \n]+has[ \n]+two[ \n]+cusps\\.")
        (set-mark (match-beginning 0))
        (activate-mark)
        (let ((x (readq-extract)))
          (should (equal (readq--get x :snippet) "The mitral valve has two cusps."))
          (should (= (readq--get x :page) 2))
          (should (= (readq--get x :priority) 15))
          ;; The passage is highlighted in the chapter.
          (let ((ov (cl-find-if (lambda (o) (overlay-get o 'readq-extract))
                                (overlays-in (point-min) (point-max)))))
            (should ov)
            (should (equal (readq--unfill (buffer-substring-no-properties
                                           (overlay-start ov) (overlay-end ov)))
                           "The mitral valve has two cusps.")))
          ;; Read on to chapter 4 (index 3), then look up the extract.
          (nov-goto-document 3)
          (goto-char 100)
          (readq--record-position)
          (should (= (readq--get book :page) 3))
          (readq-goto-source x)
          (should (= nov-documents-index 2))
          (should (looking-at "The[ \n]+mitral"))
          (should readq--peeking)
          ;; Looking around while peeking does not move the bookmark...
          (nov-goto-document 1)
          (readq--record-position)
          (should (= (readq--get book :page) 3))
          ;; ...and readq-open goes back to it.
          (readq-open book)
          (should-not readq--peeking)
          (should (= nov-documents-index 3))
          (should (= (point) 100))
          (kill-buffer (current-buffer))
          (should (= (readq--get book :page) 3)))))))

;;;; Denote

(ert-deftest readq-xtest-denote-reads-notes ()
  ;; The real Denote, when it is on the load path, reads readq's notes
  ;; as its own.
  (skip-unless (require 'denote nil t))
  (defvar denote-directory)
  (readq-xtest--with-db
    (let* ((denote-directory readq-extracts-directory)
           (book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton Physiology"
                                 '("cardio")))
           (x (readq--create-extract book "Systole is the phase of contraction." :page 57))
           (sub (readq--create-extract x "phase of contraction" :title "A phase"))
           (file (expand-file-name (readq--get x :file))))
      (should (denote-file-has-denoted-filename-p file))
      (should (denote-file-is-note-p file))
      (should (equal (denote-retrieve-filename-identifier file) (readq--get x :id)))
      (should (equal (denote-retrieve-filename-signature file) "guyton=physiology=p0057"))
      (should (equal (denote-extract-keywords-from-path file) '("cardio" "extract")))
      (should (equal (denote-retrieve-filename-title file)
                     "systole-is-the-phase-of-contraction"))
      (should (equal (denote-retrieve-front-matter-title-value file 'org)
                     "Systole is the phase of contraction."))
      (should (equal (denote-retrieve-front-matter-keywords-value file 'org)
                     '("cardio" "extract")))
      ;; Denote would give the note the name it has.
      (should (equal (denote-format-file-name
                      (file-name-directory file) (readq--get x :id) '("cardio" "extract")
                      "Systole is the phase of contraction." ".org"
                      "guyton=physiology=p0057")
                     file))
      ;; A sub-extract links its parent the way Denote links notes.
      (should (equal (denote-get-path-by-id (readq--get x :id)) file))
      (should (string-match-p (format "^#\\+parent: +\\[\\[denote:%s\\]" (readq--get x :id))
                              (readq-test--note sub))))))

;;;; Extracts of older versions

(ert-deftest readq-xtest-convert-old-extracts ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/guyton.pdf") 20 "Guyton"))
           (old-file (expand-file-name "lib/guyton-extracts.org" readq-test--dir))
           (old (lambda (id title parent)
                  (list :id id :format 'extract :book (readq--get book :id) :parent parent
                        :title title :file old-file :priority 30 :status 'active
                        :added "2026-10-01" :due "2026-12-01" :interval 9.0
                        :page 57 :sessions 3)))
           ;; Made on 2026-10-01 at 12:00:00 and 12:00:05 UTC.
           (a (funcall old "6abe4b40abcd" "Systole" nil))
           (b (funcall old "6abe4b451234" "phase" "6abe4b40abcd"))
           (gone (funcall old "6abe4b460000" "Gone" nil)))
      (with-temp-file old-file
        (insert "#+TITLE: Extracts from Guyton\n#+READQ_BOOK: " (readq--get book :id) "\n\n"
                "* Chapter 9\n:PROPERTIES:\n:READQ_CHAPTER: Chapter 9 #1\n:END:\n"
                "** Systole, renamed\n:PROPERTIES:\n:READQ_ID: 6abe4b40abcd\n:END:\n"
                "Source: [[readq:6abe4b40abcd][Guyton, p. 57]]\n"
                "#+begin_quote\nSystole is the phase of contraction.\n#+end_quote\n"
                "Note: Key definition\n"
                "*** phase\n:PROPERTIES:\n:READQ_ID: 6abe4b451234\n:END:\n"
                "Source: [[readq:6abe4b451234][Guyton, p. 57]]\n"
                "#+begin_quote\nphase of contraction\n#+end_quote\n"))
      (setq readq--books (append (readq--books) (list a b gone)))
      ;; Until converted, an old extract cannot be opened.
      (should-not (readq--open-extract a))
      (let ((process-environment (cons "TZ=UTC" process-environment)))
        (should (= (readq-convert-extracts) 2)))
      ;; The id is the time the extract was made; the schedule is kept.
      (should (equal (readq--get a :id) "20261001T120000"))
      (should (equal (readq--get b :id) "20261001T120005"))
      (should (equal (readq--get b :parent) "20261001T120000"))
      (should (equal (readq--get a :due) "2026-12-01"))
      (should (= (readq--get a :sessions) 3))
      (should (equal (readq--get a :title) "Systole, renamed"))
      (should (string-match-p "/extracts/20261001T120000==guyton=p0057--systole-renamed__extract\\.org\\'"
                              (readq--get a :file)))
      (should (string-match-p
               (concat "\\`#\\+title: +Systole, renamed\n\\(?:#\\+.*\n\\)+\n"
                       "#\\+begin_quote\nSystole is the phase of contraction\\.\n#\\+end_quote\n"
                       "Note: Key definition\n\\'")
               (readq-test--note a)))
      (should (string-match-p "^#\\+parent: +\\[\\[denote:20261001T120000\\]"
                              (readq-test--note b)))
      (should-not (string-match-p "READQ_ID\\|^Source:" (readq-test--note b)))
      ;; The old file stays; an extract not found in it is left alone.
      (should (file-exists-p old-file))
      (should (equal (readq--get gone :id) "6abe4b460000"))
      (should (readq--open-extract a))
      (readq--end-review)
      (should (= (readq-convert-extracts) 0)))))

(provide 'readq-extract-test)
;;; readq-extract-test.el ends here
