;;; readq-pdf-canvas.el --- Reading PDFs in pdf-canvas -*- lexical-binding: t; -*-

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
;; Everything readq knows about pdf-canvas is in this file: one call
;; to `readq-define-viewer'.  It is also the example to follow for
;; another PDF viewer.

;;; Code:

(require 'readq-extract-tools)

(declare-function pdf-canvas-current-page "ext:pdf-canvas" ())
(declare-function pdf-canvas-page-count "ext:pdf-canvas" ())
(declare-function pdf-canvas-goto-page "ext:pdf-canvas" (page))
(declare-function pdf-canvas-selections "ext:pdf-canvas" ())
(declare-function pdf-canvas-clear-selections "ext:pdf-canvas" ())
(declare-function pdf-canvas-region-image "ext:pdf-canvas" (page edges &optional dpi))
(declare-function pdf-canvas-annotate "ext:pdf-canvas" (type &optional contents color))
(declare-function pdf-canvas-annotations "ext:pdf-canvas" (page))
(declare-function pdf-canvas-delete-annotation "ext:pdf-canvas" (&optional annotation))
(declare-function pdf-canvas-save "ext:pdf-canvas" ())

(defun readq--canvas-figure-region ()
  "Return the area selected for a figure as (PAGE . EDGES-LIST), or nil.
That is what is selected on the page of the selection made last."
  (when-let* ((last (car (sort (copy-sequence (pdf-canvas-selections))
                               (lambda (a b) (> (plist-get a :index)
                                                (plist-get b :index)))))))
    (cons (plist-get last :page)
          (mapcar (lambda (s) (plist-get s :edges))
                  (cl-remove-if-not
                   (lambda (s) (eql (plist-get s :page) (plist-get last :page)))
                   (pdf-canvas-selections))))))

(defun readq--canvas-highlight (parts)
  "Highlight the text PARTS selected in this pdf-canvas buffer.
Each part's :edges becomes the boxes of its highlight, which is how
`readq-delete-extract' finds the highlight again.  The highlights
are saved when the caller saves the buffer."
  (let ((made (condition-case err
                  (pdf-canvas-annotate 'highlight nil readq-extract-highlight-color)
                (error (message "readq: could not highlight (%s)"
                                (error-message-string err))
                       nil))))
    (dolist (p (cl-remove-if (lambda (p) (plist-get p :image)) parts))
      ;; The highlight on the same page that covers the passage most.
      (let ((best (car (sort (cl-remove-if-not
                              (lambda (a) (eql (plist-get a :page) (plist-get p :page)))
                              made)
                             (lambda (a b)
                               (> (readq--edges-overlap (plist-get a :quads)
                                                        (plist-get p :edges))
                                  (readq--edges-overlap (plist-get b :quads)
                                                        (plist-get p :edges))))))))
        (when (and best (plist-get best :quads))
          (plist-put p :edges (plist-get best :quads)))))))

(defun readq--canvas-highlight-and-save (parts)
  "Highlight the text PARTS selected in this pdf-canvas buffer and save."
  (readq--canvas-highlight parts)
  (condition-case err
      (pdf-canvas-save)
    (error (message "readq: could not save the highlight (%s)"
                    (error-message-string err)))))

(defun readq--canvas-delete-highlights (pieces)
  "Delete the highlights at PIECES from this pdf-canvas buffer and save.
Each piece is a plist with :page and :edges.  Return how many were deleted."
  (let ((deleted 0))
    (dolist (p pieces)
      (dolist (a (pdf-canvas-annotations (plist-get p :page)))
        (when (readq--highlight-match-p
               `((page . ,(plist-get a :page))
                 (type . ,(plist-get a :type))
                 (markup-edges . ,(plist-get a :quads))
                 (edges . ,(plist-get a :edges)))
               (plist-get p :page) (plist-get p :edges))
          (pdf-canvas-delete-annotation a)
          (setq deleted (1+ deleted)))))
    (when (> deleted 0) (pdf-canvas-save))
    deleted))

(readq-define-viewer 'pdf-canvas
  :modes '(pdf-canvas-mode)
  :mode-hook 'pdf-canvas-mode-hook
  :page-hook 'pdf-canvas-after-change-page-hook
  :kind 'pdf
  :position (lambda (_win)
              (list :page (ignore-errors (pdf-canvas-current-page))
                    :total (ignore-errors (pdf-canvas-page-count))))
  :goto (lambda (pos) (pdf-canvas-goto-page (plist-get pos :page)))
  :page (lambda () (pdf-canvas-current-page))
  ;; pdf-canvas reports its selections in the form multi-region does.
  :parts (lambda () (readq--selection-parts (pdf-canvas-selections)))
  :selection-p (lambda () (pdf-canvas-selections))
  :clear-selection (lambda () (pdf-canvas-clear-selections))
  :figure-region #'readq--canvas-figure-region
  :crop (lambda (_file page edges)
          (pdf-canvas-region-image page edges readq-figure-dpi))
  :highlight #'readq--canvas-highlight-and-save
  :delete-highlights #'readq--canvas-delete-highlights)

(provide 'readq-pdf-canvas)

;;; readq-pdf-canvas.el ends here
