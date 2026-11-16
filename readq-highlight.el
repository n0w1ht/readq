;;; readq-highlight.el --- Highlights that are not extracts -*- lexical-binding: t; -*-

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
;;
;; Three things can be done with a passage, from lightest to heaviest:
;;
;;   `readq-highlight'     mark it in the book, and nothing more;
;;   `readq-extract-keep'  make it an extract, a note of its own, that
;;                         is not reviewed;
;;   `readq-extract'       make it an extract that comes back for review.
;;
;; A highlight is kept with its book in the queue file, as a plist
;; (:id :text :page :point :edges :key :snippet :tail :length :section
;; :date) in the book's :highlights.  In a PDF it is also an annotation
;; saved into the file, so other viewers show it.  `readq-extract' or
;; `readq-extract-keep' on a highlight, with nothing selected, makes it
;; an extract.

;;; Code:

(require 'readq-extract-tools)

(defvar nov-documents-index)
(declare-function multi-region-selections "ext:multi-region" (&optional sort))

(defcustom readq-highlight-color "#b8f0b0"
  "The color of the highlights `readq-highlight' adds to a PDF.
Nil uses `readq-extract-highlight-color', the color of extracts."
  :type '(choice (const :tag "The color of extracts" nil) color)
  :group 'readq-extracts)

(defface readq-highlight-face
  '((((background dark)) :background "#2f5f3a")
    (t :background "#c9f5c2"))
  "Face of the passages you highlighted in an EPUB, text or web page."
  :group 'readq-extracts)

(defun readq--selection-p ()
  "Return non-nil when something is selected in this buffer."
  (or (use-region-p)
      (and (readq--multi-region-p) (multi-region-selections))
      (readq--viewer-call :selection-p)))

(defun readq--text-cleaner ()
  "Return the function that tidies text selected in this buffer."
  ;; nov.el and eww wrap lines; text files keep their lines.
  (if (derived-mode-p 'nov-mode 'eww-mode) #'readq--unfill #'string-trim))

(defun readq--highlight-record (part n)
  "Return the highlight made of the passage PART, the Nth made just now."
  (append (list :id (format "h%s-%d" (format-time-string "%Y%m%dT%H%M%S") n)
                :text (plist-get part :text)
                :section (plist-get part :section)
                :date (readq--today))
          (readq--part-meta part)))

;;;###autoload
(defun readq-highlight (&optional remove)
  "Highlight the selected text in this book, without making an extract.
In a PDF the highlight is saved into the file, in the color
`readq-highlight-color'.  In an EPUB, a text or a web page, readq
remembers it and shows it whenever you read there.

To make an extract of a highlight later, put point on it (in a PDF,
show its page) and use `readq-extract' or `readq-extract-keep' with
nothing selected.  With a prefix argument (REMOVE), remove the
highlight at point instead.  Return the highlights made."
  (interactive "P")
  (if remove
      (readq-remove-highlight)
    (let* ((book (readq--source-book-here))
           (kind (readq--viewer-get :kind))
           (pdf (eq kind 'pdf))
           (parts (cond
                   (pdf (readq--pdf-parts))
                   ((eq kind 'comic) (user-error "A comic has no text to highlight"))
                   ((or (readq--viewer-get :text)
                        (readq--point-format-p (readq--get book :format)))
                    (readq--text-parts (readq--text-cleaner)))
                   (t (user-error "readq cannot highlight in this kind of buffer"))))
           (parts (cl-remove-if (lambda (p) (or (plist-get p :image)
                                                (string-empty-p (or (plist-get p :text) ""))))
                                parts))
           (n 0) made)
      (unless parts (user-error "The selection has no text"))
      (when pdf
        (unless (readq--viewer-get :highlight)
          (user-error "This PDF viewer cannot save highlights"))
        (let ((readq-extract-highlight-color (or readq-highlight-color
                                                 readq-extract-highlight-color)))
          (readq--viewer-call :highlight parts))
        (readq--viewer-call :clear-selection))
      (dolist (p parts)
        (push (readq--highlight-record p (cl-incf n)) made))
      (setq made (nreverse made))
      (readq--put book :highlights (append (readq--get book :highlights) made))
      (readq--done-selecting)
      (unless pdf (readq--decorate-highlights))
      (readq--save)
      (message "Highlighted%s.  %s here makes it an extract."
               (if (cdr made) (format " %d passages" (length made)) "")
               (substitute-command-keys "\\[readq-extract]"))
      made)))

(defun readq--highlights-on-page (book page)
  "Return the highlights of BOOK on PAGE."
  (cl-remove-if-not (lambda (h) (eql (plist-get h :page) page))
                    (readq--get book :highlights)))

(defun readq--highlight-label (book h)
  "Return a line describing highlight H of BOOK."
  (format "%s: %s"
          (readq--source-description book (plist-get h :page) (plist-get h :section))
          (truncate-string-to-width
           (replace-regexp-in-string "[ \t\n]+" " " (or (plist-get h :text) ""))
           70 nil nil "…")))

(defun readq--read-highlight (prompt book highlights)
  "Read one of HIGHLIGHTS of BOOK with PROMPT."
  (let* ((table (mapcar (lambda (h) (cons (readq--highlight-label book h) h)) highlights))
         (choice (completing-read prompt table nil t)))
    (cdr (assoc choice table))))

(defun readq--highlight-here ()
  "Return the highlight at point as (BOOK . HIGHLIGHT), or nil.
In a PDF, that is the one on the page shown, or one you choose there."
  (when-let* ((book (readq--buffer-book)))
    (let ((h (if (eq (readq--viewer-get :kind) 'pdf)
                 (let ((here (readq--highlights-on-page book (readq--pdf-page-here))))
                   (if (cdr here)
                       (readq--read-highlight "Which highlight on this page? " book here)
                     (car here)))
               (when-let* ((ov (cl-find-if (lambda (o) (overlay-get o 'readq-highlight-id))
                                           (overlays-at (point))))
                           (id (overlay-get ov 'readq-highlight-id)))
                 (cl-find id (readq--get book :highlights)
                          :key (lambda (h) (plist-get h :id)) :test #'equal)))))
      (and h (cons book h)))))

(defun readq--forget-highlight (book h)
  "Take highlight H out of BOOK's list, leaving the book's file alone."
  (readq--put book :highlights (remq h (readq--get book :highlights))))

;;;###autoload
(defun readq-remove-highlight ()
  "Remove the highlight at point; in a PDF, from the file too."
  (interactive)
  (pcase-let ((`(,book . ,h) (or (readq--highlight-here)
                                 (user-error "No highlight here"))))
    (when (and (eq (readq--get book :format) 'pdf) (plist-get h :edges))
      (readq--delete-pdf-highlights
       (list :format 'extract :book (readq--get book :id)
             :page (plist-get h :page) :edges (plist-get h :edges))))
    (readq--forget-highlight book h)
    (readq--decorate-highlights)
    (readq--save)
    (message "Highlight removed")))

(defun readq--extract-highlight-here (ask)
  "Make the highlight at point an extract, if nothing is selected.
With ASK, read its priority.  Return a list of the extract, or nil
when something is selected or no highlight is here.  The highlight in
a PDF stays and is the extract's from now on."
  (when-let* (((not (readq--selection-p)))
              (found (readq--highlight-here)))
    (pcase-let* ((`(,book . ,h) found)
                 (x (readq--create-extract book (plist-get h :text)
                                           :page (plist-get h :page)
                                           :point (plist-get h :point)
                                           :edges (plist-get h :edges)
                                           :section (plist-get h :section)
                                           :ask ask)))
      (readq--forget-highlight book h)
      (readq--decorate-highlights)
      (readq--decorate-extracts)
      (list x))))

(add-hook 'readq-extract-without-selection-functions #'readq--extract-highlight-here)

;;;###autoload
(defun readq-extract-keep (&optional arg)
  "Turn the selected text into an extract that is not reviewed.
Like `readq-extract', ARG included, but the extract stays out of the
queue: it is a note of its own, listed with its book, and never comes
up.  `readq-toggle-finished' on it puts it in the queue after all."
  (interactive "P")
  (let* ((made (readq-extract arg))
         (items (if (keywordp (car made)) (list made) made)))
    (dolist (x items)
      (readq--put x :status 'finished))
    (readq--save)
    (readq--queue-changed)
    (message "%s kept as %s, out of the queue"
             (if (cdr items) (format "%d passages" (length items)) "Passage")
             (if (cdr items) "notes" "a note"))
    made))

;;;###autoload
(defun readq-find-highlight (&optional all)
  "Choose a highlight and show it in its book.
Those of the book here; with a prefix argument (ALL), or outside a
book, those of every book.  Your bookmark in the book does not move."
  (interactive "P")
  (let* ((here (and (not all) (readq--buffer-book)))
         (table (mapcan (lambda (book)
                          (mapcar (lambda (h)
                                    (cons (readq--highlight-label book h) (cons book h)))
                                  (readq--get book :highlights)))
                        (if here (list here) (readq--books))))
         (choice (if table
                     (completing-read "Highlight: " table nil t)
                   (user-error "No highlights%s" (if here " in this book" ""))))
         (found (cdr (assoc choice table))))
    (readq--visit-location (car found) (plist-get (cdr found) :page)
                           (plist-get (cdr found) :point)
                           (plist-get (cdr found) :snippet))))

(defun readq--decorate-highlights ()
  "Show the highlights of this book in its buffer.
For an EPUB, those of the current chapter.  PDFs have their own."
  (remove-overlays (point-min) (point-max) 'readq-highlight t)
  (when-let* ((book (readq--buffer-book))
              (format (readq--get book :format))
              ((or (eq format 'epub) (readq--point-format-p format))))
    (dolist (h (readq--get book :highlights))
      (when (or (not (eq format 'epub))
                (eql (plist-get h :page) nov-documents-index))
        (when-let* ((m (readq--find-text (plist-get h :snippet) (plist-get h :point))))
          (let ((ov (make-overlay (car m)
                                  (max (cdr m)
                                       (readq--passage-end (car m) h
                                                           (memq format '(epub html)))))))
            (overlay-put ov 'readq-highlight t)
            (overlay-put ov 'readq-highlight-id (plist-get h :id))
            (overlay-put ov 'face 'readq-highlight-face)
            (overlay-put ov 'help-echo
                         (substitute-command-keys
                          "Highlight.  \\[readq-extract] makes it an extract, \\[universal-argument] \\[readq-highlight] removes it"))))))))

(add-hook 'readq-book-display-hook #'readq--decorate-highlights)

(provide 'readq-highlight)

;;; readq-highlight.el ends here
