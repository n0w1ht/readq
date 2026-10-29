;;; readq-backup-test.el --- Tests for readq backups and setup check -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-backup-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)

(defun readq-bktest--backup (date)
  "Return the backup file for DATE in the test directory."
  (expand-file-name (format "readq-%s.eld" date) (readq--backup-directory)))

(defun readq-bktest--contents (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

;;;; Saving

(ert-deftest readq-bktest-save-is-complete ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    (readq-add-book (readq-test--touch "b.epub") 20)
    (should (file-exists-p readq-db-file))
    (should-not (file-exists-p (concat readq-db-file ".tmp")))
    (should (= (length (plist-get (readq--read-db-file readq-db-file) :books)) 2))))

(ert-deftest readq-bktest-failed-save-keeps-old-database ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    (let ((before (readq-bktest--contents readq-db-file)))
      (readq--put (car (readq--books)) :priority 99)
      (cl-letf (((symbol-function 'readq--db-file-ok-p) (lambda (&rest _) nil)))
        (should-error (readq--save)))
      (should (equal (readq-bktest--contents readq-db-file) before))
      (should-not (file-exists-p (concat readq-db-file ".tmp")))
      (should readq--dirty))))

;;;; Backups

(ert-deftest readq-bktest-daily-backup ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    ;; The first save made the database; there was nothing to back up.
    (should-not (readq--backups))
    (let ((first (readq-bktest--contents readq-db-file)))
      (readq-add-book (readq-test--touch "b.pdf") 10)
      ;; The database as it was before today's first change is kept...
      (should (= (length (readq--backups)) 1))
      (should (equal (readq-bktest--contents (car (readq--backups))) first))
      ;; ...and later saves the same day don't replace it.
      (readq-add-book (readq-test--touch "c.pdf") 10)
      (should (= (length (readq--backups)) 1))
      (should (equal (readq-bktest--contents (car (readq--backups))) first)))))

(ert-deftest readq-bktest-prune ()
  (readq-test--with-db
    (let ((readq-backup-count 3))
      (readq-add-book (readq-test--touch "a.pdf") 10)
      (dolist (d '("2026-10-01" "2026-10-02" "2026-10-03" "2026-10-04" "2026-10-05"))
        (readq--backup-db (readq-test--now d)))
      (should (equal (mapcar #'file-name-base (readq--backups))
                     '("readq-2026-10-05" "readq-2026-10-04" "readq-2026-10-03"))))))

(ert-deftest readq-bktest-backups-off ()
  (readq-test--with-db
    (let ((readq-backup-count 0))
      (readq-add-book (readq-test--touch "a.pdf") 10)
      (readq-add-book (readq-test--touch "b.pdf") 10)
      (should-not (readq--backups)))))

(ert-deftest readq-bktest-backup-directory-option ()
  (readq-test--with-db
    (let ((readq-backup-directory (expand-file-name "elsewhere" readq-test--dir)))
      (readq-add-book (readq-test--touch "a.pdf") 10)
      (readq-add-book (readq-test--touch "b.pdf") 10)
      (should (file-exists-p (readq-bktest--backup (readq--today)))))))

;;;; Restoring

(ert-deftest readq-bktest-unreadable-database ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    (readq--backup-db (readq-test--now "2026-10-01"))
    (with-temp-file readq-db-file (insert "(:version 1 :books (("))
    (setq readq--loaded nil)
    (let ((err (should-error (readq--books))))
      (should (string-match-p "readq-restore-backup" (cadr err))))
    ;; Nothing was saved over the broken file.
    (should-not readq--loaded)))

(ert-deftest readq-bktest-restore ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    (readq--backup-db (readq-test--now "2026-10-01"))
    (readq-add-book (readq-test--touch "b.pdf") 10)
    (should (= (length (readq--books)) 2))
    (should (equal (readq--backup-description (readq-bktest--backup "2026-10-01"))
                   "1 book, 0 extracts"))
    (readq-restore-backup (readq-bktest--backup "2026-10-01"))
    (should (= (length (readq--books)) 1))
    (should (= (length (plist-get (readq--read-db-file readq-db-file) :books)) 1))
    ;; The database before the restore is kept, and is not a daily backup.
    (let ((before (directory-files (readq--backup-directory) t "before-restore")))
      (should (= (length before) 1))
      (should (= (length (plist-get (readq--read-db-file (car before)) :books)) 2)))
    (should-not (cl-some (lambda (f) (string-match-p "before" f)) (readq--backups)))))

(ert-deftest readq-bktest-restore-rejects-broken-backup ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 10)
    (let ((bad (readq-bktest--backup "2026-10-01")))
      (make-directory (file-name-directory bad) t)
      (with-temp-file bad (insert "garbage"))
      (should-error (readq-restore-backup bad) :type 'user-error)
      (should (= (length (readq--books)) 1)))))

;;;; Setup check

(defun readq-bktest--check (topic checks)
  "Return the checks of TOPIC in CHECKS."
  (cl-remove-if-not (lambda (c) (equal (nth 1 c) topic)) checks))

(defmacro readq-bktest--quiet-doctor (&rest body)
  "Run BODY without contacting Anki or reading the clipboard."
  `(let ((readq-flashcard-backend 'org-drill)
         (readq-dashboard-icons nil))
     ,@body))

(ert-deftest readq-bktest-doctor-database ()
  (readq-test--with-db
    (readq-bktest--quiet-doctor
     (should (eq (car (car (readq-bktest--check "Database" (readq--doctor-checks))))
                 'info))
     (readq-add-book (readq-test--touch "a.pdf") 10)
     (let ((db (car (readq-bktest--check "Database" (readq--doctor-checks)))))
       (should (eq (car db) 'ok))
       (should (string-match-p "1 book, 0 extracts" (nth 2 db))))
     (with-temp-file readq-db-file (insert "(oops"))
     (should (eq (car (car (readq-bktest--check "Database" (readq--doctor-checks))))
                 'fail)))))

(ert-deftest readq-bktest-doctor-backups-and-files ()
  (readq-test--with-db
    (readq-bktest--quiet-doctor
     (let ((f (readq-test--touch "gone.pdf")))
       (readq-add-book f 10 "Gone Book")
       (readq-add-book (readq-test--touch "here.pdf") 10)
       (delete-file f))
     (let ((checks (readq--doctor-checks)))
       (should (eq (car (car (readq-bktest--check "Backups" checks))) 'ok))
       (let ((files (car (readq-bktest--check "Files" checks))))
         (should (eq (car files) 'warn))
         (should (string-match-p "Gone Book" (nth 2 files)))))
     (let ((readq-backup-count nil))
       (should (eq (car (car (readq-bktest--check "Backups" (readq--doctor-checks))))
                   'warn))))))

(ert-deftest readq-bktest-doctor-sumatra ()
  (readq-test--with-db
    (readq-bktest--quiet-doctor
     (let* ((prog (readq-test--touch "SumatraPDF.exe"))
            (settings (readq-test--touch "SumatraPDF-settings.txt"))
            (readq-sumatra-program prog)
            (readq-sumatra-settings-file settings)
            (readq-default-pdf-viewer 'sumatra))
       (with-temp-file settings (insert "RememberOpenedFiles = true\nFileStates [\n]\n"))
       (should (cl-every (lambda (c) (eq (car c) 'ok))
                         (readq-bktest--check "SumatraPDF" (readq--doctor-checks))))
       (with-temp-file settings (insert "RememberOpenedFiles = false\n"))
       (should (assq 'fail (readq-bktest--check "SumatraPDF" (readq--doctor-checks))))
       (let ((readq-sumatra-program nil)
             (exec-path nil)
             (process-environment (cons "LOCALAPPDATA" process-environment)))
         (cl-letf (((symbol-function 'file-executable-p) #'ignore))
           (should (equal (mapcar #'car (readq-bktest--check
                                         "SumatraPDF" (readq--doctor-checks)))
                          '(fail)))))))))

(ert-deftest readq-bktest-doctor-mpv ()
  (readq-test--with-db
    (readq-bktest--quiet-doctor
     (let ((readq-mpv-program (expand-file-name "no-such-mpv" readq-test--dir)))
       (should (eq (car (car (readq-bktest--check "mpv" (readq--doctor-checks))))
                   'fail)))
     (when (executable-find "mpv")
       (let ((readq-mpv-program (executable-find "mpv")))
         (should (eq (car (car (readq-bktest--check "mpv" (readq--doctor-checks))))
                     'ok)))))))

(ert-deftest readq-bktest-doctor-report ()
  (readq-test--with-db
    (readq-bktest--quiet-doctor
     (readq-add-book (readq-test--touch "a.pdf") 10)
     (save-window-excursion (readq-doctor))
     (with-current-buffer "*readq doctor*"
       (should (string-match-p "readq setup check" (buffer-string)))
       (should (string-match-p "Database" (buffer-string))))
     (kill-buffer "*readq doctor*"))))

;;;; Files left in ~/.emacs.d by an older readq

(defmacro readq-bktest--with-home (&rest body)
  "Run BODY with HOME and `user-emacs-directory' in a temp directory.
The database and figures options have their default values, in
`home' (the new ~/notes/) and `emacs-d' (the old place)."
  (declare (indent 0))
  `(readq-test--with-db
     (let* ((home (file-name-as-directory (expand-file-name "home" readq-test--dir)))
            (emacs-d (expand-file-name ".emacs.d/" home))
            (process-environment (cons (concat "HOME=" home) process-environment))
            (user-emacs-directory emacs-d)
            (readq-db-file (eval (car (get 'readq-db-file 'standard-value)) t))
            (readq-figures-directory
             (eval (car (get 'readq-figures-directory 'standard-value)) t))
            (readq-backup-directory nil))
       (make-directory emacs-d t)
       ;; HOME really is the temp directory, so ~/notes/ is not yours.
       (should (string-prefix-p home (expand-file-name readq-db-file)))
       ,@body)))

(ert-deftest readq-bktest-defaults-in-notes ()
  (should (equal (eval (car (get 'readq-db-file 'standard-value)) t) "~/notes/readq.eld"))
  (should (equal (eval (car (get 'readq-figures-directory 'standard-value)) t)
                 "~/notes/readq-figures/"))
  (readq-bktest--with-home
    (should (equal (readq--backup-directory) (expand-file-name "notes/readq-backups/" home)))))

(ert-deftest readq-bktest-copy-old-files ()
  (readq-bktest--with-home
    (let ((old-db (expand-file-name "readq.eld" emacs-d)))
      ;; An older readq's queue, backups and figures in ~/.emacs.d/.
      (let ((readq-db-file old-db)
            (readq-figures-directory (expand-file-name "readq-figures/" emacs-d)))
        (readq-add-book (readq-test--touch "a.pdf") 10 "Alpha")
        (readq--save)
        (make-directory (expand-file-name "readq-backups" emacs-d) t)
        (copy-file old-db (expand-file-name "readq-backups/readq-2026-10-01.eld" emacs-d))
        (make-directory readq-figures-directory t)
        (with-temp-file (expand-file-name "fig.png" readq-figures-directory) (insert "png")))
      (setq readq--books nil readq--loaded nil)
      (let ((warned nil))
        (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warned t))))
          (should (equal (mapcar (lambda (b) (readq--get b :title)) (readq--books)) '("Alpha"))))
        (should warned))
      (should (file-exists-p (expand-file-name "notes/readq.eld" home)))
      (should (file-exists-p (expand-file-name "notes/readq-backups/readq-2026-10-01.eld" home)))
      (should (file-exists-p (expand-file-name "notes/readq-figures/fig.png" home)))
      ;; The old files are kept.
      (should (file-exists-p old-db))
      ;; Only once: the new database is used from then on.
      (should-not (readq--copy-old-files)))))

(ert-deftest readq-bktest-copy-old-files-not-when-customized ()
  (readq-bktest--with-home
    (with-temp-file (expand-file-name "readq.eld" emacs-d) (insert "(:books nil)"))
    (let ((readq-db-file (expand-file-name "mine.eld" home)))
      (should-not (readq--copy-old-files))
      (should-not (file-exists-p readq-db-file)))))

(provide 'readq-backup-test)
;;; readq-backup-test.el ends here
