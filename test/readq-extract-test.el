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
                                     :page 57 :comment "Key definition")))
      (should (readq--extract-p x))
      (should (= (readq--get x :priority) 20))
      (should (equal (readq--get x :due) (readq--date-in 1)))
      (should (equal (file-name-nondirectory (readq--get x :file)) "gray-s-anatomy.org"))
      (let ((org (readq-xtest--org-text x)))
        (should (string-match-p "^#\\+TITLE: Extracts from Gray's Anatomy" org))
        (should (string-match-p (concat ":READQ_ID: " (readq--get x :id)) org))
        (should (string-match-p (regexp-quote "[[readq:") org))
        (should (string-match-p "Gray's Anatomy, p\\. 57\\]\\]" org))
        (should (string-match-p "^,\\* Systole" org))
        (should (string-match-p "^Note: Key definition" org)))
      ;; Not due yet, so the book comes first; then make the extract due.
      (should (eq (car (readq--queue)) book))
      (readq--put x :due (readq--today) :priority 5)
      (should (eq (car (readq--queue)) x))
      ;; Review it.
      (should (readq-open x))
      (should readq-review-mode)
      (should (eq (readq--extract-at-point) x))
      (should (buffer-narrowed-p))
      (should (eq (readq--target-book) x))
      ;; A sub-extract from part of the text.
      (goto-char (point-min))
      (search-forward "Systole")
      (set-mark (match-beginning 0))
      (search-forward "phase")
      (activate-mark)
      (let ((transient-mark-mode t))
        (let ((sub (readq-extract)))
          (should (equal (readq--get sub :parent) (readq--get x :id)))
          (should (equal (readq--get sub :book) (readq--get book :id)))
          (should (= (readq--get sub :page) 57))
          (should (equal (readq--get sub :title) "Systole is the phase"))
          (widen)
          (goto-char (org-find-property "READQ_ID" (readq--get sub :id)))
          (should (= (org-current-level) 2))))
      (goto-char (org-find-property "READQ_ID" (readq--get x :id)))
      (org-narrow-to-subtree)
      ;; Renaming the heading is picked up when the review ends.
      (org-edit-headline "Systole")
      (let ((finished (readq-finish-session)))
        (should (eq finished x)))
      (should-not readq-review-mode)
      (should-not (buffer-narrowed-p))
      (should (equal (readq--get x :title) "Systole"))
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

(ert-deftest readq-xtest-deleted-heading ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "b.pdf") 50))
           (x (readq--create-extract book "gone soon" :page 3 :edges '((0 0 1 0.1)))))
      (with-current-buffer (find-file-noselect (readq--get x :file))
        (goto-char (org-find-property "READQ_ID" (readq--get x :id)))
        (org-cut-subtree)
        (save-buffer))
      (should-not (readq-open x))
      (should-not (memq x (readq--books)))
      ;; Remembered, so the same highlight is not imported again.
      (should (readq--known-highlight-p book 3 '((0 0 1 0.1)) nil)))))

(ert-deftest readq-xtest-remove-extract ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "b.pdf") 50))
           (x (readq--create-extract book "remove me" :page 1)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (readq-remove-book x))
      (should-not (memq x (readq--books)))
      (should-not (string-match-p "remove me" (readq-xtest--org-text x))))))

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

(ert-deftest readq-xtest-extracts-next-to-book ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory nil)
           (book (readq-add-book (readq-test--touch "lib/Gray's Anatomy.pdf") 20 "Gray"))
           (x (readq--create-extract book "a passage" :page 1)))
      (should (equal (expand-file-name (readq--get x :file))
                     (expand-file-name "lib/Gray's Anatomy.org" readq-test--dir)))
      (should (equal (readq--get book :extracts-file) (readq--get x :file)))
      (should (string-match-p (concat "^#\\+READQ_BOOK: " (readq--get book :id))
                              (readq-xtest--org-text x)))
      ;; Later extracts go to the same file.
      (should (equal (readq--get (readq--create-extract book "another" :page 2) :file)
                     (readq--get x :file))))))

(ert-deftest readq-xtest-extracts-file-never-takes-your-notes ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory nil)
           (notes (expand-file-name "lib/gray.org" readq-test--dir))
           (pdf (readq-add-book (readq-test--touch "lib/gray.pdf") 20))
           (epub (readq-add-book (readq-test--touch "lib/gray.epub") 20)))
      (readq-test--touch "lib/gray.org")
      (with-temp-file notes (insert "* My own notes\n"))
      (should (equal (file-name-nondirectory
                      (readq--get (readq--create-extract pdf "p" :page 1) :file))
                     "gray-extracts.org"))
      ;; Same base name, other format: another file.
      (should (equal (file-name-nondirectory
                      (readq--get (readq--create-extract epub "e" :page 0) :file))
                     "gray-extracts-2.org"))
      (with-temp-buffer
        (insert-file-contents notes)
        (should (equal (buffer-string) "* My own notes\n"))))))

(ert-deftest readq-xtest-extracts-directory-option ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory (expand-file-name "all-extracts/" readq-test--dir))
           (book (readq-add-book (readq-test--touch "lib/b.pdf") 20 "My Book"))
           (x (readq--create-extract book "t" :page 1)))
      (should (equal (expand-file-name (readq--get x :file))
                     (expand-file-name "all-extracts/my-book.org" readq-test--dir))))))

(ert-deftest readq-xtest-extracts-unwritable-book-dir ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory nil)
           (readq-extracts-fallback-directory (expand-file-name "fallback/" readq-test--dir))
           (book (readq-add-book (readq-test--touch "ro/b.pdf") 20 "Read Only")))
      (cl-letf (((symbol-function 'file-writable-p) (lambda (_) nil)))
        (should (equal (expand-file-name (readq--extracts-file book))
                       (expand-file-name "fallback/read-only.org" readq-test--dir)))))))

(ert-deftest readq-xtest-relocate-moves-extracts ()
  (readq-xtest--with-db
    (let* ((readq-extracts-directory nil)
           (old (readq-test--touch "old/b.pdf"))
           (book (readq-add-book old 20))
           (x (readq--create-extract book "kept passage" :page 1))
           (new (expand-file-name "new/b.pdf" readq-test--dir)))
      ;; The PDF alone was moved: readq moves its extracts file along.
      (make-directory (file-name-directory new) t)
      (rename-file old new)
      (readq-relocate book new)
      (should (file-exists-p (expand-file-name "new/b.org" readq-test--dir)))
      (should-not (file-exists-p (expand-file-name "old/b.org" readq-test--dir)))
      (should (equal (expand-file-name (readq--get x :file))
                     (expand-file-name "new/b.org" readq-test--dir)))
      (should (readq-open x))
      (should (string-match-p "kept passage" (buffer-string)))
      (readq--end-review)
      ;; The whole folder was moved: the file is found where it now is.
      (let ((moved (expand-file-name "moved" readq-test--dir)))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p readq-test--dir (buffer-file-name b)))
            (kill-buffer b)))
        (rename-file (expand-file-name "new" readq-test--dir) moved)
        (readq-relocate book (expand-file-name "b.pdf" moved))
        (should (equal (expand-file-name (readq--get x :file))
                       (expand-file-name "b.org" moved)))
        (should (readq-open x))))))

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

(provide 'readq-extract-test)
;;; readq-extract-test.el ends here
