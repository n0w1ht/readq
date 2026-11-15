;;; readq-book.el --- Book buffers, sessions and the commands to add and read books -*- lexical-binding: t; -*-

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

(require 'readq-core)

(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-file-name)
(declare-function readq--read-caption "readq-extract")
(declare-function readq--create-figure "readq-extract")
(declare-function readq--source-book-here "readq-extract")
(declare-function readq--subset-string "readq-sections")
(declare-function readq--subset-items "readq-sections")
(declare-function readq--budget-string "readq-plan")
(declare-function readq--budget-allows-p "readq-plan")
(declare-function readq--tags-string-of "readq-sections")
(declare-function readq--next-in-subset "readq-sections")
(declare-function readq--finish-external-session "readq-sumatra")
(declare-function readq--finish-review "readq-extract")
(declare-function readq--deadline-message "readq-plan")
(declare-function readq--deadline-needed-p "readq-plan")
(declare-function readq--leave-section "readq-sections")
(declare-function readq--open-external "readq-sumatra")
(declare-function readq--viewer "readq-sumatra")
(declare-function readq--open-section "readq-sections")
(declare-function readq--open-media "readq-media")
(declare-function readq--media-p "readq-media")
(declare-function readq--open-extract "readq-extract")
(declare-function readq-delete-extract "readq-extract-tools")
(declare-function readq--sync-extracts-of "readq-extract")
(declare-function readq--sections-of "readq-sections")
(declare-function readq--normalize-tags "readq-sections")
(declare-function readq--read-tags "readq-sections")
(declare-function readq--mpv-probe "readq-media")
(declare-function readq--extract-at-point "readq-extract")
(declare-function readq--tags-string "readq-sections")
(declare-function readq--due-string "readq-dashboard")
(declare-function readq--on-kill-review "readq-extract")
(declare-function readq--media-stop "readq-media")
(declare-function readq--media-playing-p "readq-media")
(declare-function readq--schedule-section-jump "readq-sections")
(declare-function readq--decorate-extracts "readq-extract-tools")
(declare-function readq--refresh-dashboard "readq-dashboard")
(declare-function readq--log-reading "readq-plan")
(declare-function nov-goto-document "ext:nov" (index))
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function pdf-canvas-goto-page "ext:pdf-canvas" (page))
(declare-function pdf-view-goto-page "ext:pdf-view" (page &optional window))
(declare-function readq--section-progress "readq-sections")
(declare-function readq--find-text "readq-extract-tools")
(declare-function doc-view-last-page-number "doc-view" ())
(declare-function pdf-canvas-page-count "ext:pdf-canvas" ())
(declare-function pdf-cache-number-of-pages "ext:pdf-cache" (&optional file-or-buffer))
(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function pdf-canvas-current-page "ext:pdf-canvas" ())

;;;; Book buffers

(defvar-local readq--book-id nil
  "Id of the book shown in the current buffer.")
(defvar-local readq--session-seconds 0
  "Active reading seconds in the current session.")
(defvar-local readq--session-start-progress nil
  "Progress of the book when the current session started.")
(defvar-local readq--session-start-page nil
  "Page or chapter of the book when the current session started.")
(defvar-local readq--restoring nil
  "Non-nil while the saved position has not been restored yet.")
(defvar-local readq--section-id nil
  "Id of the section being read in this book buffer, or nil.
While a section is open, positions, progress and reading time go to
the section, and the book's own bookmark is left alone.")
(put 'readq--section-id 'permanent-local t)

(defun readq--current-item (&optional buffer)
  "Return what is being read in BUFFER: the open section, or the book."
  (with-current-buffer (or buffer (current-buffer))
    (or (and readq--section-id (readq--book-by-id readq--section-id))
        (readq--buffer-book))))

(defvar-local readq--peeking nil
  "Non-nil while the buffer shows the source of an extract.
The reading position is not saved then, so looking up an extract does
not move your bookmark.  `readq-open' goes back to the bookmark.")

(defvar readq--external-session nil
  "Plist (:id :start :process :file) of the book read in SumatraPDF, or nil.")
(defvar-local readq--review-id nil
  "Id of the extract being reviewed in this buffer.")
(defvar readq-review-mode)

(defvar readq--inhibit-restore nil
  "When non-nil, enabling `readq-book-mode' does not jump to the saved spot.")

(defun readq--point-format-p (format)
  "Return non-nil for book FORMATs whose position is a buffer position."
  (memq format '(text html)))

(defun readq--page-format-p (format)
  "Return non-nil for book FORMATs read page by page: PDFs and comics."
  (memq format '(pdf comic)))

(declare-function url-filename "url-parse" (cl-x))
(declare-function url-generic-parse-url "url-parse" (url))
(declare-function url-unhex-string "url-util" (str &optional allow-newlines))
(defvar eww-data)

(defun readq--eww-file ()
  "Return the local file shown in the current eww buffer, or nil."
  (when-let* ((url (plist-get (bound-and-true-p eww-data) :url))
              ((string-prefix-p "file:" url)))
    (let* ((file (url-filename (url-generic-parse-url url)))
           ;; file:///C:/... on Windows.
           (file (if (string-match-p "\\`/[A-Za-z]:" file) (substring file 1) file)))
      (if (or (file-exists-p file) (not (string-match-p "%[[:xdigit:]]\\{2\\}" file)))
          file
        (decode-coding-string (url-unhex-string file) 'utf-8)))))

(defun readq--buffer-file (&optional buffer)
  "Return the file shown in BUFFER (default: current buffer)."
  (with-current-buffer (or buffer (current-buffer))
    (or (and (derived-mode-p 'nov-mode) (bound-and-true-p nov-file-name))
        (and (derived-mode-p 'eww-mode) (readq--eww-file))
        (and (derived-mode-p 'readq-comic-mode) (readq-comic-current-file))
        buffer-file-name)))

(defun readq--buffer-book (&optional buffer)
  "Return the book shown in BUFFER (default: current buffer), or nil."
  (with-current-buffer (or buffer (current-buffer))
    (if readq--book-id
        (readq--book-by-id readq--book-id)
      (let ((file (readq--buffer-file)))
        (and file (readq--format file) (readq--book-by-file file))))))

(defun readq--pdf-page-here ()
  "Return the page shown in this PDF buffer, in any of the PDF viewers."
  (if (derived-mode-p 'pdf-canvas-mode)
      (pdf-canvas-current-page)
    (image-mode-window-get 'page)))

(defun readq--buffer-position ()
  "Return the position in the current buffer as a plist, or nil.
Keys are :page, :point, :point-max and :total."
  (let ((win (get-buffer-window (current-buffer) t)))
    (cond
     ((derived-mode-p 'pdf-view-mode)
      (list :page (image-mode-window-get 'page win)
            :total (ignore-errors (pdf-cache-number-of-pages))))
     ((derived-mode-p 'pdf-canvas-mode)
      (list :page (ignore-errors (pdf-canvas-current-page))
            :total (ignore-errors (pdf-canvas-page-count))))
     ((derived-mode-p 'doc-view-mode)
      (list :page (image-mode-window-get 'page win)
            :total (let ((n (ignore-errors (doc-view-last-page-number))))
                     (and (integerp n) (> n 0) n))))
     ((derived-mode-p 'readq-comic-mode)
      (list :page (readq-comic-current-page) :total (readq-comic-page-count)))
     ((derived-mode-p 'nov-mode)
      (list :page nov-documents-index
            :point (if win (window-point win) (point))
            :point-max (point-max)
            :total (and (bound-and-true-p nov-documents)
                        (length nov-documents))))
     ((readq--point-format-p (readq--get (readq--buffer-book) :format))
      ;; In eww, make sure the page shown is still the book: after
      ;; following a link the buffer shows another page.
      (unless (and (derived-mode-p 'eww-mode)
                   (not (equal (readq--buffer-book)
                               (let ((readq--book-id nil)) (readq--buffer-book)))))
        (let* ((pt (if win (window-point win) (point)))
               (headings (readq--headings)))
          (list :page (cl-count-if (lambda (h) (<= (car h) pt)) headings)
                :total (length headings)
                :point pt
                :point-max (point-max)
                :anchor (readq--anchor-at pt))))))))

(defun readq--anchor-at (pos)
  "Return the text at POS, used to find POS again after the text changed."
  (let ((text (string-trim-right (buffer-substring-no-properties
                                  pos (min (point-max) (+ pos 120))))))
    (unless (string-blank-p text) text)))

(defun readq--goto-text (point anchor)
  "Go to ANCHOR, a piece of text, preferring a match near POINT.
Without a match, go to POINT."
  (let ((m (and anchor (readq--find-text anchor point)))
        ;; The match starts at the first word; POINT may have been
        ;; on whitespace before it.
        (lead (if (and anchor (string-match "\\`[ \t\n\r]+" anchor))
                  (match-end 0) 0)))
    (goto-char (cond (m (max (point-min) (- (car m) lead)))
                     (point (max (point-min) (min point (point-max))))
                     (t (point-min))))
    (when (derived-mode-p 'org-mode) (ignore-errors (org-reveal)))
    (when-let* ((win (get-buffer-window (current-buffer) t)))
      (set-window-point win (point)))))

(defun readq--shr-heading-p (face)
  "Return non-nil when FACE (a face or list of faces) is a heading in eww.
The value is the tail of (shr-h1 ... shr-h6) starting at the heading's
face, whose length gives the heading level."
  (cl-some (lambda (f) (and (memq f '(shr-h1 shr-h2 shr-h3 shr-h4))
                            (memq f '(shr-h1 shr-h2 shr-h3 shr-h4 shr-h5 shr-h6))))
           (if (listp face) face (list face))))

(defun readq--clean-heading (text)
  "Return heading TEXT on one line, without Org tags."
  (string-trim (replace-regexp-in-string
                "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*\\'" ""
                (replace-regexp-in-string "[ \t\n]+" " " text))))

(defun readq--outline (&optional ext)
  "Return the headings of the current text or eww buffer.
Each is a list (POS LEVEL TITLE).  EXT is the file extension that
says how headings look; by default the buffer's file's."
  (save-excursion
    (save-restriction
      (widen)
      (let ((ext (downcase (or ext (file-name-extension (or (readq--buffer-file) "")) "")))
            result)
        (cond
         ((derived-mode-p 'eww-mode)
          (let ((pos (point-min)) start level)
            (while (< pos (point-max))
              (let* ((next (or (next-single-property-change pos 'face) (point-max)))
                     (heading (readq--shr-heading-p (get-text-property pos 'face))))
                (cond (heading
                       (unless start
                         (setq start pos
                               level (- 6 (length heading)))))
                      ((and start (not (string-blank-p
                                        (buffer-substring-no-properties pos next))))
                       (push (list start level
                                   (readq--clean-heading
                                    (buffer-substring-no-properties start pos)))
                             result)
                       (setq start nil)))
                (setq pos next)))
            (when start
              (push (list start level
                          (readq--clean-heading
                           (buffer-substring-no-properties start (point-max))))
                    result))))
         ((or (derived-mode-p 'org-mode) (equal ext "org"))
          (goto-char (point-min))
          (while (re-search-forward "^\\(\\*+\\)[ \t]+\\(.*\\)$" nil t)
            (push (list (match-beginning 0) (length (match-string 1))
                        (readq--clean-heading (match-string 2)))
                  result)))
         ((or (derived-mode-p 'markdown-mode) (member ext '("md" "markdown")))
          (goto-char (point-min))
          (while (re-search-forward "^\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t#]*$" nil t)
            (push (list (match-beginning 0) (length (match-string 1))
                        (readq--clean-heading (match-string 2)))
                  result))))
        (nreverse result)))))

(defun readq--headings ()
  "Return the headings of the current text or eww buffer as (POS . TITLE)."
  (mapcar (lambda (h) (cons (nth 0 h) (nth 2 h))) (readq--outline)))

(defun readq--section-at (pos)
  "Return the title of the heading POS is under, or nil."
  (cdr (car (last (cl-remove-if (lambda (h) (> (car h) pos)) (readq--headings))))))

(defun readq--record-position (&optional item)
  "Store the current buffer's position in ITEM.
ITEM defaults to what is being read: the open section, or the book."
  (unless (or readq--restoring readq--peeking)
    (when-let* ((item (or item (readq--current-item)))
                (pos (readq--buffer-position))
                (page (plist-get pos :page)))
      (if (readq--section-p item)
          (let ((done (readq--at-end-p item)))
            (readq--put item :page page :point (plist-get pos :point)
                        :anchor (plist-get pos :anchor))
            (when-let* ((progress (readq--section-progress item pos)))
              (readq--put item :progress progress))
            (when (and (not done) (readq--at-end-p item))
              (message "End of \"%s\".  %s goes on to the next item."
                       (readq--get item :heading)
                       (substitute-command-keys "\\[readq-next]"))))
        (let* ((total (or (plist-get pos :total) (readq--get item :total)))
               (progress (readq--progress-from (readq--get item :format)
                                               page (plist-get pos :point)
                                               (plist-get pos :point-max) total)))
          (readq--put item :page page :point (plist-get pos :point) :total total
                      :anchor (plist-get pos :anchor))
          (when progress (readq--put item :progress progress)))))))

(defun readq--restore-position (pos)
  "Move the current buffer to POS, a plist with :page and :point."
  (let ((page (plist-get pos :page))
        (point (plist-get pos :point)))
    (when page
      (cond
       ((derived-mode-p 'pdf-view-mode)
        (pdf-view-goto-page page (get-buffer-window (current-buffer) t)))
       ((derived-mode-p 'pdf-canvas-mode)
        (pdf-canvas-goto-page page))
       ((derived-mode-p 'doc-view-mode)
        (doc-view-goto-page page))
       ((derived-mode-p 'readq-comic-mode)
        (readq-comic-show-page page))
       ((derived-mode-p 'nov-mode)
        (unless (eql page nov-documents-index)
          (nov-goto-document page))
        (goto-char (max (point-min) (min (or point (point-min)) (point-max))))
        (when-let* ((win (get-buffer-window (current-buffer) t)))
          (set-window-point win (point))))
       ((readq--point-format-p (readq--get (readq--buffer-book) :format))
        (readq--goto-text point (plist-get pos :anchor)))))))

(defun readq--deferred-restore (buffer pos)
  "Restore POS in BUFFER once it has been set up and displayed."
  (when (buffer-live-p buffer)
    (let ((win (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (unwind-protect
            (condition-case err
                (if win
                    (with-selected-window win (readq--restore-position pos))
                  (readq--restore-position pos))
              (error (message "readq: could not restore position: %s"
                              (error-message-string err))))
          (setq readq--restoring nil)
          (readq--record-position)
          (readq--start-session))))))

(defun readq--start-session ()
  "Start a new reading session in the current buffer."
  (let ((book (readq--current-item)))
    (setq readq--session-seconds 0
          readq--session-start-progress (and book (readq--get book :progress))
          readq--session-start-page (and book (readq--get book :page)))))

(defun readq--count-session (item from-page from secs)
  "Record a reading session of ITEM and reschedule it.
FROM-PAGE and FROM are the page and progress at the start of the
session, SECS its length in seconds."
  (readq--put item
              :sessions (1+ (or (readq--get item :sessions) 0))
              :last-read (readq--today)
              :history (cons (list :date (readq--today)
                                   :from-page from-page
                                   :to-page (readq--get item :page)
                                   :from from :to (readq--get item :progress)
                                   :seconds secs)
                             (readq--get item :history)))
  (readq--log-reading 0 1)
  (readq--reschedule item))

(defun readq--add-seconds (item secs)
  "Add SECS of reading time to ITEM, and to its book if ITEM is a section."
  (readq--log-reading secs 0)
  (dolist (it (delete-dups (list item (readq--item-book item))))
    (when it
      (readq--put it :seconds (+ (or (readq--get it :seconds) 0) secs)))))

(defun readq--end-session (&optional force)
  "End the session in the current buffer and save it.
The book is rescheduled when you advanced, read for at least
`readq-min-session-seconds', or FORCE is non-nil.  Return non-nil if
the book was rescheduled."
  (when-let* ((book (readq--current-item)))
    (readq--record-position book)
    (let* ((secs readq--session-seconds)
           (p0 (or readq--session-start-progress 0))
           (p1 (or (readq--get book :progress) 0))
           (moved (or (> (abs (- p1 p0)) 1e-9)
                      (not (equal readq--session-start-page
                                  (readq--get book :page)))))
           (counts (or force moved (>= secs readq-min-session-seconds))))
      (readq--add-seconds book secs)
      (when counts
        (readq--count-session book readq--session-start-page p0 secs))
      (readq--start-session)
      (readq--save)
      (readq--refresh-dashboard)
      counts)))

(defun readq--on-kill ()
  "Save the session when a book buffer is killed."
  (condition-case err
      (readq--end-session)
    (error (message "readq: error while saving session: %S" err))))

(defun readq--lighter ()
  "Return the mode-line lighter for `readq-book-mode'."
  (let ((item (readq--current-item)))
    (if item
        (format " RQ:%s%d%%" (if (readq--section-p item) "§" "")
                (floor (* 100 (or (readq--get item :progress) 0))))
      " RQ")))

(define-minor-mode readq-book-mode
  "Track reading progress of the book in this buffer.
It is turned on automatically by `readq-mode' in buffers visiting a
book of your reading queue."
  :lighter (:eval (readq--lighter))
  (if readq-book-mode
      (let ((book (let ((readq--book-id nil)) (readq--buffer-book))))
        (if (not book)
            (progn (setq readq-book-mode nil)
                   (message "readq: this buffer's file is not in your reading queue"))
          (setq readq--book-id (readq--get book :id))
          (add-hook 'kill-buffer-hook #'readq--on-kill nil t)
          (add-hook 'pdf-view-after-change-page-hook #'readq--record-position nil t)
          (add-hook 'pdf-canvas-after-change-page-hook #'readq--record-position nil t)
          (add-hook 'readq-comic-page-change-hook #'readq--record-position nil t)
          (when (derived-mode-p 'nov-mode)
            (add-hook 'nov-post-html-render-hook #'readq--decorate-extracts nil t))
          (readq--decorate-extracts)
          (readq--start-session)
          (unless readq--inhibit-restore
            (readq--schedule-restore book))))
    (when readq--book-id
      (readq--on-kill))
    (remove-hook 'kill-buffer-hook #'readq--on-kill t)
    (remove-hook 'pdf-view-after-change-page-hook #'readq--record-position t)
    (remove-hook 'pdf-canvas-after-change-page-hook #'readq--record-position t)
    (remove-hook 'readq-comic-page-change-hook #'readq--record-position t)
    (remove-hook 'nov-post-html-render-hook #'readq--decorate-extracts t)
    (setq readq--book-id nil
          readq--restoring nil
          readq--peeking nil)))

(defun readq--schedule-restore (book)
  "Go back to BOOK's saved position once the buffer is ready.
If a section of BOOK is open in this buffer, go to the section instead."
  (if readq--section-id
      (readq--schedule-section-jump)
    (readq--schedule-book-restore book)))

(defun readq--schedule-book-restore (book)
  "Go back to BOOK's own saved position once the buffer is ready."
  (when (and readq-restore-position (readq--get book :page))
    (setq readq--restoring t)
    (run-at-time 0 nil #'readq--deferred-restore (current-buffer)
                 (list :page (readq--get book :page)
                       :point (readq--get book :point)
                       :anchor (readq--get book :anchor)))))

(defvar url-allow-non-local-files)
(declare-function eww "eww" (url &optional new-buffer buffer))
(declare-function org-reveal "org" (&optional siblings))

(defvar readq--eww-jump nil
  "Where to go after the next eww page renders: (:point POINT :anchor TEXT).
Bound around `readq--eww-open' when showing the source of an extract.")

(defvar-local readq--eww-pending-jump nil
  "Like `readq--eww-jump', for an eww buffer that renders later.")
(put 'readq--eww-pending-jump 'permanent-local t)

(defun readq--eww-open (file)
  "Show the HTML FILE in a new eww buffer."
  (require 'eww)
  (let ((url-allow-non-local-files t)
        (url (concat "file://"
                     (and (memq system-type '(windows-nt ms-dos)) "/")
                     (expand-file-name file))))
    (condition-case nil
        (eww url t)
      ;; Emacs 27: eww has no NEW-BUFFER argument.
      (wrong-number-of-arguments (eww url)))))

(defun readq--eww-after-render ()
  "Track queued books shown in eww, in `eww-after-render-hook'.
Starts tracking when a page is a queued book, stops when you follow a
link to another page, and returns to your place when the book page is
shown again (reload, back)."
  (let* ((file (readq--eww-file))
         (book (and file (readq--format file) (readq--book-by-file file)))
         (jump (or readq--eww-jump readq--eww-pending-jump)))
    (setq readq--eww-pending-jump nil)
    (when (and readq-book-mode
               (not (and book (equal (readq--get book :id) readq--book-id))))
      ;; You followed a link away from the book: end its session.
      (readq-book-mode -1))
    (when book
      (cond
       ((not readq-book-mode)
        (let ((readq--inhibit-restore (or jump readq--inhibit-restore)))
          (readq-book-mode 1)))
       ((not (or jump readq--peeking))
        ;; The book was rendered again: go back to your place.
        (readq--schedule-restore book)))
      (when (and jump readq-book-mode)
        (setq readq--peeking t)
        (readq--goto-text (plist-get jump :point) (plist-get jump :anchor)))
      (readq--decorate-extracts))))

(defun readq--eww-after-history (&rest _)
  "Run `readq--eww-after-render' after eww went back or forward."
  (readq--eww-after-render))

(defun readq--maybe-enable ()
  "Enable `readq-book-mode' if the current buffer visits a queued book."
  (when (and (not readq-book-mode)
             (let ((file (readq--buffer-file)))
               (and file (readq--format file)
                    (not (eq (readq--format file) 'media))
                    (readq--book-by-file file))))
    (readq-book-mode 1)))

(defvar kokoro--session)
(defvar kokoro--paused)
(defvar kokoro--process)

(defun readq--kokoro-buffer ()
  "Return the readq buffer Kokoro is reading aloud now, or nil.
That is a book or an extract under review, while Kokoro speaks and is
not paused."
  (when (and (featurep 'kokoro)
             (bound-and-true-p kokoro--session)
             (not (bound-and-true-p kokoro--paused))
             (process-live-p (bound-and-true-p kokoro--process)))
    (cl-find-if (lambda (buf)
                  (and (buffer-live-p buf)
                       (or (buffer-local-value 'readq-book-mode buf)
                           (buffer-local-value 'readq-review-mode buf))))
                (list (plist-get kokoro--session :display)
                      (plist-get kokoro--session :buffer)))))

(defun readq--tick ()
  "Count reading time and save the position of the book being read.
Time counts in the selected window's book or extract unless Emacs has
been idle for `readq-idle-threshold' seconds, and in the one Kokoro is
reading aloud (see `readq-count-listening') whatever you do meanwhile."
  (condition-case err
      (let* ((selected (window-buffer (selected-window)))
             (idle (current-idle-time))
             (active (or (null idle) (< (float-time idle) readq-idle-threshold)))
             (heard (and readq-count-listening (readq--kokoro-buffer))))
        (dolist (buf (delete-dups (list selected heard)))
          (when (and buf
                     (or (buffer-local-value 'readq-book-mode buf)
                         (buffer-local-value 'readq-review-mode buf)))
            (with-current-buffer buf
              (when (or (eq buf heard) active)
                (setq readq--session-seconds
                      (+ readq--session-seconds readq-tick-interval)))
              (when readq-book-mode (readq--record-position)))))
        (when readq--dirty (readq--save)))
    (error (message "readq: %S" err))))

(defun readq--save-all ()
  "Save every open session and the database (for `kill-emacs-hook')."
  (when (readq--media-playing-p) (ignore-errors (readq--media-stop)))
  (dolist (buf (buffer-list))
    (cond ((buffer-local-value 'readq-book-mode buf)
           (with-current-buffer buf (readq--on-kill)))
          ((buffer-local-value 'readq-review-mode buf)
           (with-current-buffer buf (readq--on-kill-review)))))
  (when readq--dirty (readq--save)))

(defvar readq--timer nil
  "Timer running `readq--tick'.")

(defconst readq--mode-hooks
  '(pdf-view-mode-hook pdf-canvas-mode-hook doc-view-mode-hook nov-mode-hook
    find-file-hook readq-comic-open-hook)
  "Hooks where `readq-mode' looks for queued books.
`find-file-hook' covers text books, whatever their major mode.")

;;;###autoload
(define-minor-mode readq-mode
  "Global mode that tracks your reading progress in queued books."
  :global t
  :group 'readq
  (if readq-mode
      (progn
        (dolist (h readq--mode-hooks) (add-hook h #'readq--maybe-enable))
        (add-hook 'eww-after-render-hook #'readq--eww-after-render)
        ;; eww's back and forward redisplay a page without that hook.
        (advice-add 'eww-restore-history :after #'readq--eww-after-history)
        (add-hook 'kill-emacs-hook #'readq--save-all)
        (when (timerp readq--timer) (cancel-timer readq--timer))
        (setq readq--timer (run-with-timer readq-tick-interval readq-tick-interval
                                           #'readq--tick))
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (readq--buffer-file)
              (let ((readq--inhibit-restore t)) (readq--maybe-enable))))))
    (dolist (h readq--mode-hooks) (remove-hook h #'readq--maybe-enable))
    (remove-hook 'eww-after-render-hook #'readq--eww-after-render)
    (advice-remove 'eww-restore-history #'readq--eww-after-history)
    (remove-hook 'kill-emacs-hook #'readq--save-all)
    (when (timerp readq--timer) (cancel-timer readq--timer))
    (setq readq--timer nil)
    (readq--save-all)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when readq-book-mode (readq-book-mode -1))))))

;;;; Selecting books

(defun readq--book-label (book)
  "Return a completion candidate describing BOOK."
  (format "%-50s P%-3d %5s  %s"
          (truncate-string-to-width
           (concat (cond ((readq--extract-p book) "[extract] ")
                         ((readq--section-p book) "[section] ")
                         (t ""))
                   (readq--get book :title))
           50 nil nil "…")
          (round (readq--get book :priority))
          (if (readq--extract-p book)
              ""
            (format "%d%%" (floor (* 100 (or (readq--get book :progress) 0)))))
          (concat (readq--due-string book)
                  (let ((tags (readq--tags-string book)))
                    (if (string-empty-p tags) "" (concat "  " tags))))))

(defun readq--completing-read-book (prompt &optional books)
  "Read a book with PROMPT among BOOKS (default: all books, queue first)."
  (let* ((books (or books
                    (let ((q (readq--queue)))
                      (append q (cl-set-difference (readq--books) q)))))
         (cands (mapcar (lambda (b) (cons (readq--book-label b) b)) books))
         (table (lambda (str pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action cands str pred)))))
    (unless cands (user-error "Your reading queue is empty; add a book with `readq-add-book'"))
    (cdr (assoc (completing-read prompt table nil t) cands))))

(defun readq--target-book (&optional prompt)
  "Return the book at point, in this buffer, or one read with PROMPT."
  (or (and (derived-mode-p 'readq-dashboard-mode)
           (when-let* ((id (tabulated-list-get-id))) (readq--book-by-id id)))
      (readq--extract-at-point)
      (readq--current-item)
      (and readq--external-session
           (readq--book-by-id (plist-get readq--external-session :id)))
      (readq--completing-read-book (or prompt "Book: "))))

(defun readq--read-priority (&optional default)
  "Read a priority from the minibuffer with DEFAULT."
  (let ((p (read-number "Priority (0 = most important, 100 = least): "
                        (or default readq-default-priority))))
    (min 100 (max 0 p))))

;;;; Commands: adding and editing books

(defun readq--guess-title (file)
  "Guess a title from FILE's name."
  (string-trim (replace-regexp-in-string
                "[_.-]+" " " (file-name-sans-extension (file-name-nondirectory file)))))

(defun readq--count-pages (file)
  "Return the number of pages of the PDF FILE, or nil if unknown."
  (or (and (fboundp 'pdf-info-number-of-pages)
           (ignore-errors (pdf-info-number-of-pages file)))
      (and (executable-find "pdfinfo")
           (with-temp-buffer
             (when (eql 0 (ignore-errors
                            (call-process "pdfinfo" nil t nil (expand-file-name file))))
               (goto-char (point-min))
               (when (re-search-forward "^Pages:[ \t]+\\([0-9]+\\)" nil t)
                 (string-to-number (match-string 1))))))))

(defun readq--own-file-p (file)
  "Return non-nil when FILE is an extract note or a flashcards file of readq."
  (and (member (downcase (or (file-name-extension file) "")) '("org" "txt" "md"))
       (file-readable-p file)
       (with-temp-buffer
         (ignore-errors (insert-file-contents file nil 0 4000))
         (goto-char (point-min))
         (re-search-forward
          "^#\\+source:[ \t]+\\[\\[readq:\\|^#\\+READQ_BOOK:\\|^:READQ_ID:\\|^:READQ_CARD_OF:"
          nil t))))

(defun readq--make-book (file priority title)
  "Return a new book plist for FILE with PRIORITY and TITLE."
  (let ((format (readq--format file)))
    (list :id (readq--new-id)
          :file (readq--normalize-file file)
          :title title
          :format format
          :priority priority
          :status 'active
          :added (readq--today)
          :due (readq--today)
          :interval (float readq-initial-interval)
          :page nil :point nil
          :total (pcase format
                   ('pdf (readq--count-pages file))
                   ('comic (readq-comic-count-pages file))
                   ('media (plist-get (if (equal (car readq--known-probe) file)
                                          (cdr readq--known-probe)
                                        (readq--mpv-probe file))
                                      :duration)))
          :progress 0.0
          :sessions 0
          :seconds 0
          :last-read nil
          :history nil)))

;;;###autoload
(defun readq-add-book (file priority &optional title tags)
  "Add FILE to the reading queue with PRIORITY (0 high - 100 low) and TITLE.
TAGS is a list of tags, see `readq-set-tags'."
  (interactive
   (let* ((cur (readq--buffer-file))
          (file (read-file-name "Add book: " nil cur t
                                (and cur (file-name-nondirectory cur))
                                (lambda (f) (or (file-directory-p f) (readq--format f))))))
     (unless (readq--format file)
       (user-error "Not a supported book file: %s" file))
     (when (readq--book-by-file file)
       (user-error "Already in your queue: %s" (file-name-nondirectory file)))
     (when (readq--own-file-p file)
       (user-error "%s holds readq's extracts or flashcards, not a book"
                   (file-name-nondirectory file)))
     (list file
           (readq--read-priority)
           (read-string "Title: " (readq--guess-title file))
           (and readq-ask-tags (readq--read-tags "Tags (optional): ")))))
  (unless (readq--format file)
    (user-error "Not a supported book file: %s" file))
  (when (readq--book-by-file file)
    (user-error "Already in your queue: %s" file))
  (when (readq--own-file-p file)
    (user-error "%s holds readq's extracts or flashcards, not a book" file))
  (let ((book (readq--make-book file priority
                                (if (or (null title) (string-empty-p title))
                                    (readq--guess-title file)
                                  title))))
    (when tags (readq--put book :tags (readq--normalize-tags tags)))
    (setq readq--books (append (readq--books) (list book)))
    (readq--save)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (not readq-book-mode)
                   (readq--buffer-file)
                   (equal (readq--normalize-file (readq--buffer-file))
                          (readq--get book :file)))
          (let ((readq--inhibit-restore t)) (readq-book-mode 1))
          (readq--record-position)
          (readq--start-session))))
    (readq--refresh-dashboard)
    (when (called-interactively-p 'interactive)
      (message "Added \"%s\" with priority %s" (readq--get book :title) priority))
    book))

;;;###autoload
(defvar readq-media-toc-names)

(defun readq-add-directory (dir priority &optional tags)
  "Add every book under DIR that is not queued yet, all with PRIORITY.
They all get TAGS, a list of tags."
  (interactive (list (read-directory-name "Add books from directory: ")
                     (readq--read-priority)
                     (and readq-ask-tags (readq--read-tags "Tags for all of them (optional): "))))
  (let* ((case-fold-search t)
         (re (concat "\\." (regexp-opt (mapcar #'car readq-file-extensions)) "\\'"))
         (files (directory-files-recursively dir re))
         ;; Tables of contents of recordings, e.g. lecture.txt next to
         ;; lecture.mp3, are not books.
         (tocs (cl-loop for f in files
                        when (eq (readq--format f) 'media)
                        append (mapcar (lambda (pattern)
                                         (readq--normalize-file
                                          (format pattern (file-name-sans-extension f))))
                                       readq-media-toc-names)))
         (added 0))
    (dolist (f files)
      (unless (or (readq--book-by-file f) (readq--own-file-p f)
                  (cl-member (readq--normalize-file f) tocs :test #'readq--same-file-p))
        (readq-add-book f priority nil tags)
        (cl-incf added)))
    (message "Added %d book%s from %s" added (if (= added 1) "" "s")
             (abbreviate-file-name dir))
    added))

(defun readq--changed (book fmt &rest args)
  "Save the database after a change to BOOK and report FMT with ARGS."
  (readq--save)
  (readq--refresh-dashboard)
  (apply #'message fmt args)
  book)

(defun readq-set-priority (book priority)
  "Set the PRIORITY of BOOK (0 = most important, 100 = least)."
  (interactive (let ((b (readq--target-book "Set priority of: ")))
                 (list b (readq--read-priority (readq--get b :priority)))))
  (readq--put book :priority (min 100 (max 0 priority)))
  (readq--changed book "Priority of \"%s\" is now %s"
                  (readq--get book :title) (readq--get book :priority)))

(defun readq-priority-up (book)
  "Make BOOK more important by `readq-priority-step'."
  (interactive (list (readq--target-book "Raise priority of: ")))
  (readq-set-priority book (- (readq--get book :priority) readq-priority-step)))

(defun readq-priority-down (book)
  "Make BOOK less important by `readq-priority-step'."
  (interactive (list (readq--target-book "Lower priority of: ")))
  (readq-set-priority book (+ (readq--get book :priority) readq-priority-step)))

(defun readq-reschedule (book days)
  "Schedule BOOK to be read again in DAYS days; DAYS also becomes its interval."
  (interactive (let ((b (readq--target-book "Reschedule: ")))
                 (list b (read-number (format "Read \"%s\" again in how many days? "
                                              (readq--get b :title))
                                      (round (readq--get b :interval))))))
  (readq--put book :interval (float (max days readq-min-interval))
              :due (readq--date-in days))
  (readq--changed book "\"%s\" is now due %s" (readq--get book :title)
                  (readq--get book :due)))

(defun readq-postpone (book &optional days)
  "Postpone BOOK by multiplying its interval by `readq-postpone-factor'.
With a prefix argument, ask for the number of DAYS instead."
  (interactive (let ((b (readq--target-book "Postpone: ")))
                 (list b (and current-prefix-arg
                              (read-number "Postpone by how many days? " 7)))))
  (let ((interval (or days
                      (min (float readq-max-interval)
                           (* readq-postpone-factor (readq--get book :interval))))))
    (readq--put book :interval (float interval)
                :due (readq--date-in (max 1 (round interval))))
    (readq--changed book "\"%s\" postponed until %s" (readq--get book :title)
                    (readq--get book :due))))

(defun readq-toggle-finished (book)
  "Mark BOOK as finished, or back to active if it already is."
  (interactive (list (readq--target-book "Mark finished: ")))
  (readq--put book :status (if (eq (readq--get book :status) 'finished) 'active 'finished))
  (readq--put book :finished-on (and (eq (readq--get book :status) 'finished) (readq--today)))
  (readq--changed book "\"%s\" is now %s" (readq--get book :title)
                  (readq--get book :status)))

(defun readq-toggle-pause (book)
  "Pause BOOK so it is never suggested, or resume it."
  (interactive (list (readq--target-book "Pause/resume: ")))
  (readq--put book :status (if (eq (readq--get book :status) 'paused) 'active 'paused))
  (when (readq--active-p book)
    (readq--put book :due (readq--today)))
  (readq--changed book "\"%s\" is now %s" (readq--get book :title)
                  (readq--get book :status)))

(defun readq-edit-title (book title)
  "Change the TITLE of BOOK."
  (interactive (let ((b (readq--target-book "Rename: ")))
                 (list b (read-string "Title: " (readq--get b :title)))))
  (readq--put book :title title)
  ;; The notes of extracts are named after their title and their book's.
  (readq--sync-extracts-of book t)
  (readq--changed book "Renamed to \"%s\"" title))

(defun readq-relocate (book file)
  "Point BOOK to FILE, e.g. after the file was moved."
  (interactive (let ((b (readq--target-book "Relocate: ")))
                 (list b (read-file-name (format "New location of \"%s\": "
                                                 (readq--get b :title))
                                         nil nil t))))
  (let ((old (readq--get book :file)))
    (readq--put book :file (readq--normalize-file file))
    (when (readq--book-p book)
      (dolist (section (readq--sections-of book t))
        (readq--put section :file (readq--get book :file))))
    (ignore old))
  (readq--changed book "\"%s\" now points to %s" (readq--get book :title)
                  (readq--get book :file)))

(defun readq-remove-book (book)
  "Remove BOOK (or an extract) from the queue.  Book files are not touched.
Removing a book also removes its sections.  An extract is deleted with
its highlight and note, see `readq-delete-extract'; to only take it out
of the queue, dismiss it (`readq-dismiss')."
  (interactive (list (readq--target-book "Remove from queue: ")))
  (if (readq--extract-p book)
      (readq-delete-extract book)
    (readq--remove-book-only book)))

(defun readq--remove-book-only (book)
  "Remove BOOK or section BOOK from the queue, after asking."
  (when (yes-or-no-p (format "Remove %s\"%s\"%s from your reading queue? "
                             (cond ((readq--extract-p book) "extract ")
                                   ((readq--section-p book) "section ")
                                   (t ""))
                             (readq--get book :title)
                             (let ((n (and (readq--book-p book)
                                           (length (readq--sections-of book t)))))
                               (if (and n (> n 0)) (format " and its %d sections" n) ""))))
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (equal readq--book-id (readq--get book :id))
          (setq readq--book-id nil)
          (readq-book-mode -1))))
    (setq readq--books
          (cl-remove-if (lambda (x) (or (eq x book)
                                        (and (readq--section-p x)
                                             (equal (readq--get x :book)
                                                    (readq--get book :id)))))
                        (readq--books)))
    (readq--changed book "Removed \"%s\"" (readq--get book :title))))

;;;; Commands: reading

(defun readq--book-buffer (book)
  "Return a live buffer showing BOOK, or nil.
`find-buffer-visiting' is not enough: nov.el clears the variable
`buffer-file-name'."
  (let ((file (readq--get book :file)))
    (unless (eq (readq--get book :format) 'media)
      (cl-find-if (lambda (buf)
                    (let ((f (readq--buffer-file buf)))
                      (and f (readq--format f)
                           (readq--same-file-p (readq--normalize-file f) file))))
                  (buffer-list)))))

;;;###autoload
(defun readq-open (book)
  "Open BOOK (or an extract) at the position where you left it.
PDFs and comics whose viewer is SumatraPDF (see `readq-set-viewer') open there.
A section opens in its book, where you left the section.
Return non-nil when something was opened."
  (interactive (list (readq--completing-read-book "Read: ")))
  (unless readq-mode (readq-mode 1))
  (cond
   ((readq--extract-p book) (readq--open-extract book))
   ((readq--media-p book) (readq--open-media book))
   ((readq--section-p book) (readq--open-section book))
   (t
    (when (readq--missing-p book)
      (if (y-or-n-p (format "%s not found.  Relocate it? " (readq--get book :file)))
          (readq-relocate book (read-file-name "New location: " nil nil t))
        (user-error "Missing file: %s" (readq--get book :file))))
    (if (eq (readq--viewer book) 'sumatra)
        (readq--open-external book)
      (let* ((file (readq--get book :file))
             (existing (readq--book-buffer book))
             (html (eq (readq--get book :format) 'html)))
        (cond
         ((and (not existing) html) (readq--eww-open file))
         ((not existing) (readq--find-book-file book))
         (t
          (switch-to-buffer existing)
          ;; A section of this book was open here: back to the book.
          (when readq--section-id
            (setq readq--peeking nil)
            (readq--leave-section))
          (when readq--peeking
            ;; Back from looking up an extract: return to the bookmark.
            (setq readq--peeking nil)
            (readq--restore-position (list :page (readq--get book :page)
                                           :point (readq--get book :point)
                                           :anchor (readq--get book :anchor)))
            (readq--start-session))))
        ;; eww may still be loading a new page; its hook takes over.
        (unless (or readq-book-mode (and html (not existing)))
          (let ((readq--inhibit-restore existing)) (readq-book-mode 1))))
      (message "Reading \"%s\" — priority %s, %d%% done"
               (readq--get book :title) (readq--get book :priority)
               (floor (* 100 (or (readq--get book :progress) 0))))
      t))))

(defun readq--finish-book-session (ask-finished)
  "Finish the session in the current book buffer and return the book.
With ASK-FINISHED, offer to mark the book finished when at its end."
  (let ((book (readq--current-item)))
    (readq--end-session t)
    (if (and ask-finished (readq--at-end-p book)
             (y-or-n-p (format "You reached the end of \"%s\".  Mark it as finished? "
                               (readq--get book :title))))
        (readq-toggle-finished book)
      (readq--report-rescheduled book "Session saved"))
    book))

(defun readq--report-rescheduled (item what)
  "Tell the user WHAT happened and when ITEM comes back."
  (let ((days (readq--days-until (readq--get item :due))))
    (message "%s.  \"%s\" comes back in %d day%s (%s)%s"
             what (readq--get item :title) days (if (= days 1) "" "s")
             (readq--get item :due)
             (if (readq--deadline-needed-p item)
                 (concat ".  " (readq--deadline-message item))
               ""))))

(defun readq-finish-session ()
  "Finish the current reading session and reschedule what you read.
This works in a book buffer, in an extract being reviewed, for a
book read in SumatraPDF (its page is read from SumatraPDF), and for
audio or video playing in mpv (which is closed).
Return the book or extract."
  (interactive)
  (cond
   (readq-book-mode (readq--finish-book-session (called-interactively-p 'any)))
   (readq-review-mode (readq--finish-review))
   (readq--external-session (readq--finish-external-session))
   ((readq--media-playing-p) (readq--media-stop))
   (t (user-error "No reading session here; open a book or extract from your queue"))))

(defvar readq-before-suggest-hook nil
  "Hook run before `readq' and `readq-next' look at the queue.
`readq--auto-import-highlights' is on it, so that new PDF highlights
become extracts before the next item is chosen.")

;;;###autoload
(defun readq-next (&optional tags)
  "Finish the current session and open the next thing to read.
The next item is the most important book or extract that is due today.
When nothing is due, offer to read ahead with the one due soonest.

Only items with one of TAGS are considered; by default those of the
focus (`readq-focus'), if any.  With a prefix argument, ask for TAGS:
\"read next, but only from #cardio\".

While a subset is reviewed (`readq-review-subset'), open its next item
instead, due or not and beyond the daily limit."
  (interactive (list (and current-prefix-arg
                          (readq--read-tags "Read next from tags: " nil t))))
  (let* ((cur-buf (and readq-book-mode (current-buffer)))
         (cur (cond (readq-book-mode (readq--finish-book-session nil))
                    (readq-review-mode (readq--finish-review))
                    (readq--external-session (readq--finish-external-session))
                    ((readq--media-playing-p) (readq--media-stop)))))
    (when (and cur (not (readq--extract-p cur)) (readq--active-p cur)
               (readq--at-end-p cur)
               (y-or-n-p (format "You reached the end of \"%s\".  Mark it as finished? "
                                 (readq--get cur :title))))
      (readq-toggle-finished cur))
    (run-hooks 'readq-before-suggest-hook)
    (if (and readq--subset (not tags))
        (when (and (readq--next-in-subset cur)
                   readq-kill-buffer-after-session cur-buf (buffer-live-p cur-buf)
                   (not (eq cur-buf (current-buffer))))
          (kill-buffer cur-buf))
      (let* ((tags (or tags readq--focus))
             (in (if tags (concat " in " (readq--tags-string-of tags)) ""))
             (queue (delq cur (readq--queue t nil tags)))
             opened)
        (cond
         ((null queue)
          (message "Nothing left to read%s.  %s" in
                   (if tags "Clear the focus with `readq-focus'."
                     "Add books with `readq-add-book'.")))
         ((not (readq--budget-allows-p (car queue)))
          (message "Done for today (%s).  Read on with %s, or see the coming days with %s"
                   (readq--budget-string)
                   (substitute-command-keys "\\[readq-next]")
                   (substitute-command-keys "\\[readq-workload]")))
         ((or (readq--due-p (car queue))
              (y-or-n-p (format "Nothing is due today%s.  Read ahead with \"%s\" (due %s)? "
                                in (readq--get (car queue) :title)
                                (readq--get (car queue) :due))))
          (while (and queue (not opened))
            (setq opened (readq-open (pop queue))))
          (when (and readq-kill-buffer-after-session cur-buf (buffer-live-p cur-buf)
                     (not (eq cur-buf (current-buffer))))
            (kill-buffer cur-buf))))))))

;;;###autoload
(defun readq-suggest ()
  "Show which books and extracts you should read next, in order."
  (interactive)
  (let* ((q (readq--queue nil nil readq--focus))
         (due (cl-remove-if-not #'readq--due-p q))
         (in (if readq--focus (concat " in " (readq--tags-string-of readq--focus)) ""))
         (subset (and readq--subset (readq--subset-items))))
    (cond (subset
           (message "Reviewing %s: %s" (readq--subset-string)
                    (mapconcat (lambda (b) (format "\"%s\"" (readq--get b :title)))
                               (cl-subseq subset 0 (min 3 (length subset))) ", ")))
          ((null q) (message "Your reading queue is empty%s." in))
          ((null due)
           (message "Nothing is due today%s.  Next up: \"%s\" on %s"
                    in (readq--get (car q) :title) (readq--get (car q) :due)))
          (t (message "%d due today%s: %s" (length due) in
                      (mapconcat (lambda (b) (format "\"%s\"" (readq--get b :title)))
                                 (cl-subseq due 0 (min 3 (length due))) ", "))))))

;;;; Comics (CBZ and CBR)

;; Comics are shown by readq-comic, in `readq-comic-mode'.  readq tracks
;; their page like a PDF's, through readq-comic's hooks, or opens them
;; in SumatraPDF (see `readq-set-viewer').

(defalias 'readq-open-comic #'readq-comic-open)

(defun readq--figure-from-comic ()
  "Create a figure extract of the comic page shown."
  (let* ((book (readq--source-book-here))
         (page (readq-comic-current-page))
         (data (readq-comic-current-image)))
    (readq--create-figure book (list :data data :type (image-type-from-data data))
                          :page page
                          :caption (readq--read-caption)
                          :ask current-prefix-arg)))

(defun readq--find-book-file (book &optional other-window)
  "Visit the file of BOOK, in OTHER-WINDOW if non-nil.
Comics open in `readq-comic-mode', other files with `find-file'."
  (let ((file (readq--get book :file)))
    (cond ((eq (readq--get book :format) 'comic) (readq-comic-open file other-window))
          (other-window (find-file-other-window file))
          (t (find-file file)))))

(provide 'readq-book)
;;; readq-book.el ends here
