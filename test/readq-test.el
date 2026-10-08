;;; readq-test.el --- Tests for readq -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -l test/readq-test.el -f ert-run-tests-batch-and-exit
;; nov.el integration tests run when nov is on the load path.

;;; Code:

(require 'ert)
(require 'readq)

(defvar readq-test--dir nil)

(defmacro readq-test--with-db (&rest body)
  "Run BODY with a fresh, empty readq database in a temp directory."
  (declare (indent 0))
  `(let* ((readq-test--dir (make-temp-file "readq-test" t))
          (readq-db-file (expand-file-name "readq.eld" readq-test--dir))
          (readq-figures-directory (expand-file-name "figures/" readq-test--dir))
          (readq--books nil)
          (readq--loaded nil)
          (readq--dirty nil)
          (readq--log nil)
          (readq--spread-date nil)
          (readq--tag-deadlines nil)
          (readq--budget-override nil))
     (unwind-protect (progn ,@body)
       (when readq-mode (readq-mode -1))
       (dolist (b (buffer-list))
         (when (buffer-local-value 'readq-book-mode b)
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory readq-test--dir t))))

(defun readq-test--touch (name)
  "Create an empty file NAME in the test directory and return its path."
  (let ((f (expand-file-name name readq-test--dir)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert "x"))
    f))

(defun readq-test--now (date)
  "Return a time value for 10:00 on DATE (YYYY-MM-DD)."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (encode-time (list 0 0 10 d m y nil -1 nil))))

;;;; Scheduling

(ert-deftest readq-test-afactor ()
  (let ((readq-min-afactor 1.2) (readq-max-afactor 2.5))
    (should (= (readq--afactor 0) 1.2))
    (should (= (readq--afactor 100) 2.5))
    (should (< (abs (- (readq--afactor 50) 1.85)) 1e-9))
    (should (= (readq--afactor -10) 1.2))
    (should (= (readq--afactor 500) 2.5))))

(ert-deftest readq-test-next-interval-bounds ()
  (let ((readq-min-interval 1) (readq-max-interval 60))
    (should (= (readq--next-interval 50 100) 60.0))
    (should (= (readq--next-interval 0.1 0) 1.0))
    (should (> (readq--next-interval 10 100) (readq--next-interval 10 0)))))

(ert-deftest readq-test-dates ()
  (let ((now (readq-test--now "2026-02-27")))
    (should (equal (readq--today now) "2026-02-27"))
    (should (equal (readq--date-in 2 now) "2026-03-01"))
    (should (equal (readq--date-in 0 now) "2026-02-27"))
    (should (= (readq--days-until "2026-03-01" now) 2))
    (should (= (readq--days-until "2026-02-20" now) -7))))

(ert-deftest readq-test-reschedule ()
  (let ((now (readq-test--now "2026-10-04"))
        (readq-min-afactor 1.2) (readq-max-afactor 2.5)
        (readq-min-interval 1) (readq-max-interval 60))
    (let ((hi (list :priority 0 :interval 10.0 :due "2026-10-04"))
          (lo (list :priority 100 :interval 10.0 :due "2026-10-04")))
      (readq--reschedule hi now)
      (readq--reschedule lo now)
      (should (= (plist-get hi :interval) 12.0))
      (should (equal (plist-get hi :due) "2026-10-16"))
      (should (= (plist-get lo :interval) 25.0))
      (should (equal (plist-get lo :due) "2026-10-29")))))

;;;; Queue

(ert-deftest readq-test-queue-order ()
  (readq-test--with-db
    (let* ((now (readq-test--now "2026-10-04"))
           (mk (lambda (name pri due &optional status)
                 (let ((b (readq--make-book (readq-test--touch name) pri name)))
                   (readq--put b :due due :status (or status 'active))
                   (setq readq--books (append readq--books (list b)))
                   b)))
           (due-low (funcall mk "a.pdf" 80 "2026-10-01"))
           (due-high (funcall mk "b.pdf" 10 "2026-10-04"))
           (due-high-older (funcall mk "c.epub" 10 "2026-09-30"))
           (later-soon (funcall mk "d.pdf" 5 "2026-10-05"))
           (later-far (funcall mk "e.pdf" 1 "2026-11-01"))
           (_paused (funcall mk "f.pdf" 0 "2026-10-01" 'paused))
           (_finished (funcall mk "g.pdf" 0 "2026-10-01" 'finished))
           (missing (funcall mk "h.pdf" 0 "2026-10-01")))
      (setq readq--loaded t)
      (delete-file (readq--get missing :file))
      (should (equal (readq--queue nil now)
                     (list due-high-older due-high due-low later-soon later-far)))
      (should (readq--due-p due-low now))
      (should-not (readq--due-p later-soon now)))))

(ert-deftest readq-test-randomization-keeps-due-first ()
  (readq-test--with-db
    (let ((now (readq-test--now "2026-10-04"))
          (readq-randomization 1.0))
      (dotimes (i 6)
        (let ((b (readq--make-book (readq-test--touch (format "b%d.pdf" i))
                                   (* i 20) "x")))
          (readq--put b :due (if (cl-evenp i) "2026-10-04" "2026-10-09"))
          (setq readq--books (append readq--books (list b)))))
      (setq readq--loaded t)
      (dotimes (_ 20)
        (let ((q (readq--queue t now)))
          (should (cl-every (lambda (b) (readq--due-p b now)) (cl-subseq q 0 3)))
          (should (cl-notany (lambda (b) (readq--due-p b now)) (cl-subseq q 3))))))))

;;;; Database

(ert-deftest readq-test-add-save-load ()
  (readq-test--with-db
    (let* ((f (readq-test--touch "My_Great-Book.epub"))
           (book (readq-add-book f 30)))
      (should (equal (readq--get book :title) "My Great Book"))
      (should (eq (readq--get book :format) 'epub))
      (should (equal (readq--get book :due) (readq--today)))
      (should-error (readq-add-book f 10) :type 'user-error)
      (should-error (readq-add-book (readq-test--touch "notes.docx") 10) :type 'user-error)
      (readq--put book :page 3 :progress 0.25)
      (readq--save)
      (setq readq--books nil readq--loaded nil)
      (let ((loaded (readq--book-by-file f)))
        (should loaded)
        (should (equal (readq--get loaded :page) 3))
        (should (equal (readq--get loaded :title) "My Great Book"))
        (should (eq (readq--get loaded :status) 'active))))))

(ert-deftest readq-test-add-directory ()
  (readq-test--with-db
    (readq-test--touch "lib/a.pdf")
    (readq-test--touch "lib/sub/b.EPUB")
    (readq-test--touch "lib/sub/c.docx")
    (readq-add-book (expand-file-name "lib/a.pdf" readq-test--dir) 5)
    (should (= (readq-add-directory (expand-file-name "lib" readq-test--dir) 40) 1))
    (should (= (length (readq--books)) 2))))

(ert-deftest readq-test-pdf-page-count ()
  (skip-unless (and (executable-find "gs") (executable-find "pdfinfo")))
  (readq-test--with-db
    (let ((f (expand-file-name "five.pdf" readq-test--dir)))
      (call-process "gs" nil nil nil "-q" "-sDEVICE=pdfwrite" "-o" f
                    "-c" "1 1 5 {pop showpage} for")
      (should (= (readq--get (readq-add-book f 50) :total) 5)))))

;;;; Progress

(ert-deftest readq-test-progress ()
  (should (= (readq--progress-from 'pdf 50 nil nil 200) 0.25))
  (should (= (readq--progress-from 'pdf 200 nil nil 200) 1.0))
  (should (null (readq--progress-from 'pdf 5 nil nil nil)))
  ;; chapter index 1 of 4, halfway through it
  (should (= (readq--progress-from 'epub 1 51 101 4) 0.375))
  (should (= (readq--progress-from 'epub 0 1 1 4) 0.0)))

;;;; Page-based buffers (pdf-view-mode is mocked)

(defvar-local readq-test--page 1)
(unless (fboundp 'pdf-view-mode)
  (define-derived-mode pdf-view-mode special-mode "PDFView"))

(defmacro readq-test--with-fake-pdf-tools (&rest body)
  "Run BODY with pdf-tools' page functions mocked."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'image-mode-window-get)
              (lambda (prop &optional _w) (and (eq prop 'page) readq-test--page)))
             ((symbol-function 'pdf-cache-number-of-pages) (lambda (&rest _) 100))
             ((symbol-function 'pdf-view-goto-page)
              (lambda (p &optional _w) (setq readq-test--page p))))
     (unwind-protect (progn ,@body)
       ;; Kill fake PDF buffers while the mocks still exist.
       (dolist (b (buffer-list))
         (when (buffer-local-value 'readq-book-mode b)
           (kill-buffer b))))))

(defun readq-test--run-timers ()
  "Let pending timers run."
  (accept-process-output nil 0.05))

(ert-deftest readq-test-pdf-session ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((f (readq-test--touch "book.pdf"))
             (book (readq-add-book f 20))
             (auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist)))
        (readq-mode 1)
        ;; First session: read from page 1 to page 30.
        (readq-open book)
        (should (eq major-mode 'pdf-view-mode))
        (should readq-book-mode)
        (setq readq-test--page 30)
        (readq--record-position)
        (should (= (readq--get book :page) 30))
        (should (= (readq--get book :total) 100))
        (should (= (readq--get book :progress) 0.3))
        (readq-finish-session)
        (should (= (readq--get book :sessions) 1))
        (should (string< (readq--today) (readq--get book :due)))
        (kill-buffer (current-buffer))
        ;; Killing right after finishing must not count a second session.
        (should (= (readq--get book :sessions) 1))
        ;; Reopen: position is restored, and the jump is not a reading session.
        (readq-open book)
        (readq-test--run-timers)
        (should (= readq-test--page 30))
        (should-not readq--restoring)
        (kill-buffer (current-buffer))
        (should (= (readq--get book :sessions) 1))
        ;; Moving and then killing the buffer counts as a session.
        (readq-open book)
        (readq-test--run-timers)
        (setq readq-test--page 42)
        (kill-buffer (current-buffer))
        (should (= (readq--get book :sessions) 2))
        (should (= (readq--get book :page) 42))
        (should (equal (plist-get (car (readq--get book :history)) :from-page) 30))
        ;; The database on disk has the update.
        (setq readq--books nil readq--loaded nil)
        (should (= (readq--get (readq--book-by-file f) :page) 42))))))

(ert-deftest readq-test-next-picks-highest-priority-due ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist))
             (a (readq-add-book (readq-test--touch "a.pdf") 50))
             (b (readq-add-book (readq-test--touch "b.pdf") 10))
             (c (readq-add-book (readq-test--touch "c.pdf") 30)))
        (readq-mode 1)
        (readq-next)
        (should (eq (readq--buffer-book) b))
        (setq readq-test--page 5)
        (readq-next)                    ; finishes b, opens c
        (should (eq (readq--buffer-book) c))
        (should-not (readq--due-p b))
        (readq-next)                    ; finishes c, opens a
        (should (eq (readq--buffer-book) a))
        ;; nothing due after a: decline reading ahead
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (readq-next))
        (should (eq (readq--buffer-book) a))
        (should (= 0 (cl-count-if #'readq--due-p (readq--books))))))))

(ert-deftest readq-test-dashboard ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 50 "Alpha")
    (readq-toggle-finished (readq-add-book (readq-test--touch "b.pdf") 10 "Beta"))
    (readq)
    (should (eq major-mode 'readq-dashboard-mode))
    (should (string-match-p "Alpha" (buffer-string)))
    (should-not (string-match-p "Beta" (buffer-string)))
    (readq-dashboard-toggle-finished)
    (should (string-match-p "Beta" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Alpha")
    (readq-priority-up (readq--target-book))
    (should (= (readq--get (readq--book-by-file (expand-file-name "a.pdf" readq-test--dir))
                           :priority)
               45))
    (kill-buffer "*readq*")))

;;;; EPUB with the real nov.el

(defun readq-test--make-epub (file chapters)
  "Write a minimal EPUB to FILE with CHAPTERS (a list of strings)."
  (let ((dir (make-temp-file "epub" t)))
    (unwind-protect
        (let ((write (lambda (name content)
                       (let ((p (expand-file-name name dir)))
                         (make-directory (file-name-directory p) t)
                         (with-temp-file p (insert content))))))
          (funcall write "mimetype" "application/epub+zip")
          (funcall write "META-INF/container.xml"
                   "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
          (let ((n 0) manifest spine)
            (dolist (text chapters)
              (cl-incf n)
              (funcall write (format "OEBPS/ch%d.xhtml" n)
                       (format "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C%d</title></head><body><h1>Chapter %d</h1><p>%s</p></body></html>" n n text))
              (push (format "<item id=\"ch%d\" href=\"ch%d.xhtml\" media-type=\"application/xhtml+xml\"/>" n n) manifest)
              (push (format "<itemref idref=\"ch%d\"/>" n) spine))
            (funcall write "OEBPS/toc.ncx"
                     "<?xml version=\"1.0\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>T</text></docTitle><navMap><navPoint id=\"n1\" playOrder=\"1\"><navLabel><text>Chapter 1</text></navLabel><content src=\"ch1.xhtml\"/></navPoint></navMap></ncx>")
            (funcall write "OEBPS/content.opf"
                     (format "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Test Book</dc:title><dc:identifier id=\"id\">readq-test-book</dc:identifier><dc:language>en</dc:language></metadata><manifest><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>%s</manifest><spine toc=\"ncx\">%s</spine></package>"
                             (apply #'concat (nreverse manifest))
                             (apply #'concat (nreverse spine)))))
          (let ((default-directory dir))
            (call-process "zip" nil nil nil "-X0q" (expand-file-name file) "mimetype")
            (call-process "zip" nil nil nil "-Xrq" (expand-file-name file) "META-INF" "OEBPS")))
      (delete-directory dir t))))

(ert-deftest readq-test-nov-session ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-test--with-db
    (let* ((nov-save-place-file nil)
           (f (expand-file-name "test.epub" readq-test--dir))
           (para (mapconcat #'identity (make-list 200 "lorem ipsum dolor") " ")))
      (readq-test--make-epub f (list para para para para))
      (let ((book (readq-add-book f 10))
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist)))
        (readq-mode 1)
        (readq-open book)
        (should (eq major-mode 'nov-mode))
        (should readq-book-mode)
        (should (eq (readq--book-buffer book) (current-buffer)))
        ;; Opening again must reuse the buffer even though nov clears
        ;; `buffer-file-name'.
        (let ((buf (current-buffer)))
          (readq-open book)
          (should (eq (current-buffer) buf)))
        (nov-goto-document 2)
        (goto-char (/ (point-max) 2))
        (let ((pt (point))
              ;; nov.el adds the table of contents for EPUB 2 books
              (total (length nov-documents)))
          (kill-buffer (current-buffer))
          (should (= (readq--get book :total) total))
          (should (= (readq--get book :page) 2))
          (should (= (readq--get book :point) pt))
          (should (< (/ 2.4 total) (readq--get book :progress) (/ 2.6 total)))
          (should (= (readq--get book :sessions) 1))
          (readq-open book)
          (readq-test--run-timers)
          (should (= nov-documents-index 2))
          (should (= (point) pt)))))))

(provide 'readq-test)
;;; readq-test.el ends here
