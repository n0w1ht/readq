;;; readq-sumatra.el --- Reading PDFs in SumatraPDF -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
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

;; Part of readq; see readq.el.  Load readq with (require 'readq).

;;; Code:

(require 'readq-book)

(declare-function readq--section-progress "readq-sections")

;;;; External viewer (SumatraPDF)

;; A PDF can be read in SumatraPDF instead of Emacs.  readq starts
;; SumatraPDF at your page and reads the page back from SumatraPDF's own
;; settings file, where it remembers the last page of every document.
;; SumatraPDF writes that file when you close a document or quit, so
;; closing the PDF there ends the session by itself: readq saves the page
;; and reschedules the book.  `readq-next' does the same while it is
;; still open, once SumatraPDF has saved the page.

(defun readq--viewer (book)
  "Return the viewer used for BOOK (or its section): `emacs' or `sumatra'."
  (let* ((book (readq--item-book book))
         (format (and book (readq--get book :format))))
    (if (readq--page-format-p format)
        (let ((viewer (or (readq--get book :viewer)
                          (if (eq format 'comic)
                              readq-default-comic-viewer
                            readq-default-pdf-viewer))))
          ;; Books once set to Okular, which readq no longer supports.
          (if (eq viewer 'okular) 'sumatra viewer))
      'emacs)))

(defun readq-set-viewer (book viewer)
  "Choose the VIEWER (`emacs' or `sumatra') used to read BOOK, a PDF or comic."
  (interactive
   (let ((b (readq--item-book (readq--target-book "Set viewer of: "))))
     (unless (readq--page-format-p (readq--get b :format))
       (user-error "Only PDFs and comics can be read in an external viewer"))
     (list b (intern (completing-read "Read it in: " '("emacs" "sumatra")
                                      nil t nil nil
                                      (symbol-name (readq--viewer b)))))))
  (readq--put book :viewer viewer)
  (readq--changed book "\"%s\" will open in %s" (readq--get book :title)
                  (if (eq viewer 'sumatra) "SumatraPDF" "Emacs")))

(defun readq--sumatra-program ()
  "Return the SumatraPDF executable to run."
  (or readq-sumatra-program
      (executable-find "SumatraPDF")
      (cl-find-if #'file-executable-p
                  (delq nil
                        (list (when-let* ((local (getenv "LOCALAPPDATA")))
                                (expand-file-name "SumatraPDF/SumatraPDF.exe" local))
                              "C:/Program Files/SumatraPDF/SumatraPDF.exe"
                              "C:/Program Files (x86)/SumatraPDF/SumatraPDF.exe"
                              (expand-file-name "~/scoop/apps/sumatrapdf/current/SumatraPDF.exe"))))
      (user-error "Cannot find SumatraPDF; set `readq-sumatra-program' to SumatraPDF.exe")))

(defun readq--sumatra-settings-file ()
  "Return SumatraPDF's settings file, or nil if there is none yet.
The portable version keeps it next to the program, the installed one
in %LOCALAPPDATA%/SumatraPDF/."
  (or readq-sumatra-settings-file
      (cl-find-if #'file-exists-p
                  (delq nil
                        (list (when-let* ((prog (ignore-errors (readq--sumatra-program))))
                                (expand-file-name "SumatraPDF-settings.txt"
                                                  (file-name-directory prog)))
                              (when-let* ((local (getenv "LOCALAPPDATA")))
                                (expand-file-name "SumatraPDF/SumatraPDF-settings.txt"
                                                  local)))))))

(defun readq--sumatra-file-states (file)
  "Return the documents remembered in SumatraPDF's settings FILE.
Each is a plist (:file FILE :page PAGE), from its FileStates list."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (let ((depth 0) in-states state states)
      (while (not (eobp))
        (let ((line (string-trim (buffer-substring-no-properties
                                  (line-beginning-position) (line-end-position)))))
          (cond
           ((string-match "\\`\\([[:alnum:]]+\\) \\[\\'" line)
            (when (and (= depth 0) (equal (match-string 1 line) "FileStates"))
              (setq in-states t))
            (setq depth (1+ depth)))
           ((equal line "[")
            (setq depth (1+ depth))
            (when (and in-states (= depth 2)) (setq state (list :page nil))))
           ((equal line "]")
            (when (and in-states (= depth 2) state (plist-get state :file))
              (push state states))
            (setq depth (max 0 (1- depth)))
            (when (= depth 0) (setq in-states nil)))
           ((and in-states (= depth 2) state
                 (string-match "\\`\\([[:alnum:]]+\\) = \\(.*\\)\\'" line))
            (pcase (match-string 1 line)
              ("FilePath" (plist-put state :file (match-string 2 line)))
              ("PageNo" (plist-put state :page
                                   (string-to-number (match-string 2 line))))))))
        (forward-line 1))
      (nreverse states))))

(defun readq--sumatra-page (file &optional since)
  "Return the page of FILE that SumatraPDF remembers, or nil.
With SINCE (a `float-time'), only if SumatraPDF saved its settings since."
  (when-let* ((settings (readq--sumatra-settings-file))
              ((file-exists-p settings))
              ((or (null since)
                   (>= (float-time (file-attribute-modification-time
                                    (file-attributes settings)))
                       (- since 1)))))
    (let ((state (cl-find-if
                  (lambda (s)
                    (readq--same-file-p
                     (subst-char-in-string ?\\ ?/ (plist-get s :file))
                     (expand-file-name file)))
                  (readq--sumatra-file-states settings))))
      (and state (plist-get state :page) (> (plist-get state :page) 0)
           (plist-get state :page)))))

(defun readq--native-file-name (file)
  "Return FILE as an absolute name in the operating system's syntax."
  (let ((f (expand-file-name file)))
    (if (memq system-type '(windows-nt ms-dos))
        (subst-char-in-string ?/ ?\\ f)
      f)))

(defun readq--sumatra-args (file page)
  "Return SumatraPDF's arguments to open FILE at PAGE."
  (append (and page (list "-page" (number-to-string page)))
          (list (readq--native-file-name file))))

(defun readq--sumatra-launch (file &optional page)
  "Show FILE in SumatraPDF at PAGE, in a window already open if any."
  (apply #'call-process (readq--sumatra-program) nil 0 nil
         "-reuse-instance" (readq--sumatra-args file page)))

(defvar readq--sumatra-timer nil
  "Timer that watches SumatraPDF's settings during a session.")

(defun readq--open-external (book)
  "Open BOOK in SumatraPDF at its saved page and start an external session.
SumatraPDF runs in a window of its own; closing it, or closing the
document in it, ends the session."
  (when (and readq--external-session
             (not (equal (plist-get readq--external-session :id)
                         (readq--get book :id))))
    (readq--finish-external-session))
  (let* ((page (or (readq--get book :page) (readq--get book :start) 1))
         (file (readq--get book :file))
         (proc (make-process :name "readq-sumatra"
                             :command (cons (readq--sumatra-program)
                                            (readq--sumatra-args file page))
                             :connection-type 'pipe
                             :noquery t
                             :sentinel #'readq--sumatra-sentinel)))
    (when readq--sumatra-timer (cancel-timer readq--sumatra-timer))
    (setq readq--external-session (list :id (readq--get book :id) :start (float-time)
                                        :process proc :file file)
          readq--sumatra-timer (run-with-timer readq-sumatra-poll-interval
                                               readq-sumatra-poll-interval
                                               #'readq--sumatra-poll))
    (message "Reading \"%s\" in SumatraPDF from page %d.  Close it there when you are done."
             (readq--get book :title) page))
  t)

(defun readq--sumatra-poll ()
  "End the SumatraPDF session if SumatraPDF saved the page after closing it.
This catches a document closed in a SumatraPDF window that readq did not
start, as when SumatraPDF hands documents to a window already open."
  (let ((session readq--external-session))
    (if (not session)
        (when readq--sumatra-timer
          (cancel-timer readq--sumatra-timer)
          (setq readq--sumatra-timer nil))
      (when (and (not (process-live-p (plist-get session :process)))
                 (readq--sumatra-page (plist-get session :file) (plist-get session :start)))
        (readq--finish-external-session t)))))

(defun readq--sumatra-sentinel (proc _event)
  "End the session when the SumatraPDF PROC readq started closes."
  (let ((session readq--external-session))
    (when (and session (eq (plist-get session :process) proc)
               (not (process-live-p proc)))
      ;; With SumatraPDF's ReuseInstance, the document went to a window
      ;; already open and this process ends at once; the timer then
      ;; waits for SumatraPDF to save the page.
      (when (readq--sumatra-page (plist-get session :file) (plist-get session :start))
        (readq--finish-external-session t)))))

(defun readq--finish-external-session (&optional auto)
  "Save the page reached in SumatraPDF and reschedule the book.
The page is read from SumatraPDF's settings.  When SumatraPDF has not
saved it yet, ask you to close the document there, or for the page.
With AUTO (SumatraPDF was closed), never ask: if the page is not known,
keep the session.  Return the book, or nil."
  (let* ((session readq--external-session)
         (book (readq--book-by-id (plist-get session :id)))
         (file (plist-get session :file))
         (start (plist-get session :start))
         (page (and file (readq--sumatra-page file start))))
    (when (and book (not page) (not auto)
               (process-live-p (plist-get session :process))
               (y-or-n-p (format "SumatraPDF saves your page when you close \"%s\" there.  \
Closed it? " (readq--get book :title))))
      (let ((deadline (+ (float-time) 3)))
        (while (and (not (setq page (readq--sumatra-page file start)))
                    (< (float-time) deadline))
          (accept-process-output nil 0.2))))
    (when (or page (not auto) (not book))
      (setq readq--external-session nil)
      (when readq--sumatra-timer
        (cancel-timer readq--sumatra-timer)
        (setq readq--sumatra-timer nil))
      (when book
        (let* ((section (readq--section-p book))
               (total (if section
                          (readq--get book :end)
                        (or (readq--get book :total)
                            (readq--count-pages (readq--get book :file)))))
               (from-page (readq--get book :page))
               (from (or (readq--get book :progress) 0))
               (page (or page
                         (read-number (format "Page you stopped at in \"%s\"%s: "
                                              (readq--get book :title)
                                              (if total (format " (%s %d)"
                                                                (if section "section ends at" "of")
                                                                total)
                                                ""))
                                      (or from-page (readq--get book :start) 1))))
               (secs (min (round (- (float-time) start))
                          (* 60 readq-external-max-session-minutes))))
          (readq--put book :page page :point nil)
          (unless section (readq--put book :total total))
          (when-let* ((progress (if section
                                   (readq--section-progress book (list :page page))
                                 (readq--progress-from 'pdf page nil nil total))))
            (readq--put book :progress progress))
          (readq--add-seconds book secs)
          (readq--count-session book from-page from secs)
          (readq--save)
          (readq--queue-changed)
          (readq--report-rescheduled
           book (format "Session saved at page %d%s" page
                        (if auto (substitute-command-keys
                                  " (\\[readq-next] for the next item)")
                          "")))
          book)))))

;; How a session in SumatraPDF is finished.
(readq--add-finisher 20 (lambda () readq--external-session)
                     #'readq--finish-external-session)

(provide 'readq-sumatra)
;;; readq-sumatra.el ends here
