;;; readq-formats-test.el --- Tests for text and HTML books -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-formats-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'eww)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-ftest--org
  "#+TITLE: Physiology notes

* Heart
The heart pumps blood.
** Systole
Systole is the phase of contraction of the ventricles.
** Diastole
Diastole is the phase of relaxation.
* Lungs
The lungs exchange gases.
")

(defconst readq-ftest--md
  "# Kidney

The kidney filters blood.

## Nephron

The nephron is the functional unit of the kidney.
")

(defconst readq-ftest--html
  "<html><head><title>Cardiac cycle</title></head><body>
<h1>The cardiac cycle</h1><p>Intro paragraph about the heart.</p>
<h2>Systole</h2><p>Systole is the phase of contraction of the ventricles, which ejects blood into the aorta.</p>
<h2>Diastole</h2><p>Diastole is the phase of relaxation.</p>
<p><a href=\"other.html\">Other page</a></p></body></html>
")

(defmacro readq-ftest--with-db (&rest body)
  "Run BODY with an empty database, readq-mode on, extracts next to books."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq-extracts-directory nil)
           (eww-history nil))
       (readq-mode 1)
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (with-current-buffer b (derived-mode-p 'eww-mode))
             (with-current-buffer b (when readq-book-mode (readq-book-mode -1)))
             (kill-buffer b)))))))

(defun readq-ftest--write (name content)
  "Write CONTENT to NAME in the test directory and return its path."
  (let ((file (expand-file-name name readq-test--dir)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))
    file))

(defun readq-ftest--run-timers ()
  "Let pending timers run."
  (accept-process-output nil 0.05))

(defun readq-ftest--select (regexp)
  "Select the text matching REGEXP in the current buffer."
  (goto-char (point-min))
  (re-search-forward regexp)
  (set-mark (match-beginning 0))
  (goto-char (match-end 0))
  (activate-mark))

;;;; Org, Markdown, text

(ert-deftest readq-ftest-org-book ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "lib/notes.org" readq-ftest--org))
           (book (readq-add-book file 20 "Notes")))
      (should (eq (readq--get book :format) 'text))
      (readq-open book)
      (should (derived-mode-p 'org-mode))
      (should readq-book-mode)
      (should (equal (mapcar #'cdr (readq--headings))
                     '("Heart" "Systole" "Diastole" "Lungs")))
      (goto-char (point-min))
      (search-forward "Diastole is ")
      (let ((pt (point)))
        (kill-buffer (current-buffer))
        (should (= (readq--get book :point) pt))
        (should (= (readq--get book :page) 3))
        (should (= (readq--get book :total) 4))
        (should (equal (readq--position-string book) "§ 3/4"))
        (should (< 0.6 (readq--get book :progress) 0.8))
        (should (= (readq--get book :sessions) 1))
        (should (string-prefix-p "the phase of relaxation" (readq--get book :anchor))))
      ;; Edit the file outside the session: the anchor still finds the place.
      (readq-ftest--write "lib/notes.org"
                          (concat "#+TITLE: Physiology notes\n\nA new introduction, "
                                  "added later, which moves everything down.\n"
                                  (substring readq-ftest--org 26)))
      (readq-open book)
      (readq-ftest--run-timers)
      (should (looking-at "the phase of relaxation"))
      (should-not readq--restoring))))

(ert-deftest readq-ftest-markdown-and-text-books ()
  (readq-ftest--with-db
    (let* ((md (readq-add-book (readq-ftest--write "lib/kidney.md" readq-ftest--md) 30))
           (txt (readq-add-book (readq-ftest--write "lib/plain.txt"
                                                    "Line one.\nLine two.\nLine three.\n")
                                40)))
      ;; Markdown is tracked whatever its major mode (no markdown-mode here).
      (readq-open md)
      (should readq-book-mode)
      (should (equal (readq--headings) '((1 . "Kidney") (38 . "Nephron"))))
      (goto-char (point-max))
      (readq--record-position)
      (should (equal (readq--position-string md) "§ 2/2"))
      (should (= (readq--get md :progress) 1.0))
      (should (readq--at-end-p md))
      (readq-open txt)
      (search-forward "Line two")
      (readq--record-position)
      (should (equal (readq--position-string txt) "56%"))
      (readq)
      (goto-char (point-min))
      (should (re-search-forward "md +kidney" nil t))
      (should (re-search-forward "txt +plain" nil t))
      (kill-buffer "*readq*"))))

(ert-deftest readq-ftest-own-files-are-not-books ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20))
           (x (readq--create-extract book "The heart pumps blood." :point 40)))
      ;; The book is notes.org, so its extracts cannot go there.
      (should (equal (file-name-nondirectory (readq--get x :file)) "notes-extracts.org"))
      (should (readq--own-file-p (readq--get x :file)))
      (should-not (readq--own-file-p (readq--get book :file)))
      (should-error (readq-add-book (readq--get x :file) 10) :type 'user-error)
      (readq-ftest--write "lib/notes-cards.org"
                          "* Q :drill:\n:PROPERTIES:\n:READQ_CARD_OF: abc\n:END:\n")
      (readq-ftest--write "lib/new.md" readq-ftest--md)
      ;; Adding the folder adds new.md only.
      (should (= (readq-add-directory (expand-file-name "lib" readq-test--dir) 50) 1)))))

(ert-deftest readq-ftest-org-extract-and-source ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org)
                                 20 "Notes"))
           (transient-mark-mode t))
      (readq-open book)
      (goto-char (point-max))
      (readq--record-position)
      (let ((bookmark (readq--get book :point)))
        (readq-ftest--select "Systole is the phase[^.]*\\.")
        (let ((x (readq-extract)))
          (should (equal (readq--get x :snippet)
                         "Systole is the phase of contraction of the ventricles."))
          (should (equal (readq--get x :section) "Systole"))
          (should (= (readq--get x :page) 2))
          (should (equal (readq--position-string x) "§ 2"))
          (should (string-match-p (regexp-quote "[[readq:")
                                  (readq-xtest--org-text x)))
          (should (string-match-p "\\]\\[Notes, Systole\\]\\]" (readq-xtest--org-text x)))
          ;; The passage is highlighted in the book.
          (should (cl-some (lambda (o) (overlay-get o 'readq-extract))
                           (overlays-in (point-min) (point-max))))
          ;; Look it up from the extract, then return to the bookmark.
          (goto-char (point-max))
          (readq-goto-source x)
          (should readq--peeking)
          (should (looking-at "Systole is the phase"))
          (readq--record-position)
          (should (= (readq--get book :point) bookmark))
          (readq-open book)
          (should-not readq--peeking)
          (should (= (point) bookmark))
          ;; Flashcards name the section as the source.
          (should (equal (plist-get (readq--make-card x) :source) "Notes, Systole")))))))

(ert-deftest readq-ftest-org-links ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/kidney.md" readq-ftest--md)
                                 20 "Kidney"))
           visited)
      (readq-open book)
      (goto-char (point-min))
      (search-forward "The nephron")
      (let ((org-store-link-plist nil))
        (should (readq--org-store-link))
        (let ((link (plist-get org-store-link-plist :link)))
          (should (equal link (format "readq:%s::t%d" (readq--get book :id) (point))))
          (should (equal (plist-get org-store-link-plist :description) "Kidney, Nephron"))
          (cl-letf (((symbol-function 'readq--visit-location)
                     (lambda (&rest args) (setq visited args))))
            (readq--org-follow (substring link (length "readq:"))))
          (should (equal visited (list book nil (point)))))))))

(ert-deftest readq-ftest-org-books-keep-org-links ()
  (readq-ftest--with-db
    (let ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20)))
      (readq-open book)
      (should-not (readq--org-store-link)))))

;;;; HTML in eww

(ert-deftest readq-ftest-html-book ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "web/My Article.html" readq-ftest--html))
           (book (progn (readq-ftest--write "web/other.html"
                                            "<html><body><h1>Other</h1><p>Elsewhere.</p></body></html>")
                        (readq-add-book file 30 "Article"))))
      (should (eq (readq--get book :format) 'html))
      (readq-open book)
      (readq-ftest--run-timers)
      (should (derived-mode-p 'eww-mode))
      (should readq-book-mode)
      (should (equal (readq--buffer-file) file))
      (should (equal (mapcar #'cdr (readq--headings))
                     '("The cardiac cycle" "Systole" "Diastole")))
      (should (eq (readq--book-buffer book) (current-buffer)))
      (re-search-forward "Diastole[ \n]+is")
      (readq--record-position)
      (let ((pt (point))
            (buf (current-buffer)))
        (should (= (readq--get book :page) 3))
        ;; Following a link ends the session and stops tracking...
        (let ((url-allow-non-local-files t))
          (eww (concat "file://" (expand-file-name "web/other.html" readq-test--dir))))
        (should (eq (current-buffer) buf))
        (should-not readq-book-mode)
        (should (= (readq--get book :sessions) 1))
        (goto-char (point-max))
        (readq--tick)
        (should (= (readq--get book :point) pt))
        ;; ...and going back to the book resumes it at your place.
        (eww-back-url)
        (readq-ftest--run-timers)
        (should readq-book-mode)
        (should (= (point) pt))
        ;; Opening the book again reuses its buffer.
        (readq-open book)
        (should (eq (current-buffer) buf))))))

(ert-deftest readq-ftest-html-extract-and-source ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "web/article.html" readq-ftest--html))
           (book (readq-add-book file 30 "Article"))
           (transient-mark-mode t))
      (readq-open book)
      (readq-ftest--run-timers)
      (readq-ftest--select "Systole[ \n]+is[^.]*aorta\\.")
      (let ((x (readq-extract)))
        ;; eww's line wrapping is not kept.
        (should (equal (readq--get x :snippet)
                       "Systole is the phase of contraction of the ventricles, which ejects blood into the aorta."))
        (should (equal (readq--get x :section) "Systole"))
        (should (cl-some (lambda (o) (overlay-get o 'readq-extract))
                         (overlays-in (point-min) (point-max))))
        ;; With the book closed, looking up the source opens it there.
        (kill-buffer (current-buffer))
        (readq-goto-source x)
        (readq-ftest--run-timers)
        (should (derived-mode-p 'eww-mode))
        (should readq-book-mode)
        (should readq--peeking)
        (should (looking-at "Systole[ \n]+is[ \n]+the[ \n]+phase"))))))

;;;; File names of eww pages

(ert-deftest readq-ftest-eww-file-names ()
  (with-temp-buffer
    (eww-mode)
    (setq-local eww-data (list :url "file:///C:/Books/My Article.html"))
    (should (equal (readq--eww-file) "C:/Books/My Article.html"))
    (setq-local eww-data (list :url "file:///home/me/caf%C3%A9%20notes.html"))
    (should (equal (readq--eww-file) "/home/me/café notes.html"))
    (setq-local eww-data (list :url "https://example.com/page.html"))
    (should-not (readq--eww-file))))

(provide 'readq-formats-test)
;;; readq-formats-test.el ends here
