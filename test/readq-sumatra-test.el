;;; readq-sumatra-test.el --- Tests for reading PDFs in SumatraPDF -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-sumatra-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; SumatraPDF is played by test/fake-sumatra.sh, which writes a settings
;; file the way SumatraPDF does when you close a document.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-sutest--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro readq-sutest--with-sumatra (vars &rest body)
  "Run BODY with an empty database and the fake SumatraPDF.
VARS are extra environment settings for it, such as
\"FAKE_SUMATRA_PAGE=40\".  In BODY, `log' and `settings' are its files."
  (declare (indent 1))
  `(readq-xtest--with-db
     (let* ((log (expand-file-name "sumatra.log" readq-test--dir))
            (settings (expand-file-name "SumatraPDF-settings.txt" readq-test--dir))
            (readq-sumatra-program (expand-file-name "fake-sumatra.sh" readq-sutest--dir))
            (readq-sumatra-settings-file settings)
            (readq-sumatra-poll-interval 0.2)
            (process-environment (append (list (concat "FAKE_SUMATRA_LOG=" log)
                                               (concat "FAKE_SUMATRA_SETTINGS=" settings))
                                         ,vars process-environment)))
       (ignore log settings)
       (unwind-protect (progn ,@body)
         (dolist (proc (process-list))
           (when (string-prefix-p "readq-sumatra" (process-name proc))
             (delete-process proc)))
         (setq readq--external-session nil)
         (when readq--sumatra-timer
           (cancel-timer readq--sumatra-timer)
           (setq readq--sumatra-timer nil))))))

(defun readq-sutest--wait (pred &optional seconds)
  "Wait until PRED returns non-nil, at most SECONDS (default 10)."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun readq-sutest--log (log)
  "Return the argument lines the fake SumatraPDF logged in LOG."
  (if (file-exists-p log)
      (split-string (with-temp-buffer (insert-file-contents log) (buffer-string)) "\n" t)
    nil))

(defun readq-sutest--book (name &optional pages)
  "Add a PDF NAME of PAGES pages (default 200) read in SumatraPDF."
  (let ((book (readq-add-book (readq-test--touch name) 10)))
    (readq--put book :total (or pages 200))
    (readq-set-viewer book 'sumatra)
    book))

;;;; Reading SumatraPDF's settings

(ert-deftest readq-sutest-settings ()
  (readq-test--with-db
    (let ((file (expand-file-name "settings.txt" readq-test--dir)))
      (with-temp-file file
        (insert "Theme = Light\nFileStates [\n\t[\n\t\tFilePath = C:\\Books\\Guyton Physiology.pdf\n"
                "\t\tFavorites [\n\t\t\t[\n\t\t\t\tPageNo = 3\n\t\t\t]\n\t\t]\n"
                "\t\tPageNo = 112\n\t\tZoom = fit width\n\t]\n"
                "\t[\n\t\tFilePath = C:\\Books\\café.pdf\n\t\tPageNo = 7\n\t]\n"
                "\t[\n\t\tFilePath = C:\\Books\\never-read.pdf\n\t]\n]\n"
                "SessionData [\n\t[\n\t\tTabStates [\n\t\t\t[\n"
                "\t\t\t\tFilePath = C:\\Books\\café.pdf\n\t\t\t\tPageNo = 9\n"
                "\t\t\t]\n\t\t]\n\t]\n]\n"))
      ;; Only the documents' own states count, not favorites or tabs.
      (should (equal (readq--sumatra-file-states file)
                     '((:page 112 :file "C:\\Books\\Guyton Physiology.pdf")
                       (:page 7 :file "C:\\Books\\café.pdf")
                       (:page nil :file "C:\\Books\\never-read.pdf"))))
      ;; Windows names, with backslashes, are matched to the book's.
      (let ((readq-sumatra-settings-file file)
            (book (expand-file-name "Books/Gray.pdf" readq-test--dir)))
        (with-temp-file file
          (insert "FileStates [\n\t[\n\t\tFilePath = "
                  (subst-char-in-string ?/ ?\\ book)
                  "\n\t\tPageNo = 112\n\t]\n]\n"))
        (should (= (readq--sumatra-page book) 112))
        (should-not (readq--sumatra-page (expand-file-name "other.pdf" readq-test--dir))))
      ;; Saved before the session started: not the page of this session.
      (let ((readq-sumatra-settings-file file))
        (set-file-times file (time-subtract nil 60))
        (should-not (readq--sumatra-page "/x.pdf" (float-time)))))))

(ert-deftest readq-sutest-finding-sumatra ()
  (let* ((dir (make-temp-file "sumatra" t))
         (local (expand-file-name "local" dir))
         (portable (expand-file-name "portable" dir))
         (readq-sumatra-settings-file nil)
         (process-environment (cons (concat "LOCALAPPDATA=" local) process-environment)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "SumatraPDF" local) t)
          (make-directory portable t)
          (with-temp-file (expand-file-name "SumatraPDF/SumatraPDF.exe" local) (insert "x"))
          (set-file-modes (expand-file-name "SumatraPDF/SumatraPDF.exe" local) #o755)
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
            (let ((readq-sumatra-program nil))
              ;; The installed version.
              (should (equal (readq--sumatra-program)
                             (expand-file-name "SumatraPDF/SumatraPDF.exe" local)))
              (should-not (readq--sumatra-settings-file))
              (with-temp-file (expand-file-name "SumatraPDF/SumatraPDF-settings.txt" local))
              (should (equal (readq--sumatra-settings-file)
                             (expand-file-name "SumatraPDF/SumatraPDF-settings.txt" local))))
            ;; The portable version keeps its settings next to it.
            (let ((readq-sumatra-program (expand-file-name "SumatraPDF.exe" portable)))
              (with-temp-file (expand-file-name "SumatraPDF-settings.txt" portable))
              (should (equal (readq--sumatra-settings-file)
                             (expand-file-name "SumatraPDF-settings.txt" portable))))
            (let ((readq-sumatra-program nil)
                  (process-environment (cons "LOCALAPPDATA" process-environment)))
              (should-error (readq--sumatra-program) :type 'user-error))))
      (delete-directory dir t))))

(ert-deftest readq-sutest-viewer ()
  (readq-xtest--with-db
    (let ((book (readq-add-book (readq-test--touch "a.pdf") 10))
          (epub (readq-add-book (readq-test--touch "a.epub") 10)))
      (should (eq (readq--viewer book) 'emacs))
      (readq-set-viewer book 'sumatra)
      (should (eq (readq--viewer book) 'sumatra))
      ;; Books once set to Okular now open in SumatraPDF.
      (readq--put book :viewer 'okular)
      (should (eq (readq--viewer book) 'sumatra))
      (let ((readq-default-pdf-viewer 'sumatra))
        (should (eq (readq--viewer (readq-add-book (readq-test--touch "b.pdf") 10)) 'sumatra))
        (should (eq (readq--viewer epub) 'emacs))))))

;;;; Sessions

(ert-deftest readq-sutest-closing-saves-the-page ()
  (readq-sutest--with-sumatra '("FAKE_SUMATRA_PAGE=40" "FAKE_SUMATRA_SLEEP=0.5")
    (let* ((book (readq-sutest--book "my book.pdf")))
      (readq--put book :page 12)
      (with-temp-buffer (readq-open book))
      (should (equal (plist-get readq--external-session :id) (readq--get book :id)))
      (should (readq-sutest--wait (lambda () (readq-sutest--log log))))
      (should (equal (readq-sutest--log log)
                     (list (concat "-page 12 " (readq--native-file-name (readq--get book :file))))))
      ;; Closing SumatraPDF ends the session without asking anything.
      (cl-letf (((symbol-function 'read-number) (lambda (&rest _) (error "Asked")))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked"))))
        (should (readq-sutest--wait (lambda () (null readq--external-session)))))
      (should (= (readq--get book :page) 40))
      (should (= (readq--get book :progress) 0.2))
      (should (= (readq--get book :sessions) 1))
      (should-not (readq--due-p book))
      (should-not readq--sumatra-timer)
      ;; The next session starts there.
      (with-temp-buffer (readq-open book))
      (should (readq-sutest--wait (lambda () (= (length (readq-sutest--log log)) 2))))
      (should (string-prefix-p "-page 40 " (cadr (readq-sutest--log log)))))))

(ert-deftest readq-sutest-next-while-open ()
  (readq-sutest--with-sumatra '("FAKE_SUMATRA_SLEEP=30")
    (let* ((book (readq-sutest--book "book.pdf"))
           (other (readq-add-book (readq-test--touch "next.pdf") 20))
           asked)
      (with-temp-buffer (readq-open book))
      ;; SumatraPDF has not saved the page yet: readq asks you to close
      ;; the document there, then reads it.
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (q)
                   (setq asked q)
                   (with-temp-file settings
                     (insert (format "FileStates [\n\t[\n\t\tFilePath = %s\n\t\tPageNo = 77\n\t]\n]\n"
                                     (readq--native-file-name (readq--get book :file)))))
                   t))
                ((symbol-function 'read-number) (lambda (&rest _) (error "Asked for the page")))
                ((symbol-function 'readq-open) (lambda (b) (should (eq b other)) t)))
        (with-temp-buffer (readq-next)))
      (should (string-match-p "close \"book\" there" asked))
      (should-not readq--external-session)
      (should (= (readq--get book :page) 77)))))

(ert-deftest readq-sutest-page-typed-when-unknown ()
  (readq-sutest--with-sumatra '("FAKE_SUMATRA_SLEEP=30")
    (let ((book (readq-sutest--book "book.pdf")))
      (with-temp-buffer (readq-open book))
      (should (readq-sutest--wait (lambda () (readq-sutest--log log))))
      ;; No: type the page instead.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                ((symbol-function 'read-number) (lambda (&rest _) 33)))
        (should (eq (with-temp-buffer (readq-finish-session)) book)))
      (should (= (readq--get book :page) 33)))))

(ert-deftest readq-sutest-window-already-open ()
  ;; With SumatraPDF's ReuseInstance, the document goes to a window
  ;; already open and the process readq started ends at once.
  (readq-sutest--with-sumatra nil
    (let ((book (readq-sutest--book "book.pdf")))
      (with-temp-buffer (readq-open book))
      (should (readq-sutest--wait
               (lambda () (not (process-live-p (plist-get readq--external-session :process))))))
      (accept-process-output nil 0.5)
      ;; The session goes on until SumatraPDF saves the page.
      (should readq--external-session)
      (with-temp-file settings
        (insert (format "FileStates [\n\t[\n\t\tFilePath = %s\n\t\tPageNo = 50\n\t]\n]\n"
                        (readq--native-file-name (readq--get book :file)))))
      (should (readq-sutest--wait (lambda () (null readq--external-session))))
      (should (= (readq--get book :page) 50)))))

(ert-deftest readq-sutest-section ()
  (readq-sutest--with-sumatra '("FAKE_SUMATRA_PAGE=14")
    (let* ((book (readq-sutest--book "ok.pdf"))
           (section (readq-add-section book "Ch" 10 19 5)))
      (with-temp-buffer (readq-open section))
      (should (readq-sutest--wait (lambda () (null readq--external-session))))
      (should (string-prefix-p "-page 10 " (car (readq-sutest--log log))))
      (should (= (readq--get section :page) 14))
      (should (= (readq--get section :progress) 0.5))
      (should-not (readq--get book :page)))))

(ert-deftest readq-sutest-goto-source ()
  (readq-sutest--with-sumatra nil
    (let* ((book (readq-sutest--book "book.pdf"))
           (x (readq--create-extract book "a passage" :page 77))
           launched)
      (cl-letf (((symbol-function 'call-process)
                 (lambda (program _in dest _display &rest args)
                   (should (eq dest 0))
                   (push (cons program args) launched)
                   0)))
        (readq-goto-source x))
      ;; Shown in the window already open, without starting a session.
      (should (equal (car launched)
                     (list readq-sumatra-program "-reuse-instance" "-page" "77"
                           (readq--native-file-name (readq--get book :file)))))
      (should-not readq--external-session))))

(ert-deftest readq-sutest-figure-from-clipboard ()
  (readq-sutest--with-sumatra '("FAKE_SUMATRA_SLEEP=30")
    (let ((book (readq-sutest--book "book.pdf"))
          (readq-ask-figure-caption nil))
      (readq--put book :page 21)
      (with-temp-buffer (readq-open book))
      (cl-letf (((symbol-function 'gui-get-selection)
                 (lambda (_sel type) (and (eq type 'image/png) "\211PNG\r\n\032\nfake")))
                ((symbol-function 'read-number) (lambda (_prompt default) default)))
        (let ((x (with-temp-buffer (call-interactively #'readq-extract-figure))))
          (should (equal (readq--get x :book) (readq--get book :id)))
          (should (= (readq--get x :page) 21)))))))

(provide 'readq-sumatra-test)
;;; readq-sumatra-test.el ends here
