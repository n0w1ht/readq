;;; readq-media-toc-test.el --- Tables of contents for audio and video -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-media-toc-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Playback tests run the real mpv (skipped without it).

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-media-test)

(defun readq-tocttest--summary (entries)
  "Return ENTRIES as (TITLE DEPTH START END) lists."
  (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :depth)
                            (plist-get e :start)
                            (and (plist-get e :end) (round (plist-get e :end)))))
          entries))

(defun readq-tocttest--parse (text &optional duration)
  "Parse TEXT as a table of contents of a file lasting DURATION seconds."
  (readq-tocttest--summary (readq--media-toc-ends (readq--parse-media-toc text) duration)))

(defconst readq-tocttest--nested
  "* Section 1
00:01:04 Sub-section 1

00:03:24 Sub-section 2

* Section 2
00:11:04 Sub-section 1

00:33:24 Sub-section 2")

;; Within the 90 seconds of lecture.opus.
(defconst readq-tocttest--lecture
  "* Part 1
00:00:05 Intro
00:00:20 Middle
* Part 2
00:01:04 End")

;;;; Parsing

(ert-deftest readq-tocttest-flat ()
  (should (equal (readq-tocttest--parse "00:02:03 Section 1\n00:04:55 Section 2\n" 600)
                 '(("Section 1" 1 123.0 295) ("Section 2" 1 295.0 600)))))

(ert-deftest readq-tocttest-nested ()
  (should (equal (readq-tocttest--parse readq-tocttest--nested 3000)
                 '(("Section 1" 1 64.0 664) ("Sub-section 1" 2 64.0 204)
                   ("Sub-section 2" 2 204.0 664)
                   ("Section 2" 1 664.0 3000) ("Sub-section 1" 2 664.0 2004)
                   ("Sub-section 2" 2 2004.0 3000)))))

(ert-deftest readq-tocttest-variants ()
  ;; YouTube descriptions, lists, brackets, separators, trailing times.
  (should (equal (readq-tocttest--parse
                  "Chapters:\n0:00 Intro\n- 1:04:06 - Long one\n3. [1:10:30] Numbered\n" 5000)
                 '(("Intro" 1 0.0 3846) ("Long one" 1 3846.0 4230)
                   ("Numbered" 1 4230.0 5000))))
  (should (equal (readq-tocttest--parse "Opening - 0:10\nClosing (2:07)\n" 200)
                 '(("Opening" 1 10.0 127) ("Closing" 1 127.0 200))))
  ;; Markdown headings, and a heading with its own time.
  (should (equal (readq-tocttest--parse "# A 0:10\n0:30 Inside\n## B\n0:50 Deep\n" 100)
                 '(("A" 1 10.0 100) ("Inside" 2 30.0 50) ("B" 2 50.0 100)
                   ("Deep" 3 50.0 100))))
  ;; Unknown duration: the last ends are open.
  (should (equal (readq-tocttest--parse "0:10 One\n0:20 Two\n")
                 '(("One" 1 10.0 20) ("Two" 1 20.0 nil))))
  ;; Not timestamps.
  (should-not (readq--parse-media-toc "Version 2:75 notes\nNothing here\n")))

(ert-deftest readq-tocttest-paths ()
  (should (equal (mapcar (lambda (e) (plist-get e :path))
                         (readq--media-toc-paths
                          (readq--media-toc-ends (readq--parse-media-toc readq-tocttest--nested)
                                                 3000)))
                 '(nil "Section 1 › Sub-section 1" "Section 1 › Sub-section 2"
                       nil "Section 2 › Sub-section 1" "Section 2 › Sub-section 2"))))

;;;; Finding and choosing one

(ert-deftest readq-tocttest-file-next-to-media ()
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (base (file-name-sans-extension (readq--get book :file))))
      (should-not (readq--media-toc-file book))
      ;; A text file without timestamps is not one, nor readq's own files.
      (with-temp-file (concat base ".txt") (insert "Just notes.\n"))
      (should-not (readq--media-toc-file book))
      (with-temp-file (concat base ".chapters") (insert "00:00:05 Intro\n"))
      (should (equal (readq--media-toc-file book) (concat base ".chapters")))
      (with-temp-file (concat base ".toc") (insert readq-tocttest--lecture))
      (should (equal (readq--media-toc-file book) (concat base ".toc")))
      (should (= (length (cdr (readq--media-toc book))) 5)))))

(ert-deftest readq-tocttest-set-file-region-clear ()
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (toc (expand-file-name "anywhere/lecture notes.org" readq-test--dir)))
      (make-directory (file-name-directory toc) t)
      (with-temp-file toc (insert readq-tocttest--lecture))
      (readq-set-media-toc book toc)
      (should (equal (expand-file-name (readq--get book :toc-file)) toc))
      (should (= (length (cdr (readq--media-toc book))) 5))
      ;; Saved with the book.
      (setq readq--books nil readq--loaded nil)
      (setq book (readq--book-by-file (readq--get book :file)))
      (should (readq--get book :toc-file))
      ;; Text selected in any buffer.
      (with-temp-buffer
        (insert "Video description\n0:00 Start\n0:45 Second half\nThanks!\n")
        (let ((transient-mark-mode t))
          (set-mark (point-min)) (goto-char (point-max)) (activate-mark)
          (readq-set-media-toc book)))
      (should-not (readq--get book :toc-file))
      (should (equal (mapcar (lambda (e) (plist-get e :title)) (cdr (readq--media-toc book)))
                     '("Start" "Second half")))
      ;; Nothing with timestamps.
      (let ((bad (expand-file-name "bad.txt" readq-test--dir)))
        (with-temp-file bad (insert "no times\n"))
        (should-error (readq-set-media-toc book bad) :type 'user-error))
      (readq-set-media-toc book nil t)
      (should-not (readq--get book :toc-text))
      (should-not (readq--media-toc book)))))

;;;; Sections from it

(ert-deftest readq-tocttest-sections-and-play ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let ((book (readq-media-test--book)))
      (with-temp-file (concat (file-name-sans-extension (readq--get book :file)) ".toc")
        (insert readq-tocttest--lecture))
      ;; The table of contents wins over the chapters in the file.
      (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :depth)
                                               (round (plist-get e :start))
                                               (round (plist-get e :end))))
                             (readq--book-outline book))
                     '(("Part 1" 1 5 64) ("Intro" 2 5 20) ("Middle" 2 20 64)
                       ("Part 2" 1 64 90) ("End" 2 64 90))))
      (readq-add-sections book)
      (should (string-match-p "^.*  Middle +0:20–1:04" (buffer-string)))
      (goto-char (point-min))
      (search-forward "Middle")
      (readq-sections-mark 5)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (readq-sections-add))
      (kill-buffer (current-buffer))
      (let ((middle (cl-find "Middle" (readq--books)
                             :key (lambda (x) (readq--get x :heading)) :test #'equal)))
        (should (equal (readq--get middle :title) "Lecture › Part 1 › Middle"))
        (readq-open middle)
        (should (equal (readq-media-test--arg "--start=") "--start=20.000"))
        (should (equal (readq-media-test--arg "--end=") "--end=64.000"))
        (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
        (should (= (readq--get middle :time) 64.0))
        (should (eq (readq--get middle :status) 'finished))))))

(ert-deftest readq-tocttest-open-ended-section ()
  ;; A section whose end was not known plays to the end of the file and
  ;; learns it.
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (last (readq--make-section book (list :title "Last" :depth 1 :start 80.0 :end nil)
                                      10)))
      (readq-open last)
      (should-not (readq-media-test--arg "--end="))
      (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
      (should (= (round (readq--get last :end)) 90))
      (should (eq (readq--get last :status) 'finished)))))

(ert-deftest readq-tocttest-add-directory-skips-toc ()
  ;; lecture.txt next to lecture.opus is its table of contents, not a book.
  (readq-xtest--with-db
    (let ((dir (expand-file-name "talks" readq-test--dir)))
      (make-directory dir t)
      (copy-file (expand-file-name "fixtures/lecture.opus" readq-mtest-dir)
                 (expand-file-name "lecture.opus" dir))
      (with-temp-file (expand-file-name "lecture.txt" dir) (insert "0:05 Intro\n"))
      (with-temp-file (expand-file-name "notes.txt" dir) (insert "My notes\n"))
      (cl-letf (((symbol-function 'readq--mpv-probe) (lambda (&rest _) nil)))
        (should (= (readq-add-directory dir 30) 2)))
      (should-not (readq--book-by-file (expand-file-name "lecture.txt" dir)))
      (should (readq--book-by-file (expand-file-name "notes.txt" dir))))))

(provide 'readq-media-toc-test)
;;; readq-media-toc-test.el ends here
