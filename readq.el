;;; readq.el --- Incremental reading queue for books and documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (card-export "0.1.0") (readq-comic "0.1.0"))
;; Keywords: convenience, docs, multimedia

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; readq keeps a queue of the books you are reading incrementally and
;; tells you which one to pick up next.
;;
;; Every book has a priority from 0 (most important) to 100 (least
;; important), in the spirit of SuperMemo's incremental reading.  Each
;; time you finish a reading session the book is rescheduled, at a
;; steady rhythm set by its priority: high-priority books come back
;; daily, low-priority ones about once a week.  Extracts drift further
;; apart instead: their interval is multiplied by a factor that depends
;; on priority.  `readq-next' closes the session in the
;; current book and opens the most important book that is due.
;;
;; Positions are tracked automatically for:
;;   - PDF files in `pdf-view-mode' (pdf-tools) or `doc-view-mode'
;;   - EPUB files in `nov-mode' (nov.el)
;;   - comics (CBZ, CBR) in `readq-comic-mode', one page at a time
;;   - Org, Markdown and plain text files, in whatever mode they open
;;   - HTML files, read in eww
;;
;; Quick start:
;;
;;   (require 'readq)
;;   (readq-mode 1)
;;   (global-set-key (kbd "C-c r") readq-command-map)
;;
;; Then `C-c r a' to add a book, `C-c r l' (or M-x readq) to see your
;; queue and `C-c r n' to read the next book.
;;
;; Extracts: select a passage (pdf-tools, nov.el, or inside another
;; extract) and press `C-c r e'.  The passage is stored as a note of
;; its own, an Org file named and written as Denote does, in one flat
;; folder (~/notes/), and becomes an item of the queue with its own
;; priority and schedule.
;; Highlights saved into PDFs by other viewers, such as SumatraPDF, are
;; imported as extracts too (`C-c r i'; automatic when a PDF changes).
;; A PDF can be set to open in SumatraPDF with `C-c r v'; readq follows
;; your page there.
;;
;; Audio and video: add files like books, or online videos (YouTube) with
;; `C-c r u'.  They play in mpv, which readq starts; your position is
;; saved when mpv closes, Ctrl+b in mpv marks a moment as an extract, and
;; chapters can be chosen as sections.
;;
;; Tags: `C-c r #' tags a book (#cardio, #leisure...); `C-u C-c r n'
;; reads next only from some tags, and `C-c r /' focuses all suggestions
;; on them until cleared.
;;
;; Sections: `C-c r T' lists a book's table of contents (PDF outline,
;; EPUB table of contents, Org/Markdown/HTML headings); the chapters
;; you mark become queue items of their own, with their own priority and
;; schedule, read in the book without moving its bookmark.
;;
;; Flashcards: mark an extract ready with `C-c r c' (add cloze deletions
;; first with `C-c r k' if you like), then `C-c r C' exports all ready
;; extracts to org-srs or Anki.  After editing exported extracts,
;; `C-c r U' updates their Anki cards.

;;; Code:

(require 'readq-highlight)
(require 'readq-draft)
(require 'readq-relearn)
(require 'readq-kokoro)
(require 'readq-pdf-canvas)

(defvar readq-figures-directory)

(defconst readq-version "0.2.0"
  "The version of readq.  CHANGELOG.md says what changed in each.")
;;;; The manual

(defconst readq--doc-directory
  (expand-file-name "doc" (file-name-directory (or load-file-name buffer-file-name "")))
  "The folder of readq's Info manual.")

(declare-function info-initialize "info")
(defvar Info-directory-list)

(defun readq--add-manual ()
  "Let Info find readq's manual, so that C-h R readq shows it."
  (when (file-exists-p (expand-file-name "readq.info" readq--doc-directory))
    (info-initialize)
    (add-to-list 'Info-directory-list readq--doc-directory t)))

(with-eval-after-load 'info (readq--add-manual))

;;;###autoload
(defun readq-manual ()
  "Show readq's manual."
  (interactive)
  (require 'info)
  (readq--add-manual)
  (info "readq"))

;;;; Setup check

;; `readq-doctor' looks at everything readq relies on outside Emacs
;; (SumatraPDF, mpv, epdfinfo, PowerShell, Anki...) and says, for each,
;; whether it was found and what to do if not.  Checks for things you
;; don't use are reported as notes, not problems.

(defvar pdf-info-epdfinfo-program)
(defvar nov-unzip-program)
(declare-function pdf-info-check-epdfinfo "ext:pdf-info" (&optional interactive))

(defun readq--doctor-writable (dir)
  "Return nil if DIR is, or can be made, a writable directory, else a reason."
  (let ((dir (expand-file-name dir)))
    (cond ((file-directory-p dir)
           (unless (file-writable-p (expand-file-name "readq-probe" dir))
             "not writable"))
          ((file-exists-p dir) "is a file, not a directory")
          (t (let ((parent (file-name-directory (directory-file-name dir))))
               (while (and parent (not (file-exists-p parent))
                           (not (equal parent (file-name-directory
                                               (directory-file-name parent)))))
                 (setq parent (file-name-directory (directory-file-name parent))))
               (unless (and parent (file-writable-p parent))
                 "cannot be created"))))))

(defun readq--doctor-program-version (program &rest args)
  "Return the first line PROGRAM prints when run with ARGS, or nil."
  (ignore-errors
    (with-temp-buffer
      (when (eql 0 (apply #'call-process program nil t nil args))
        (goto-char (point-min))
        (string-trim (buffer-substring (point) (line-end-position)))))))

(defvar readq--doctor-results nil
  "The checks collected so far, newest first, while the setup check runs.")

(defvar readq--doctor-items nil
  "The items of the queue file, while the setup check runs.")

(defvar readq--doctor-db-data nil
  "What the queue file holds, while the setup check runs; nil if unreadable.")

(defvar readq-doctor-functions
  '(readq--doctor-database readq--doctor-files readq--doctor-pdf
                           readq--doctor-epub readq--doctor-comics readq--doctor-sumatra
                           readq--doctor-media readq--doctor-search readq--doctor-clipboard
                           readq--doctor-cards readq--doctor-icons)
  "Functions that each check one part of readq's setup.
They are called in order, without arguments, by `readq-doctor', and
report what they find with `readq--doctor-add'.  A package that
adds to readq can add its own check here.")

(defun readq--doctor-add (status topic fmt &rest args)
  "Report a finding of the setup check.
STATUS is `ok', `warn' (something you use may not work), `fail'
\(something you use will not work) or `info' (not needed for what
you read now, or nothing to check).  TOPIC names what was checked;
FMT and ARGS, as for `format', say what was found."
  (push (list status topic (apply #'format fmt args)) readq--doctor-results))

(defun readq--doctor-windows-p ()
  "Non-nil on Windows."
  (and (memq system-type '(windows-nt ms-dos cygwin)) t))

(defun readq--doctor-uses (pred)
  "Non-nil if PRED holds for an item of the queue being checked."
  (cl-some pred readq--doctor-items))

(defun readq--doctor-reads-p (format)
  "Non-nil if the queue being checked has an item of FORMAT."
  (readq--doctor-uses (lambda (b) (eq (readq--get b :format) format))))

(defun readq--doctor-sumatra-used-p ()
  "Non-nil if a PDF of the queue being checked is read in SumatraPDF."
  (or (eq readq-default-pdf-viewer 'sumatra)
      (readq--doctor-uses (lambda (b)
                            (and (eq (readq--get b :format) 'pdf)
                                 (memq (readq--get b :viewer) '(sumatra okular)))))))

(defun readq--doctor-database ()
  "Check the queue file and its backups."
  (let* ((db (expand-file-name readq-db-file))
         (items readq--doctor-items))
    (cond ((not (file-exists-p db))
           (readq--doctor-add (if (readq--backups) 'fail 'info) "Database"
                              "%s does not exist yet%s" (abbreviate-file-name db)
                              (if (readq--backups)
                                  "; there are backups, see M-x readq-restore-backup"
                                "; it is created when you add a book")))
          ((not readq--doctor-db-data)
           (readq--doctor-add 'fail "Database" "%s cannot be read; restore a backup with M-x readq-restore-backup"
                              (abbreviate-file-name db)))
          (t (readq--doctor-add 'ok "Database" "%s: %s"
                                (abbreviate-file-name db) (readq--count-books-extracts items))))
    (when-let* ((why (readq--doctor-writable (file-name-directory db))))
      (readq--doctor-add 'fail "Database" "its directory %s" why))
    (if (not (and readq-backup-count (> readq-backup-count 0)))
        (readq--doctor-add 'warn "Backups" "off; set `readq-backup-count' to keep daily copies")
      (let ((backups (readq--backups))
            (why (readq--doctor-writable (readq--backup-directory))))
        (cond (why (readq--doctor-add 'fail "Backups" "%s %s"
                                      (abbreviate-file-name (readq--backup-directory)) why))
              (backups (readq--doctor-add 'ok "Backups" "%d in %s, newest %s"
                                          (length backups)
                                          (abbreviate-file-name (readq--backup-directory))
                                          (substring (file-name-base (car backups)) 6)))
              (t (readq--doctor-add 'info "Backups" "none yet; one is made in %s on the first save of each day"
                                    (abbreviate-file-name (readq--backup-directory)))))))))

(defun readq--doctor-files ()
  "Check the files of the books, and the folders readq writes to."
  (let ((items readq--doctor-items))
    (let ((missing (cl-remove-if-not
                    (lambda (b) (and (not (readq--extract-p b)) (readq--missing-p b)))
                    items)))
      (if missing
          (readq--doctor-add 'warn "Files" "%d not found: %s%s; press R on them in the dashboard to relocate"
                             (length missing)
                             (mapconcat (lambda (b) (format "\"%s\"" (readq--get b :title)))
                                        (cl-subseq missing 0 (min 3 (length missing))) ", ")
                             (if (> (length missing) 3) ", ..." ""))
        (when items (readq--doctor-add 'ok "Files" "all books found"))))
    (when-let* ((why (readq--doctor-writable (readq--notes-directory))))
      (readq--doctor-add 'fail "Extracts" "the folder of your extracts %s %s"
                         (abbreviate-file-name (readq--notes-directory)) why))
    (let ((old (cl-count-if (lambda (b) (and (readq--extract-p b) (not (readq--note-p b))))
                            items)))
      (when (> old 0)
        (readq--doctor-add 'warn "Extracts"
                           "%d made by an older readq; M-x readq-convert-extracts turns them into notes"
                           old)))
    (when-let* ((why (readq--doctor-writable readq-figures-directory)))
      (readq--doctor-add 'warn "Figures" "`readq-figures-directory' %s %s"
                         (abbreviate-file-name readq-figures-directory) why))))

(defun readq--doctor-pdf ()
  "Check pdf-tools."
  (let ((windows (readq--doctor-windows-p))
        (pdfs (readq--doctor-reads-p 'pdf))
        (sumatra-used (readq--doctor-sumatra-used-p)))
    (cond ((not (locate-library "pdf-tools"))
           (readq--doctor-add (if (and pdfs (not sumatra-used)) 'fail 'info) "pdf-tools"
                              "not installed; needed to read PDFs in Emacs and import highlights"))
          ((not (require 'pdf-info nil t))
           (readq--doctor-add 'fail "pdf-tools" "installed but cannot be loaded"))
          (t
           (let ((err (condition-case err
                          (progn (pdf-info-check-epdfinfo) nil)
                        (error (error-message-string err)))))
             (if err
                 (readq--doctor-add 'fail "pdf-tools" "epdfinfo does not work: %s%s" err
                                    (if windows "; on Windows, build it with M-x pdf-tools-install (needs MSYS2)" ""))
               (readq--doctor-add 'ok "pdf-tools" "epdfinfo works (%s)"
                                  (abbreviate-file-name pdf-info-epdfinfo-program))))))))

(defun readq--doctor-epub ()
  "Check nov.el."
  (let ((windows (readq--doctor-windows-p))
        (epubs (readq--doctor-reads-p 'epub)))
    (cond ((not (locate-library "nov"))
           (readq--doctor-add (if epubs 'fail 'info) "nov.el" "not installed; needed for EPUB books"))
          ((not (require 'nov nil t))
           (readq--doctor-add 'fail "nov.el" "installed but cannot be loaded"))
          ((and (boundp 'nov-unzip-program)
                (not (and nov-unzip-program (executable-find nov-unzip-program))))
           (readq--doctor-add (if epubs 'fail 'warn) "nov.el" "cannot find unzip (`nov-unzip-program')%s"
                              (if windows "; install it, e.g. with scoop install unzip" "")))
          (t (readq--doctor-add 'ok "nov.el" "ready")))))

(defun readq--doctor-comics ()
  "Check the programs that open comics."
  (let ((windows (readq--doctor-windows-p))
        (comics (readq--doctor-uses
                 (lambda (b) (and (eq (readq--get b :format) 'comic)
                                  (eq (readq--viewer b) 'emacs))))))
    (let* ((programs (readq-comic-programs))
           (best (cl-find-if (lambda (p) (memq (car p) '(7z bsdtar unar))) programs)))
      (cond
       (best (readq--doctor-add 'ok "Comics" "%s reads CBZ and CBR" (abbreviate-file-name (cdr best))))
       (programs
        (readq--doctor-add 'warn "Comics" "only %s, which reads %s; 7-Zip reads both%s"
                           (mapconcat (lambda (p) (abbreviate-file-name (cdr p))) programs " and ")
                           (if (cdr programs) "ZIP (CBZ) and RAR (CBR) but not 7z (CB7)"
                             (if (eq (caar programs) 'unzip) "only CBZ" "only CBR"))
                           (if windows " (winget install 7zip.7zip)" "")))
       (t (readq--doctor-add (if comics 'fail 'info) "Comics"
                             "no archiver found; to read CBZ and CBR in Emacs, install 7-Zip%s or set `readq-comic-program'"
                             (if windows " (winget install 7zip.7zip)" "")))))))

(defun readq--doctor-sumatra ()
  "Check SumatraPDF."
  (let ((windows (readq--doctor-windows-p))
        (sumatra-used (readq--doctor-sumatra-used-p)))
    (when (or windows sumatra-used)
      (let ((prog (ignore-errors (readq--sumatra-program))))
        (if (not prog)
            (readq--doctor-add (if sumatra-used 'fail 'info) "SumatraPDF"
                               "not found; install it or set `readq-sumatra-program'")
          (readq--doctor-add 'ok "SumatraPDF" "%s" (abbreviate-file-name prog))
          (let ((settings (readq--sumatra-settings-file)))
            (cond
             ((not settings)
              (readq--doctor-add 'warn "SumatraPDF" "no settings file yet: open any PDF in SumatraPDF and close it, so it writes one; until then readq cannot learn your page"))
             ((with-temp-buffer
                (insert-file-contents settings)
                (re-search-forward "^[ \t]*RememberOpenedFiles[ \t]*=[ \t]*false" nil t))
              (readq--doctor-add 'fail "SumatraPDF" "\"Remember opened files\" is off in SumatraPDF's settings, so it doesn't save your page; turn it on in Settings > Options"))
             (t (readq--doctor-add 'ok "SumatraPDF" "settings %s" (abbreviate-file-name settings))))))))))

(defun readq--doctor-media ()
  "Check mpv and yt-dlp."
  (let ((media (readq--doctor-reads-p 'media))
        (urls (readq--doctor-uses (lambda (b) (readq--url-p (readq--get b :file))))))
    (let ((mpv (ignore-errors (readq--mpv-program))))
      (if (not mpv)
          (readq--doctor-add (if media 'fail 'info) "mpv"
                             "not found; needed for audio and video; install it or set `readq-mpv-program'")
        (let ((version (readq--doctor-program-version mpv "--version")))
          (if version
              (readq--doctor-add 'ok "mpv" "%s (%s)" (car (split-string version " Copyright"))
                                 (abbreviate-file-name mpv))
            (readq--doctor-add 'fail "mpv" "%s does not run" mpv))))
      (let ((ytdl (if readq-mpv-ytdl-path
                      (and (file-executable-p (expand-file-name readq-mpv-ytdl-path))
                           readq-mpv-ytdl-path)
                    (or (executable-find "yt-dlp") (executable-find "youtube-dl")))))
        (if ytdl
            (readq--doctor-add 'ok "yt-dlp" "%s" (abbreviate-file-name ytdl))
          (readq--doctor-add (if urls 'fail 'info) "yt-dlp"
                             "not found; needed for online videos (set `readq-mpv-ytdl-path')"))))))

(defun readq--doctor-search ()
  "Check ripgrep."
  (let ((windows (readq--doctor-windows-p)))
    (let ((rg (executable-find "rg")))
      (cond (rg (readq--doctor-add 'ok "ripgrep" "%s (for C-c r S)" (abbreviate-file-name rg)))
            ((locate-library "consult")
             (readq--doctor-add 'warn "ripgrep" "not found; C-c r S falls back to slower searches; install it%s"
                                (if windows " with: winget install BurntSushi.ripgrep.MSVC" "")))
            (t (readq--doctor-add 'info "ripgrep" "not needed without consult; C-c r S uses multi-occur"))))))

(defun readq--doctor-clipboard ()
  "Check figures from the clipboard."
  (progn
    (cond
     ((eq system-type 'windows-nt)
      (if (not (executable-find "powershell"))
          (readq--doctor-add 'fail "Clipboard" "PowerShell not found; C-c r y cannot read figures from the clipboard")
        (let ((image (ignore-errors (readq--clipboard-image))))
          (if image
              (readq--doctor-add 'ok "Clipboard" "read a %s image of %d bytes from the clipboard"
                                 (plist-get image :type) (length (plist-get image :data)))
            (readq--doctor-add 'info "Clipboard" "PowerShell found; to test figures, copy an image (Ctrl+drag, Ctrl+C in SumatraPDF) and run this again")))))
     ((display-graphic-p)
      (readq--doctor-add 'info "Clipboard" "copy an image and run this again to test C-c r y"))
     (t (readq--doctor-add 'info "Clipboard" "figures from the clipboard need a graphical Emacs")))))

(defun readq--doctor-cards ()
  "Check the flashcard programs."
  (progn
    (when (memq readq-flashcard-backend '(org-srs org-drill ask))
      (if (locate-library "org-srs")
          (readq--doctor-add 'ok "org-srs" "installed")
        (readq--doctor-add (if (eq readq-flashcard-backend 'ask) 'info 'fail) "org-srs"
                           "not installed")))
    (when (memq readq-flashcard-backend '(anki ask))
      (if (eq readq-anki-method 'file)
          (readq--doctor-add 'info "Anki" "cards are written to %s for File > Import" readq-anki-export-file)
        (let ((version (condition-case err (card-export-anki "version")
                         (error (cons 'error (error-message-string err))))))
          (if (integerp version)
              (readq--doctor-add 'ok "Anki" "AnkiConnect %d answers at %s" version card-export-anki-connect-url)
            (readq--doctor-add (if (eq readq-flashcard-backend 'anki) 'warn 'info) "Anki"
                               "AnkiConnect does not answer at %s; start Anki with the AnkiConnect add-on before exporting"
                               card-export-anki-connect-url)))))))

(defun readq--doctor-icons ()
  "Check the icons of the dashboard."
  (let ((windows (readq--doctor-windows-p)))
    (when readq-dashboard-icons
      (cond ((not (locate-library "all-the-icons"))
             (readq--doctor-add 'info "Icons" "all-the-icons is not installed; the dashboard shows text instead"))
            ((not (display-graphic-p))
             (readq--doctor-add 'info "Icons" "shown only in a graphical Emacs"))
            ((not (find-font (font-spec :family "FontAwesome")))
             (readq--doctor-add 'warn "Icons" "fonts missing: run M-x all-the-icons-install-fonts%s"
                                (if windows ", then double-click each downloaded font to install it" "")))
            (t (readq--doctor-add 'ok "Icons" "all-the-icons and its fonts"))))))

(defun readq--doctor-checks ()
  "Check readq's setup.  Return a list of (STATUS TOPIC TEXT).
The checks are those of `readq-doctor-functions'; see
`readq--doctor-add' for the meaning of STATUS."
  (let* ((db (expand-file-name readq-db-file))
         (readq--doctor-db-data (and (file-exists-p db) (readq--read-db-file db)))
         (readq--doctor-items (plist-get readq--doctor-db-data :books))
         (readq--doctor-results nil))
    (readq--doctor-add 'info "Emacs" "%s on %s, readq %s"
                       emacs-version system-type readq-version)
    (run-hooks 'readq-doctor-functions)
    (nreverse readq--doctor-results)))

;;;###autoload
(defun readq-doctor ()
  "Check that the programs and files readq relies on are in place.
Shows a report, with what to do about each problem."
  (interactive)
  (let ((checks (readq--doctor-checks))
        (buf (get-buffer-create "*readq doctor*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (let ((fails (cl-count 'fail checks :key #'car))
              (warns (cl-count 'warn checks :key #'car)))
          (insert (propertize "readq setup check" 'face 'bold) "\n"
                  (cond ((> fails 0)
                         (propertize (format "%d problem%s%s" fails (if (= fails 1) "" "s")
                                             (if (> warns 0) (format ", %d warning%s" warns
                                                                     (if (= warns 1) "" "s"))
                                               ""))
                                     'face 'error))
                        ((> warns 0)
                         (propertize (format "%d warning%s" warns (if (= warns 1) "" "s"))
                                     'face 'warning))
                        (t (propertize "Everything you use is in place" 'face 'success)))
                  "\n\n"))
        (dolist (c checks)
          (pcase-let ((`(,status ,topic ,text) c))
            (insert (pcase status
                      ('ok (propertize "ok  " 'face 'success))
                      ('warn (propertize "!!  " 'face 'warning))
                      ('fail (propertize "XX  " 'face 'error))
                      (_ (propertize "--  " 'face 'shadow)))
                    (propertize (format "%-12s" topic) 'face 'bold)
                    text "\n")))
        (insert "\nPress g to check again.\n")
        (goto-char (point-min)))
      (special-mode)
      (setq-local revert-buffer-function (lambda (&rest _) (readq-doctor))))
    (pop-to-buffer buf)))

;;;; Keymap

;;;###autoload
(defvar readq-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "l" #'readq)
    (define-key map "n" #'readq-next)
    (define-key map "o" #'readq-open)
    (define-key map "s" #'readq-suggest)
    (define-key map "a" #'readq-add-book)
    (define-key map "h" #'readq-manual)
    (define-key map "H" #'readq-highlight)
    (define-key map "K" #'readq-extract-keep)
    (define-key map "J" #'readq-find-highlight)
    (define-key map "Q" #'readq-draft-cards)
    (define-key map "A" #'readq-add-directory)
    (define-key map "f" #'readq-finish-session)
    (define-key map "p" #'readq-set-priority)
    (define-key map "+" #'readq-priority-up)
    (define-key map "-" #'readq-priority-down)
    (define-key map "r" #'readq-reschedule)
    (define-key map "z" #'readq-postpone)
    (define-key map "F" #'readq-toggle-finished)
    (define-key map "x" #'readq-toggle-pause)
    (define-key map "e" #'readq-extract)
    (define-key map "d" #'readq-dismiss)
    (define-key map "g" #'readq-goto-source)
    (define-key map "E" #'readq-visit-extracts)
    (define-key map "i" #'readq-import-highlights)
    (define-key map "I" #'readq-import-all-highlights)
    (define-key map "v" #'readq-set-viewer)
    (define-key map "c" #'readq-mark-ready)
    (define-key map "T" #'readq-add-sections)
    (define-key map "u" #'readq-add-url)
    (define-key map "m" #'readq-media-mark)
    (define-key map "D" #'readq-delete-extract)
    (define-key map "M" #'readq-set-media-toc)
    (define-key map "k" #'readq-cloze)
    (define-key map "C" #'readq-export-cards)
    (define-key map "U" #'readq-update-anki-cards)
    (define-key map "#" #'readq-set-tags)
    (define-key map "/" #'readq-focus)
    (define-key map "b" #'readq-review-subset)
    (define-key map "L" #'readq-workload)
    (define-key map "!" #'readq-set-deadline)
    (define-key map "P" #'readq-extract-figure)
    (define-key map "y" #'readq-extract-figure-from-clipboard)
    (define-key map "?" #'readq-doctor)
    (define-key map "S" #'readq-search)
    (define-key map "j" #'readq-find-extract)
    (define-key map "X" #'readq-stale-extracts)
    (define-key map "=" #'readq-set-priority)
    (define-key map "%" #'readq-stats)
    (define-key map "'" #'readq-edit-extract)
    (define-key map "B" #'readq-restore-backup)
    (define-key map "R" #'readq-read-aloud)
    (define-key map "V" #'readq-save-extracts-audio)
    map)
  "Prefix keymap for readq commands.
Bind it to a key, e.g. (global-set-key (kbd \"C-c r\") readq-command-map).")
;;;###autoload
(fset 'readq-command-map readq-command-map)

(provide 'readq)
;;; readq.el ends here
