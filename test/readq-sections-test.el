;;; readq-sections-test.el --- Tests for readq sections -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-sections-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The PDF table of contents test needs pdf-tools (READQ_EPDFINFO, see
;; readq-extract-test.el); the EPUB tests need nov.el and zip.

;;; Code:

(require 'ert)
(require 'org)
(require 'eww)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)

(defun readq-stest--make-epub (file version chapters toc)
  "Write an EPUB VERSION (\"2.0\" or \"3.0\") to FILE.
CHAPTERS is a list of strings, one file each (ch1.xhtml ...).  TOC is a
tree of (TITLE CHAPTER-NUMBER CHILDREN...)."
  (let ((dir (make-temp-file "epub" t)) (n 0) manifest spine)
    (unwind-protect
        (let ((write (lambda (name content)
                       (let ((p (expand-file-name name dir)))
                         (make-directory (file-name-directory p) t)
                         (with-temp-file p (insert content))))))
          (funcall write "mimetype" "application/epub+zip")
          (funcall write "META-INF/container.xml"
                   "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
          (dolist (text chapters)
            (setq n (1+ n))
            (funcall write (format "OEBPS/ch%d.xhtml" n)
                     (format "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C%d</title></head><body><h1>Chapter %d</h1><p>%s</p></body></html>" n n text))
            (push (format "<item id=\"ch%d\" href=\"ch%d.xhtml\" media-type=\"application/xhtml+xml\"/>" n n) manifest)
            (push (format "<itemref idref=\"ch%d\"/>" n) spine))
          (let ((counter 0))
            (cl-labels ((ncx (node)
                          (setq counter (1+ counter))
                          (format "<navPoint id=\"n%d\" playOrder=\"%d\"><navLabel><text>%s</text></navLabel><content src=\"ch%d.xhtml\"/>%s</navPoint>"
                                  counter counter (car node) (cadr node)
                                  (mapconcat #'ncx (cddr node) "")))
                        (nav (node)
                          (format "<li><a href=\"ch%d.xhtml\">%s</a>%s</li>" (cadr node) (car node)
                                  (if (cddr node) (concat "<ol>" (mapconcat #'nav (cddr node) "") "</ol>") ""))))
              (if (equal version "2.0")
                  (funcall write "OEBPS/toc.ncx"
                           (concat "<?xml version=\"1.0\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>T</text></docTitle><navMap>"
                                   (mapconcat #'ncx toc "") "</navMap></ncx>"))
                (funcall write "OEBPS/nav.xhtml"
                         (concat "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>"
                                 (mapconcat #'nav toc "") "</ol></nav></body></html>")))))
          (funcall write "OEBPS/content.opf"
                   (format "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"%s\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Test Book</dc:title><dc:identifier id=\"id\">readq-sections-%s</dc:identifier><dc:language>en</dc:language></metadata><manifest>%s%s</manifest><spine%s>%s</spine></package>"
                           version version
                           (if (equal version "2.0")
                               "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
                             "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")
                           (apply #'concat (nreverse manifest))
                           (if (equal version "2.0") " toc=\"ncx\"" "")
                           (apply #'concat (nreverse spine))))
          (let ((default-directory dir))
            (call-process "zip" nil nil nil "-X0q" (expand-file-name file) "mimetype")
            (call-process "zip" nil nil nil "-Xrq" (expand-file-name file) "META-INF" "OEBPS")))
      (delete-directory dir t))))

(defun readq-stest--marks (buffer specs)
  "In the sections BUFFER, mark entries: SPECS is a list of (TITLE . PRIORITY)."
  (with-current-buffer buffer
    (dolist (spec specs)
      (goto-char (point-min))
      (search-forward (car spec))
      (readq-sections-set-priority (cdr spec)))))

(defun readq-stest--section (title)
  "Return the section whose heading is TITLE."
  (cl-find title (readq--books) :key (lambda (x) (readq--get x :heading)) :test #'equal))

;;;; Tables of contents and the sections buffer

(ert-deftest readq-stest-pdf-outline-and-picker ()
  (skip-unless (readq-xtest--pdf-tools-p))
  (readq-xtest--with-db
    (let* ((file (readq-xtest--copy-fixture "outline.pdf" "physiology.pdf"))
           (book (readq-add-book file 30 "Physiology")))
      (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :depth)
                                               (plist-get e :start) (plist-get e :end)))
                             (readq--book-outline book))
                     '(("Part 1: The heart" 1 1 4)
                       ("Chapter 1: Anatomy" 2 1 2)
                       ("Chapter 2: The cardiac cycle" 2 3 4)
                       ("Part 2: The vessels" 1 5 8)
                       ("Chapter 3: Arteries" 2 5 8))))
      (readq-add-sections book)
      (let ((buf (current-buffer)))
        (should (derived-mode-p 'readq-sections-mode))
        (should (string-match-p "  Chapter 2: The cardiac cycle +p 3–4" (buffer-string)))
        (cl-letf (((symbol-function 'read-number) (lambda (&rest _) 10)))
          (readq-stest--marks buf '(("Chapter 2" . 10))))
        (goto-char (point-min))
        (search-forward "Chapter 3")
        (readq-sections-mark)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (should (= (length (readq-sections-add)) 2)))
        (let ((c2 (readq-stest--section "Chapter 2: The cardiac cycle"))
              (c3 (readq-stest--section "Chapter 3: Arteries")))
          (should (equal (list (readq--get c2 :start) (readq--get c2 :end)
                               (readq--get c2 :priority))
                         '(3 4 10)))
          (should (equal (list (readq--get c3 :start) (readq--get c3 :end)
                               (readq--get c3 :priority))
                         '(5 8 30)))
          (should (equal (readq--get c2 :title) "Physiology › Chapter 2: The cardiac cycle"))
          (should (equal (readq--get c2 :file) (readq--get book :file))))
        ;; The book was paused: only its sections come up.
        (should (eq (readq--get book :status) 'paused))
        (should (equal (mapcar (lambda (x) (readq--get x :heading)) (readq--queue))
                       '("Chapter 2: The cardiac cycle" "Chapter 3: Arteries")))
        ;; Queued sections are shown as such and not added twice.
        (should (string-match-p "Chapter 3: Arteries +p 5–8 +in queue" (buffer-string)))
        (goto-char (point-min))
        (search-forward "Chapter 3")
        (readq-sections-mark)
        (should-error (readq-sections-add) :type 'user-error)
        (kill-buffer buf)))))

(ert-deftest readq-stest-mark-level ()
  (readq-ftest--with-db
    (let ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20)))
      (readq-add-sections book)
      (goto-char (point-min))
      (search-forward "Systole")
      (readq-sections-mark-level)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should (equal (mapcar (lambda (x) (readq--get x :heading)) (readq-sections-add))
                       '("Systole" "Diastole"))))
      (should (eq (readq--get book :status) 'active))
      (kill-buffer (current-buffer)))))

(ert-deftest readq-stest-epub-outline ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-xtest--with-db
    (let ((nov-save-place-file nil)
          (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist)))
      (dolist (version '("2.0" "3.0"))
        (let* ((f (expand-file-name (format "book%s.epub" version) readq-test--dir))
               (book (progn (readq-stest--make-epub
                             f version '("one" "two" "three" "four")
                             '(("Part I" 1 ("Chapter 1" 1) ("Chapter 2" 2))
                               ("Part II" 3 ("Chapter 3" 3) ("Chapter 4" 4))))
                            (readq-add-book f 30))))
          (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :depth)
                                                   (plist-get e :start) (plist-get e :end)))
                                 (readq--book-outline book))
                         '(("Part I" 1 1 2) ("Chapter 1" 2 1 1) ("Chapter 2" 2 2 2)
                           ("Part II" 1 3 4) ("Chapter 3" 2 3 3) ("Chapter 4" 2 4 4))))
          ;; Reading the table of contents leaves no buffer behind.
          (should-not (readq--book-buffer book)))))))

(ert-deftest readq-stest-text-and-html-outlines ()
  (readq-ftest--with-db
    (let ((org (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 20))
          (md (readq-add-book (readq-ftest--write "lib/kidney.md" readq-ftest--md) 20))
          (html (readq-add-book (readq-ftest--write "web/a.html" readq-ftest--html) 20)))
      (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :level)))
                             (readq--book-outline org))
                     '(("Heart" 1) ("Systole" 2) ("Diastole" 2) ("Lungs" 1))))
      (should (equal (mapcar (lambda (e) (plist-get e :title)) (readq--book-outline md))
                     '("Kidney" "Nephron")))
      (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :level)))
                             (readq--book-outline html))
                     '(("The cardiac cycle" 1) ("Systole" 2) ("Diastole" 2)))))))

;;;; Reading sections

(ert-deftest readq-stest-pdf-section-reading ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist))
             (book (readq-add-book (readq-test--touch "book.pdf") 30 "Book"))
             (section (readq-add-section book "Arteries" 5 8 10)))
        (readq-mode 1)
        ;; Read the book a little first: page 2.
        (readq-open book)
        (readq-test--run-timers)
        (setq readq-test--page 2)
        (readq--record-position)
        (should (= (readq--get book :page) 2))
        ;; Opening the section goes to its first page.
        (readq-open section)
        (readq-test--run-timers)
        (should (equal readq--section-id (readq--get section :id)))
        (should (= readq-test--page 5))
        (should (equal (readq--lighter) " RQ:§25%"))
        (setq readq-test--page 7)
        (readq--record-position)
        (should (= (readq--get section :progress) 0.75))
        (should (equal (readq--position-string section) "p 7 (5–8)"))
        ;; The book's own bookmark did not move.
        (should (= (readq--get book :page) 2))
        ;; Killing the buffer ends the section's session, not the book's.
        (kill-buffer (current-buffer))
        (should (= (readq--get section :sessions) 1))
        (should-not (readq--due-p section))
        (should (= (readq--get book :sessions) 1))
        ;; The section reopens where you left it.
        (readq-open section)
        (readq-test--run-timers)
        (should (= readq-test--page 7))
        ;; Opening the book itself goes back to the book's bookmark.
        (readq-open book)
        (should-not readq--section-id)
        (should (= readq-test--page 2))
        (should (= (readq--get section :page) 7))))))

(ert-deftest readq-stest-pdf-section-end-and-next ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist))
             (book (readq-add-book (readq-test--touch "book.pdf") 30 "Book"))
             (s1 (readq-add-section book "One" 1 4 5))
             (s2 (readq-add-section book "Two" 5 8 6)))
        (readq-toggle-pause book)
        (readq-mode 1)
        (readq-next)
        (readq-test--run-timers)
        (should (equal readq--section-id (readq--get s1 :id)))
        (setq readq-test--page 4)
        (readq--record-position)
        (should (readq--at-end-p s1))
        ;; At the end: offer to finish the section, then open the next one.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (readq-next))
        (readq-test--run-timers)
        (should (eq (readq--get s1 :status) 'finished))
        (should (equal readq--section-id (readq--get s2 :id)))
        (should (= readq-test--page 5))))))

(ert-deftest readq-stest-text-section-reading ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "lib/notes.org" readq-ftest--org))
           (book (readq-add-book file 20 "Notes")))
      (readq-add-sections book)
      (goto-char (point-min))
      (search-forward "Heart")
      (readq-sections-mark)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (readq-sections-add))
      (kill-buffer (current-buffer))
      (let ((heart (readq-stest--section "Heart")))
        (readq-open heart)
        (readq-ftest--run-timers)
        (should (looking-at "\\* Heart"))
        (should (equal (readq--position-string heart) "§ 0%"))
        ;; Heart runs up to Lungs; Systole and Diastole are inside it.
        (search-forward "Diastole is ")
        (readq--record-position)
        (should (< 0.7 (readq--get heart :progress) 0.95))
        (should-not (readq--get book :page))
        (kill-buffer (current-buffer))
        ;; Text added above the section: it is still found by its heading.
        (readq-ftest--write "lib/notes.org"
                            (concat "* Preface\nA preface added later.\n" readq-ftest--org))
        (readq-open heart)
        (readq-ftest--run-timers)
        (should (looking-at "the phase of relaxation"))
        (should (< 0.7 (readq--section-progress heart (list :point (point))) 0.95))))))

(ert-deftest readq-stest-repeated-headings ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "lib/rep.md" "# Summary\nfirst\n# Body\ntext\n# Summary\nsecond\n"))
           (book (readq-add-book file 20))
           (outline (readq--book-outline book))
           (second (readq--make-section book (nth 2 outline) 20)))
      (should (= (readq--get second :occurrence) 2))
      (readq-open second)
      (readq-ftest--run-timers)
      (should (looking-at "# Summary\nsecond")))))

(ert-deftest readq-stest-html-section ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "web/a.html" readq-ftest--html))
           (book (readq-add-book file 20 "Article"))
           (diastole (readq--make-section book (nth 2 (readq--book-outline book)) 10)))
      (readq-open diastole)
      (readq-ftest--run-timers)
      (should (derived-mode-p 'eww-mode))
      (should readq-book-mode)
      (should (equal readq--section-id (readq--get diastole :id)))
      (should (looking-at "Diastole"))
      (goto-char (point-max))
      (readq--record-position)
      (should (= (readq--get diastole :progress) 1.0)))))

(ert-deftest readq-stest-epub-section-reading ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-xtest--with-db
    (let* ((nov-save-place-file nil)
           (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist))
           (f (expand-file-name "book.epub" readq-test--dir))
           (book (progn (readq-stest--make-epub
                         f "3.0" '("one" "two" "three" "four")
                         '(("Part I" 1 ("Chapter 1" 1) ("Chapter 2" 2))
                           ("Part II" 3 ("Chapter 3" 3) ("Chapter 4" 4))))
                        (readq-add-book f 30)))
           (part2 (readq--make-section book (nth 3 (readq--book-outline book)) 10)))
      (readq-mode 1)
      (readq-open part2)
      (readq-test--run-timers)
      (should (= nov-documents-index 3))
      (should (equal (readq--position-string part2) "ch 4 (4–5)"))
      (nov-goto-document 4)
      (goto-char (point-max))
      (readq--record-position)
      (should (= (readq--get part2 :progress) 1.0))
      (should (readq--at-end-p part2))
      (kill-buffer (current-buffer)))))

;;;; With the rest of readq

(ert-deftest readq-stest-extracts-take-section-priority ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org) 50))
           (lungs (readq--make-section book (nth 3 (readq--book-outline book)) 5))
           (transient-mark-mode t))
      (readq-open lungs)
      (readq-ftest--run-timers)
      (readq-ftest--select "The lungs exchange gases\\.")
      (let ((x (readq-extract)))
        (should (= (readq--get x :priority) 5))
        (should (equal (readq--get x :book) (readq--get book :id)))))))

(ert-deftest readq-stest-dashboard-remove-relocate ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "old/b.pdf") 30 "Book"))
           (section (readq-add-section book "Arteries" 5 8 10)))
      (readq)
      (goto-char (point-min))
      (should (re-search-forward "pdf +▾ Book .*\n.*section +Arteries .* p 5 (5–8)" nil t))
      (kill-buffer "*readq*")
      (should (string-match-p "\\[section\\] Book › Arteries"
                              (readq--book-label section)))
      ;; Sections follow their book when it moves...
      (let ((new (readq-test--touch "new/b.pdf")))
        (readq-relocate book new)
        (should (equal (readq--get section :file) (readq--get book :file))))
      ;; ...and go when it is removed.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (readq-remove-book book))
      (should-not (memq section (readq--books))))))

(provide 'readq-sections-test)
;;; readq-sections-test.el ends here
