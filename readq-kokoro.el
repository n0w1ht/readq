;;; readq-kokoro.el --- Reading aloud with Kokoro -*- lexical-binding: t; -*-

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

(require 'readq-cards)

(defvar readq-review-mode)

;;;; Reading aloud (Kokoro)

;; readq works with kokoro.el (https://github.com/n0w1ht/kokoro.el), if
;; it is installed: reading aloud starts at readq's bookmark, the
;; listening time counts as reading (`readq-count-listening'), and the
;; extracts due today can be saved as one audio file to listen to away
;; from the computer.

(declare-function kokoro-read-dwim "kokoro" ())
(declare-function kokoro-read-string "kokoro" (string &optional display))
(declare-function kokoro-save-region-audio "kokoro" (beg end output))
(defvar kokoro-audio-format)

(defcustom readq-audio-directory "~/notes/readq-audio/"
  "The folder where `readq-save-extracts-audio' saves its audio files."
  :type 'directory
  :group 'readq-extracts)

(defun readq--require-kokoro ()
  "Load kokoro.el, or signal an error saying it is needed."
  (unless (require 'kokoro nil t)
    (user-error "readq: reading aloud needs kokoro.el (https://github.com/n0w1ht/kokoro.el)")))

(defun readq--spoken-org (text)
  "Return the Org TEXT of an extract's body as plain text to read aloud.
Properties, the Source line, pictures and quote block lines are left
out; links are read by their description."
  (let ((lines '()) (drawer nil))
    (dolist (line (split-string (readq--org-unescape text) "\n"))
      (cond
       (drawer (when (string-match-p "^[ \t]*:END:[ \t]*$" line) (setq drawer nil)))
       ((string-match-p "^[ \t]*:[A-Za-z_-]+:[ \t]*$" line) (setq drawer t))
       ((string-match-p "^[ \t]*\\(Source:\\|#\\+\\)" line))
       ((string-match-p "^[ \t]*\\[\\[\\(file\\|attachment\\):[^]]*\\]\\(\\[[^]]*\\]\\)?\\][ \t]*$"
                        line))
       (t (push line lines))))
    (string-trim
     (replace-regexp-in-string
      "\n\\{3,\\}" "\n\n"
      (replace-regexp-in-string
       "\\[\\[\\(?:[^]]*\\)\\]\\[\\([^]]*\\)\\]\\]" "\\1"
       (replace-regexp-in-string
        "\\[\\[\\(?:file\\|attachment\\):[^]]*\\]\\]" ""
        (replace-regexp-in-string
         "\\[\\[\\([^]]*\\)\\]\\]" "\\1"
         (mapconcat #'identity (nreverse lines) "\n"))))))))

(defun readq--extract-spoken-text (item)
  "Return extract ITEM's title and passage as plain text to read aloud.
Sub-extracts made from it are left out.  The title is left out when
the passage starts with it, as the titles readq makes do."
  (let ((text (readq--extract-body item)))
    (unless text
      (user-error "Cannot find the note of \"%s\"; it may have been deleted"
                  (readq--get item :title)))
    (let* ((title (or (with-current-buffer (readq--extract-buffer item) (readq--note-title))
                      (readq--get item :title)))
           (body (readq--spoken-org text))
           (flat (lambda (s) (replace-regexp-in-string "[ \t\n]+" " " s)))
           (stem (string-trim (string-remove-suffix "…" title))))
      (if (or (string-empty-p stem)
              (string-prefix-p (funcall flat stem) (funcall flat body)))
          body
        (if (string-empty-p body)
            (concat title ".")
          (concat title ".\n\n" body))))))

;;;###autoload
(defun readq-read-aloud ()
  "Read aloud with Kokoro, starting at readq's bookmark.
In a book, go back to where you last were in it (the page of a PDF,
the spot in an EPUB or text) and read on from there; with text
selected, read that.  In an extract under review, read its passage.
The time spent listening counts as reading, see
`readq-count-listening'.  Needs kokoro.el."
  (interactive)
  (readq--require-kokoro)
  (cond
   (readq-review-mode
    (let ((item (or (readq--book-by-id readq--review-id)
                    (user-error "readq: this extract is no longer in the queue"))))
      (kokoro-read-string (readq--extract-spoken-text item) (current-buffer))))
   (readq-book-mode
    (let ((item (readq--current-item)))
      (unless (or (use-region-p)
                  (readq--viewer-call :selection-p))
        (when (and item (readq--get item :page))
          (readq--restore-position (list :page (readq--get item :page)
                                         :point (readq--get item :point)
                                         :anchor (readq--get item :anchor)))))
      (kokoro-read-dwim)))
   (t (user-error "Open a book or an extract with %s first"
                  (substitute-command-keys "\\[readq-open]")))))

(defun readq--due-extracts ()
  "Return the active extracts due today, in the order they are reviewed."
  (let ((readq-queue-extracts t))
    (cl-remove-if-not (lambda (x) (and (readq--extract-p x) (readq--due-p x)))
                      (readq--queue))))

(defun readq--extracts-audio-text (items)
  "Return the text to narrate for extracts ITEMS, one after another.
Extracts that cannot be found are skipped."
  (let ((n 0) (total (length items)) (parts '()))
    (dolist (item items)
      (let ((text (condition-case nil (readq--extract-spoken-text item)
                    (user-error nil))))
        (when (and text (not (string-empty-p text)))
          (setq n (1+ n))
          (push (format "Extract %d of %d.\n\n%s" n total text) parts))))
    (mapconcat #'identity (nreverse parts) "\n\n")))

;;;###autoload
(defun readq-save-extracts-audio (items output)
  "Save the extracts ITEMS, read aloud by Kokoro, as one audio file OUTPUT.
Interactively, these are the extracts due today; with a prefix
argument, ask for a book, section, extract or #tag and take its
extracts (only due ones with `readq-subset-due-only').  The file goes
in `readq-audio-directory', named after the date or the subset.

Each extract is announced (\"Extract 2 of 9\") and read with its title
and passage; sources, pictures and sub-extracts are left out.  Kokoro
narrates in the background.  Saving does not review the extracts: they
stay due until you open them.  Needs kokoro.el."
  (interactive
   (progn
     (readq--require-kokoro)
     (let* ((target (and current-prefix-arg (readq--read-subset-target)))
            (items (if target
                       (cl-remove-if-not #'readq--extract-p (readq--subset-of target))
                     (readq--due-extracts)))
            (name (if target
                      (readq--slug (if (stringp target) target
                                     (readq--get target :title)))
                    "due"))
            (default (expand-file-name
                      (format "extracts-%s-%s.%s" name (readq--today) kokoro-audio-format)
                      readq-audio-directory)))
       (unless items
         (user-error (if target "No extracts to save there" "No extracts are due today")))
       (make-directory readq-audio-directory t)
       (list items
             (expand-file-name
              (read-file-name (format "Save %d extract%s as: " (length items)
                                      (if (= (length items) 1) "" "s"))
                              readq-audio-directory default nil
                              (file-name-nondirectory default)))))))
  (readq--require-kokoro)
  (let ((text (readq--extracts-audio-text items)))
    (when (string-empty-p text)
      (user-error "readq: these extracts have no text to read"))
    (make-directory (file-name-directory output) t)
    (with-temp-buffer
      (insert text)
      (kokoro-save-region-audio (point-min) (point-max) output))
    (message "readq: narrating %d extract%s into %s" (length items)
             (if (= (length items) 1) "" "s") (abbreviate-file-name output))))

(provide 'readq-kokoro)
;;; readq-kokoro.el ends here
