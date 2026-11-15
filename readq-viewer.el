;;; readq-viewer.el --- The viewers readq reads books in -*- lexical-binding: t; -*-

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
;; A viewer is a major mode that shows a book: pdf-tools, doc-view,
;; nov.el, readq-comic...  What readq needs from a viewer (where am I,
;; go there, what is selected) is a small table of functions, kept in
;; `readq-viewers'.  The rest of readq asks the table and does not
;; name any viewer, so that support for another viewer is one call to
;; `readq-define-viewer'; see readq-pdf-canvas.el for a complete one.
;;
;; Books that are plain text (Org, Markdown, text, and HTML in eww)
;; need no viewer: readq follows point in them, whatever their mode.

;;; Code:

(require 'readq-core)

(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-file-name)
(defvar readq-mode)
(declare-function nov-goto-document "ext:nov" (index))
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function doc-view-last-page-number "doc-view" ())
(declare-function pdf-view-goto-page "ext:pdf-view" (page &optional window))
(declare-function pdf-cache-number-of-pages "ext:pdf-cache" (&optional file-or-buffer))
(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function readq--maybe-enable "readq-book")
(declare-function readq--eww-file "readq-book")

(defvar readq-viewers nil
  "The viewers readq knows, an alist of (NAME . PROPERTIES).
Add to it with `readq-define-viewer', which describes the properties.")

(defun readq-define-viewer (name &rest properties)
  "Tell readq how to read books in the viewer NAME, a symbol.
PROPERTIES is a property list.  If NAME is already defined, the
properties given here are added to it, replacing those of the same
name.  All but :modes are optional; every function is called in the
buffer of the book.

:modes        List of major modes; the viewer is used in buffers
              whose mode is, or derives from, one of them.
:mode-hook    Hook run when such a buffer opens; `readq-mode' looks
              there for books of the queue.
:page-hook    Hook run after the page shown changes, so that readq
              records the new position at once.
:render-hook  Hook run after the text was drawn again, so that readq
              marks the extracts in it again.
:kind         `pdf' for a PDF viewer that can select text and areas,
              `comic' for pages that are pictures.
:text         Non-nil if the buffer holds the text of the book, so
              that passages are selected with the region.
:file         Function returning the file shown, for viewers whose
              buffers do not visit it.
:position     Function of one argument, the window showing the
              buffer or nil.  Returns a plist with :page and :total,
              and :point and :point-max where point matters.
:goto         Function of one argument, a plist with :page and maybe
              :point, that shows that place.
:page         Function returning the page shown.

A PDF viewer can also give:

:parts            Function returning what is selected, as a list of
                  plists (:text TEXT :page PAGE :edges LIST-OF-EDGES)
                  in reading order, or nil when nothing is.
:selection-p      Function returning non-nil if something is selected.
:clear-selection  Function that unselects everything.
:figure-region    Function returning the area selected for a figure
                  as (PAGE . LIST-OF-EDGES), or nil.
:crop             Function of FILE, PAGE and EDGES returning the PNG
                  data of that area of the page.
:highlight        Function of one argument, the parts being
                  extracted, that highlights them in the PDF and
                  saves it.  It may replace the :edges of a part by
                  those of its highlight.
:delete-highlights  Function of one argument, a list of plists with
                  :page and :edges, that deletes the highlights
                  there and saves the PDF.  Returns how many.

Edges are (LEFT TOP RIGHT BOTTOM), relative to the page, from 0 to 1."
  (declare (indent 1))
  (let ((cell (assq name readq-viewers)))
    (if (not cell)
        (setq readq-viewers (append readq-viewers (list (cons name properties))))
      (let ((plist (copy-sequence (cdr cell))))
        (while properties
          (setq plist (plist-put plist (pop properties) (pop properties))))
        (setcdr cell plist))))
  (when-let* (((bound-and-true-p readq-mode))
              (hook (plist-get (cdr (assq name readq-viewers)) :mode-hook)))
    (add-hook hook #'readq--maybe-enable))
  name)

(defun readq--viewer-here ()
  "Return the viewer of the current buffer as (NAME . PROPERTIES), or nil."
  (cl-find-if (lambda (viewer)
                (apply #'derived-mode-p (plist-get (cdr viewer) :modes)))
              readq-viewers))

(defun readq--viewer-get (property)
  "Return PROPERTY of the viewer of the current buffer, or nil."
  (plist-get (cdr (readq--viewer-here)) property))

(defun readq--viewer-call (property &rest args)
  "Call the function PROPERTY of this buffer's viewer with ARGS.
Return nil if the buffer has no viewer, or the viewer no such function."
  (when-let* ((fn (readq--viewer-get property)))
    (apply fn args)))

(defun readq--viewer-hooks (property)
  "Return the hooks that the viewers give as PROPERTY."
  (delq nil (mapcar (lambda (viewer) (plist-get (cdr viewer) property))
                    readq-viewers)))

(defun readq--viewer-buffer-visiting (file property)
  "Return a buffer showing FILE whose viewer has PROPERTY, or nil."
  (cl-find-if (lambda (buf)
                (with-current-buffer buf
                  (and buffer-file-name
                       (readq--viewer-get property)
                       (readq--same-file-p (readq--normalize-file buffer-file-name)
                                           file))))
              (buffer-list)))

;;;; The viewers that come with Emacs or that readq has always known

(readq-define-viewer 'pdf-tools
  :modes '(pdf-view-mode)
  :mode-hook 'pdf-view-mode-hook
  :page-hook 'pdf-view-after-change-page-hook
  :kind 'pdf
  :position (lambda (win)
              (list :page (image-mode-window-get 'page win)
                    :total (ignore-errors (pdf-cache-number-of-pages))))
  :goto (lambda (pos)
          (pdf-view-goto-page (plist-get pos :page)
                              (get-buffer-window (current-buffer) t)))
  :page (lambda () (image-mode-window-get 'page)))

(readq-define-viewer 'doc-view
  :modes '(doc-view-mode)
  :mode-hook 'doc-view-mode-hook
  :position (lambda (win)
              (list :page (image-mode-window-get 'page win)
                    :total (let ((n (ignore-errors (doc-view-last-page-number))))
                             (and (integerp n) (> n 0) n))))
  :goto (lambda (pos) (doc-view-goto-page (plist-get pos :page)))
  :page (lambda () (image-mode-window-get 'page)))

(readq-define-viewer 'comic
  :modes '(readq-comic-mode)
  :mode-hook 'readq-comic-open-hook
  :page-hook 'readq-comic-page-change-hook
  :kind 'comic
  :file #'readq-comic-current-file
  :position (lambda (_win)
              (list :page (readq-comic-current-page)
                    :total (readq-comic-page-count)))
  :goto (lambda (pos) (readq-comic-show-page (plist-get pos :page)))
  :page #'readq-comic-current-page)

(readq-define-viewer 'nov
  :modes '(nov-mode)
  :mode-hook 'nov-mode-hook
  :render-hook 'nov-post-html-render-hook
  :text t
  :file (lambda () (bound-and-true-p nov-file-name))
  :position (lambda (win)
              (list :page nov-documents-index
                    :point (if win (window-point win) (point))
                    :point-max (point-max)
                    :total (and (bound-and-true-p nov-documents)
                                (length nov-documents))))
  :goto (lambda (pos)
          (let ((page (plist-get pos :page))
                (point (plist-get pos :point)))
            (unless (eql page nov-documents-index)
              (nov-goto-document page))
            (goto-char (max (point-min) (min (or point (point-min)) (point-max))))
            (when-let* ((win (get-buffer-window (current-buffer) t)))
              (set-window-point win (point))))))

(readq-define-viewer 'eww
  :modes '(eww-mode)
  :file (lambda () (readq--eww-file)))

(provide 'readq-viewer)

;;; readq-viewer.el ends here
