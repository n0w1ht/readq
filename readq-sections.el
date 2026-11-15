;;; readq-sections.el --- Sections, tags and subset review -*- lexical-binding: t; -*-

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

(require 'readq-sumatra)

(defvar nov-documents)
(declare-function readq--extract-at-point "readq-extract")
(declare-function readq--dashboard-item "readq-dashboard")
(declare-function readq--chapter-p "readq-dashboard")
(declare-function readq--extract-chapter-index "readq-dashboard")
(declare-function readq--book-chapters "readq-dashboard")
(declare-function readq--refresh-dashboard "readq-dashboard")
(declare-function readq--media-outline "readq-media")
(declare-function pdf-info-number-of-pages "ext:pdf-info" (&optional file-or-buffer))
(declare-function readq--pdf-info-available-p "readq-extract-tools")
(declare-function readq--format-time "readq-media")

;;;; Sections

;; A section is a chapter (or any part) of a book that you put in the
;; queue on its own, with its own priority and schedule.  It is read in
;; the book's buffer: while a section is open there, positions, progress
;; and reading time go to the section and the book's own bookmark stays
;; where it was.
;;
;; Where a section is:
;;   PDF          pages :start to :end
;;   EPUB         documents (nov.el chapters) :start to :end
;;   text, HTML   the heading :heading at :level, its :occurrence-th
;;                appearance; found again each time, so edits are fine.

(declare-function pdf-info-outline "ext:pdf-info" (&optional file-or-buffer))
(declare-function nov-url-filename-and-target "ext:nov" (url))
(declare-function nov-ncx-to-html "ext:nov" (path))
(declare-function libxml-parse-html-region "xml.c"
                  (start end &optional base-url discard-comments))
(defvar nov-epub-version)

(defun readq--section-bounds (section)
  "Return (START . END) of the text or eww SECTION in the current buffer.
Return nil when its heading cannot be found."
  (let* ((outline (readq--outline))
         (title (readq--get section :heading))
         (n (or (readq--get section :occurrence) 1))
         (tail outline)
         found)
    (while (and tail (not found))
      (when (and (equal (nth 2 (car tail)) title)
                 (zerop (setq n (1- n))))
        (setq found tail))
      (setq tail (cdr tail)))
    ;; The heading appears fewer times now: take its last appearance.
    (unless found
      (setq found (let (last)
                    (dolist (tl (cl-maplist #'identity outline) last)
                      (when (equal (nth 2 (car tl)) title) (setq last tl))))))
    (when found
      (let* ((level (nth 1 (car found)))
             (next (cl-find-if (lambda (h) (<= (nth 1 h) level)) (cdr found))))
        (cons (nth 0 (car found)) (if next (nth 0 next) (point-max)))))))

(defun readq--section-progress (section pos)
  "Return how far into SECTION the position POS is, from 0.0 to 1.0.
POS is a plist like `readq--buffer-position' returns.  For text and
web pages this must be called in the book's buffer."
  (let* ((book (readq--item-book section))
         (format (readq--get book :format))
         (start (readq--get section :start))
         (end (readq--get section :end))
         (page (plist-get pos :page))
         (point (plist-get pos :point)))
    (cond
     ((eq format 'media)
      (let ((time (plist-get pos :time)))
        (and time start end
             (max 0.0 (min 1.0 (/ (- time start) (max 1.0 (float (- end start)))))))))
     ((readq--point-format-p format)
      (when-let* ((bounds (and point (readq--section-bounds section))))
        (max 0.0 (min 1.0 (/ (float (- point (car bounds)))
                             (max 1 (- (cdr bounds) (car bounds))))))))
     ((not (and page start end)) nil)
     ((eq format 'epub)
      (let ((frac (if (and point (plist-get pos :point-max) (> (plist-get pos :point-max) 1))
                      (/ (float (1- point)) (1- (plist-get pos :point-max)))
                    0.0)))
        (max 0.0 (min 1.0 (/ (+ (- page start) frac) (float (1+ (- end start))))))))
     (t (max 0.0 (min 1.0 (/ (float (1+ (- page start))) (1+ (- end start)))))))))

(defun readq--section-location (section)
  "Describe where SECTION is in its book, e.g. \"p 12–30\"."
  (let ((start (readq--get section :start))
        (end (readq--get section :end)))
    (pcase (readq--get (readq--item-book section) :format)
      ((or 'pdf 'comic)
       (if (eql start end) (format "p %d" start) (format "p %d–%d" start end)))
      ('epub (if (eql start end) (format "ch %d" (1+ start))
               (format "ch %d–%d" (1+ start) (1+ end))))
      ('media (format "%s–%s" (readq--format-time start) (readq--format-time end)))
      (_ (make-string (max 1 (or (readq--get section :level) 1)) ?§)))))

;;;;; Reading a book's table of contents

(defun readq--outline-ends (entries last)
  "Fill in :end for ENTRIES, plists with :depth and :start, in book order.
A section ends just before the next one at its depth or above, or at
LAST.  It never ends before it starts."
  (let ((tail entries))
    (while tail
      (let* ((e (car tail))
             (next (cl-find-if (lambda (n) (<= (plist-get n :depth) (plist-get e :depth)))
                               (cdr tail))))
        (plist-put e :end (max (plist-get e :start)
                               (if next (1- (plist-get next :start)) last))))
      (setq tail (cdr tail)))
    entries))

(defun readq--pdf-outline (book)
  "Return the table of contents of the PDF BOOK as plists.
Each has :title, :depth, :start and :end (pages).  Needs pdf-tools."
  (unless (readq--pdf-info-available-p)
    (user-error "Reading a PDF's table of contents needs pdf-tools; \
use `readq-add-section' to add a section by its pages"))
  (let* ((file (expand-file-name (readq--get book :file)))
         (total (or (ignore-errors (pdf-info-number-of-pages file))
                    (readq--get book :total) 1))
         (entries (delq nil
                        (mapcar (lambda (o)
                                  (let ((page (cdr (assq 'page o))))
                                    (when (and (integerp page) (> page 0))
                                      (list :title (readq--clean-heading
                                                    (or (cdr (assq 'title o)) ""))
                                            :depth (or (cdr (assq 'depth o)) 1)
                                            :start page))))
                                (pdf-info-outline file)))))
    (readq--outline-ends entries total)))

(defun readq--dom-text (node)
  "Return the text of the DOM NODE on one line."
  (readq--clean-heading
   (mapconcat (lambda (c) (if (stringp c) c (readq--dom-text c)))
              (cddr node) " ")))

(defun readq--epub-toc-links (dom)
  "Return the links of the EPUB table of contents DOM as (DEPTH HREF TITLE).
DEPTH counts the nested lists a link is in."
  (let (result)
    (cl-labels ((walk (node depth)
                  (when (consp node)
                    (if (eq (car node) 'a)
                        (when-let* ((href (cdr (assq 'href (cadr node)))))
                          (push (list depth href (readq--dom-text node)) result))
                      (let ((depth (if (memq (car node) '(ol ul)) (1+ depth) depth)))
                        (dolist (child (cddr node))
                          (walk child depth)))))))
      (walk dom 0))
    (nreverse result)))

(defun readq--epub-outline (book)
  "Return the table of contents of the EPUB BOOK as plists.
Each has :title, :depth, :start and :end (nov.el document indexes).
Needs nov.el."
  (unless (require 'nov nil t)
    (user-error "Reading an EPUB's table of contents needs nov.el"))
  (let* ((existing (readq--book-buffer book))
         (buf (or existing
                  (let ((readq--inhibit-restore t))
                    (find-file-noselect (readq--get book :file))))))
    (unwind-protect
        (with-current-buffer buf
          (unless (derived-mode-p 'nov-mode)
            (user-error "%s did not open in nov-mode" (readq--get book :file)))
          (let* ((toc-path (cdr (aref nov-documents 0)))
                 (epub2 (version< nov-epub-version "3.0"))
                 (dom (with-temp-buffer
                        (if epub2
                            (insert (nov-ncx-to-html toc-path))
                          (insert-file-contents toc-path))
                        (libxml-parse-html-region (point-min) (point-max))))
                 (dir (file-name-directory toc-path))
                 (entries
                  (delq nil
                        (mapcar
                         (lambda (link)
                           (let* ((file (car (nov-url-filename-and-target (nth 1 link))))
                                  (path (and file (expand-file-name file dir)))
                                  (index (and path
                                              (cl-position-if
                                               (lambda (doc)
                                                 (readq--same-file-p
                                                  (expand-file-name (cdr doc)) path))
                                               nov-documents))))
                             (when index
                               (list :title (nth 2 link) :depth (nth 0 link)
                                     :start index))))
                         (readq--epub-toc-links dom)))))
            (readq--outline-ends entries (1- (length nov-documents)))))
      (unless existing (kill-buffer buf)))))

(defun readq--html-outline-titles (file)
  "Return the headings of the HTML FILE as (LEVEL TITLE), in order."
  (let ((dom (with-temp-buffer
               (insert-file-contents file)
               (libxml-parse-html-region (point-min) (point-max))))
        result)
    (cl-labels ((walk (node)
                  (when (consp node)
                    (let ((level (cdr (assq (car node) '((h1 . 1) (h2 . 2) (h3 . 3) (h4 . 4))))))
                      (if level
                          (push (list level (readq--dom-text node)) result)
                        (mapc #'walk (cddr node)))))))
      (walk dom))
    (nreverse result)))

(defun readq--text-outline (book)
  "Return the headings of the text or HTML BOOK as plists.
Each has :title, :depth, :heading, :level and :occurrence."
  (let* ((file (readq--get book :file))
         (titles (if (eq (readq--get book :format) 'html)
                     (readq--html-outline-titles file)
                   (with-temp-buffer
                     (insert-file-contents file)
                     (mapcar #'cdr (readq--outline (file-name-extension file))))))
         (seen (make-hash-table :test #'equal)))
    (mapcar (lambda (h)
              (let ((n (1+ (gethash (nth 1 h) seen 0))))
                (puthash (nth 1 h) n seen)
                (list :title (nth 1 h) :depth (nth 0 h)
                      :heading (nth 1 h) :level (nth 0 h) :occurrence n)))
            titles)))

(defun readq--book-outline (book)
  "Return the table of contents of BOOK, see `readq-add-sections'."
  (pcase (readq--get book :format)
    ('pdf (readq--pdf-outline book))
    ('epub (readq--epub-outline book))
    ('media (readq--media-outline book))
    (_ (readq--text-outline book))))

;;;;; Section items

(defun readq--sections-of (book &optional all)
  "Return the sections of BOOK; only active ones unless ALL."
  (let ((id (readq--get book :id)))
    (cl-remove-if-not (lambda (x) (and (readq--section-p x)
                                       (equal (readq--get x :book) id)
                                       (or all (not (eq (readq--get x :status) 'finished)))))
                      (readq--books))))

(defun readq--find-section (book entry)
  "Return the section of BOOK made from outline ENTRY, if there is one."
  (cl-find-if (lambda (s)
                (if (plist-get entry :heading)
                    (and (equal (readq--get s :heading) (plist-get entry :heading))
                         (eql (readq--get s :occurrence) (plist-get entry :occurrence)))
                  (and (eql (readq--get s :start) (plist-get entry :start))
                       (eql (readq--get s :end) (plist-get entry :end)))))
              (readq--sections-of book t)))

(defun readq--make-section (book entry priority)
  "Add the outline ENTRY of BOOK to the queue with PRIORITY; return it."
  (let ((section (list :id (readq--new-id)
                       :format 'section
                       :book (readq--get book :id)
                       :file (readq--get book :file)
                       :title (format "%s › %s" (readq--get book :title)
                                      (or (plist-get entry :path) (plist-get entry :title)))
                       :heading (plist-get entry :title)
                       :start (plist-get entry :start)
                       :end (plist-get entry :end)
                       :level (plist-get entry :level)
                       :occurrence (plist-get entry :occurrence)
                       :priority (min 100 (max 0 priority))
                       :status 'active
                       :added (readq--today)
                       :due (readq--today)
                       :interval (float readq-initial-interval)
                       :page nil :point nil :anchor nil
                       :progress 0.0
                       :sessions 0 :seconds 0 :last-read nil :history nil)))
    (setq readq--books (append (readq--books) (list section)))
    section))

;;;###autoload
(defun readq-add-section (book title start end priority)
  "Add pages START to END of the PDF BOOK as a section named TITLE.
For PDFs without a table of contents, or without pdf-tools."
  (interactive
   (let ((b (readq--target-book "Add a section of: ")))
     (setq b (readq--item-book b))
     (unless (readq--page-format-p (readq--get b :format))
       (user-error "Use `readq-add-sections' to choose sections of this book"))
     (let* ((title (read-string "Section title: "))
            (start (read-number "First page: "))
            (end (read-number "Last page: " start)))
       (list b title start end (readq--read-priority (readq--get b :priority))))))
  (when (< end start) (user-error "The last page is before the first one"))
  (let ((section (readq--make-section book (list :title title :start start :end end)
                                      priority)))
    (readq--save)
    (readq--refresh-dashboard)
    (message "Added \"%s\" (%s)" (readq--get section :title)
             (readq--section-location section))
    section))

;;;;; Reading a section

(defun readq--open-section (section)
  "Open SECTION in its book's buffer.  Return non-nil on success."
  (let* ((book (readq--item-book section))
         (file (readq--get book :file)))
    (unless book (user-error "The book of this section is not in your queue anymore"))
    (when (readq--missing-p book)
      (user-error "Missing file: %s" file))
    (if (eq (readq--viewer section) 'sumatra)
        (readq--open-external section)
      (let ((existing (readq--book-buffer book)))
        (cond
         (existing (switch-to-buffer existing))
         ((eq (readq--get book :format) 'html)
          (let ((readq--inhibit-restore t)) (readq--eww-open file)))
         (t (let ((readq--inhibit-restore t)) (readq--find-book-file book))))
        (readq--activate-section section (not existing))
        (message "Reading \"%s\" (%s) — priority %s, %d%% done"
                 (readq--get section :heading) (readq--section-location section)
                 (readq--get section :priority)
                 (floor (* 100 (or (readq--get section :progress) 0))))
        t))))

(defun readq--activate-section (section &optional fresh)
  "Make SECTION what is read in the current book buffer, and go to it.
FRESH means the buffer was opened just now."
  ;; End what was being read here, a book or another section.  A buffer
  ;; opened just now is not at the book's bookmark: nothing to end.
  (when (and readq-book-mode (not fresh)
             (not (equal readq--section-id (readq--get section :id))))
    (readq--end-session))
  (setq readq--section-id (readq--get section :id)
        readq--peeking nil)
  (unless readq-book-mode
    ;; eww may still be loading; its hook turns on `readq-book-mode'.
    (let ((readq--inhibit-restore t)) (readq--maybe-enable)))
  (when readq-book-mode
    (readq--start-session)
    (readq--schedule-section-jump)))

(defun readq--schedule-section-jump ()
  "Go to the open section once the buffer is ready."
  (setq readq--restoring t)
  (run-at-time 0 nil #'readq--deferred-section-jump (current-buffer)))

(defun readq--section-position (section)
  "Return where to open SECTION in the current buffer, as a position plist.
That is where you left it, or else its beginning."
  (let ((format (readq--get (readq--item-book section) :format)))
    (cond
     ((readq--get section :page)
      (list :page (readq--get section :page) :point (readq--get section :point)
            :anchor (readq--get section :anchor)))
     ((readq--point-format-p format)
      (when-let* ((bounds (readq--section-bounds section)))
        (list :page 0 :point (car bounds))))
     (t (list :page (readq--get section :start))))))

(defun readq--deferred-section-jump (buffer)
  "Go to the section open in BUFFER, once BUFFER is displayed."
  (when (buffer-live-p buffer)
    (let ((win (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (unwind-protect
            (when-let* ((section (and readq--section-id
                                      (readq--book-by-id readq--section-id)))
                        (pos (readq--section-position section)))
              (condition-case err
                  (if win
                      (with-selected-window win (readq--restore-position pos))
                    (readq--restore-position pos))
                (error (message "readq: could not go to the section: %s"
                                (error-message-string err)))))
          (setq readq--restoring nil)
          (readq--record-position)
          (readq--start-session))))))

(defun readq--leave-section ()
  "Stop reading a section in this buffer and go back to the book's bookmark."
  (when readq--section-id
    (readq--end-session)
    (setq readq--section-id nil)
    (when-let* ((book (readq--buffer-book)))
      (readq--restore-position (list :page (readq--get book :page)
                                     :point (readq--get book :point)
                                     :anchor (readq--get book :anchor))))
    (readq--start-session)))

;;;;; Choosing sections

(defvar-local readq--sections-book nil
  "Id of the book whose table of contents this buffer shows.")
(defvar-local readq--sections-outline nil
  "Vector of the outline entries shown in this buffer.")
(defvar-local readq--sections-marks nil
  "Hash table: outline index -> priority of the entries marked for adding.")

(defun readq--sections-entries ()
  "Return the tabulated-list entries of the sections buffer."
  (let ((book (readq--book-by-id readq--sections-book))
        (i -1))
    (mapcar
     (lambda (e)
       (setq i (1+ i))
       (let* ((mark (gethash i readq--sections-marks))
              (existing (readq--find-section book e))
              (where (pcase (readq--get book :format)
                       ((or 'pdf 'comic)
                        (format "p %d–%d" (plist-get e :start) (plist-get e :end)))
                       ('media (format "%s–%s" (readq--format-time (plist-get e :start))
                                       (readq--format-time (plist-get e :end))))
                       ('epub (format "ch %d–%d" (1+ (plist-get e :start))
                                      (1+ (plist-get e :end))))
                       (_ ""))))
         (list i (vector (if mark "*" " ")
                         (cond (mark (format "%d" mark))
                               (existing (format "%d" (round (readq--get existing :priority))))
                               (t ""))
                         (concat (make-string (* 2 (max 0 (1- (plist-get e :depth)))) ?\s)
                                 (plist-get e :title))
                         where
                         (if existing
                             (propertize "in queue" 'face 'readq-inactive-face)
                           "")))))
     readq--sections-outline)))

(defvar readq-sections-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "m" #'readq-sections-mark)
    (define-key map "u" #'readq-sections-unmark)
    (define-key map "=" #'readq-sections-set-priority)
    (define-key map "M" #'readq-sections-mark-level)
    (define-key map "U" #'readq-sections-unmark-all)
    (define-key map "x" #'readq-sections-add)
    map)
  "Keymap for `readq-sections-mode'.")

(define-derived-mode readq-sections-mode tabulated-list-mode "Sections"
  "Choose sections of a book to put in the reading queue.
Mark them with \\[readq-sections-mark], give them a priority with
\\[readq-sections-set-priority], then add them with \\[readq-sections-add].

\\{readq-sections-mode-map}"
  (setq tabulated-list-format [(" " 1 nil) ("Pri" 4 nil :right-align t)
                               ("Section" 60 nil) ("Where" 12 nil) ("" 8 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'readq--sections-entries)
  (tabulated-list-init-header))

;;;###autoload
(defun readq-add-sections (book)
  "Choose parts of BOOK's table of contents to read as separate items.
The table of contents of a PDF (pdf-tools), an EPUB (nov.el), or the
headings of an Org, Markdown or HTML book are listed; marked ones are
added to the queue, each with its own priority and schedule."
  (interactive (list (readq--item-book (readq--target-book "Sections of: "))))
  (let ((outline (readq--book-outline book)))
    (unless outline
      (user-error "\"%s\" has no table of contents%s" (readq--get book :title)
                  (if (readq--page-format-p (readq--get book :format))
                      "; add sections by page with `readq-add-section'" "")))
    (let ((buf (get-buffer-create
                (format "*readq sections: %s*" (readq--get book :title)))))
      (with-current-buffer buf
        (readq-sections-mode)
        (setq readq--sections-book (readq--get book :id)
              readq--sections-outline (vconcat outline)
              readq--sections-marks (make-hash-table))
        (tabulated-list-print)
        (goto-char (point-min)))
      (pop-to-buffer buf)
      (message "m: mark, =: priority, M: mark this level, x: add marked, q: quit")
      buf)))

(defun readq--sections-default-priority ()
  "Return the priority given to newly marked sections."
  (readq--get (readq--book-by-id readq--sections-book) :priority))

(defun readq-sections-mark (&optional priority)
  "Mark the section at point to be added, with PRIORITY; move down."
  (interactive)
  (when-let* ((i (tabulated-list-get-id)))
    (puthash i (or priority (gethash i readq--sections-marks)
                   (readq--sections-default-priority))
             readq--sections-marks)
    (tabulated-list-print t)
    (forward-line 1)))

(defun readq-sections-unmark ()
  "Unmark the section at point; move down."
  (interactive)
  (when-let* ((i (tabulated-list-get-id)))
    (remhash i readq--sections-marks)
    (tabulated-list-print t)
    (forward-line 1)))

(defun readq-sections-unmark-all ()
  "Unmark all sections."
  (interactive)
  (clrhash readq--sections-marks)
  (tabulated-list-print t))

(defun readq-sections-mark-level ()
  "Mark every section at the same level as the one at point."
  (interactive)
  (when-let* ((i (tabulated-list-get-id)))
    (let ((depth (plist-get (aref readq--sections-outline i) :depth))
          (priority (or (gethash i readq--sections-marks)
                        (readq--sections-default-priority))))
      (dotimes (j (length readq--sections-outline))
        (when (= (plist-get (aref readq--sections-outline j) :depth) depth)
          (puthash j (or (gethash j readq--sections-marks) priority)
                   readq--sections-marks)))
      (tabulated-list-print t))))

(defun readq-sections-set-priority (priority)
  "Mark the section at point with PRIORITY (0 most important, 100 least)."
  (interactive
   (list (readq--read-priority
          (or (gethash (tabulated-list-get-id) readq--sections-marks)
              (readq--sections-default-priority)))))
  (readq-sections-mark priority))

(defun readq-sections-add ()
  "Add the marked sections to the reading queue."
  (interactive)
  (let* ((book (readq--book-by-id readq--sections-book))
         (added
          (delq nil
                (mapcar (lambda (i)
                          (let ((entry (aref readq--sections-outline i)))
                            (unless (readq--find-section book entry)
                              (readq--make-section book entry
                                                   (gethash i readq--sections-marks)))))
                        (sort (hash-table-keys readq--sections-marks) #'<)))))
    (unless added (user-error "Mark sections with m first (or they are already queued)"))
    (readq--save)
    (when (and (readq--active-p book)
               (y-or-n-p (format "Pause \"%s\" itself, so that only its sections are \
suggested? " (readq--get book :title))))
      (readq--put book :status 'paused)
      (readq--save))
    (clrhash readq--sections-marks)
    (tabulated-list-print t)
    (readq--refresh-dashboard)
    (message "Added %d section%s of \"%s\"" (length added)
             (if (cdr added) "s" "") (readq--get book :title))
    added))

;;;; Tags

;; Items can have tags, such as "cardio" or "leisure", written with or
;; without "#".  Sections and extracts also have the tags of their book,
;; so tagging a book tags everything that comes from it.  `readq-focus'
;; limits what readq suggests to some tags; `readq-next' with a prefix
;; argument does so once.

(defface readq-tag-face '((t :inherit font-lock-keyword-face))
  "Face for tags in the readq dashboard."
  :group 'readq)

(defun readq--normalize-tag (tag)
  "Return TAG without \"#\", in lower case, usable as an Org tag."
  (let ((tag (downcase (string-trim (or tag "")))))
    (string-trim (replace-regexp-in-string
                  "[^[:alnum:]_@%]+" "_" (string-remove-prefix "#" tag))
                 "_+" "_+")))

(defun readq--normalize-tags (tags)
  "Return TAGS normalized, without duplicates or empty ones."
  (delete-dups (delete "" (mapcar #'readq--normalize-tag tags))))

(defun readq--item-tags (item)
  "Return ITEM's tags: its own and, for a section or extract, its book's."
  (let ((book (readq--item-book item)))
    (delete-dups (append (readq--get item :tags)
                         (and book (not (eq book item)) (readq--get book :tags))))))

(defun readq--tags-match-p (item tags)
  "Return non-nil when ITEM has one of TAGS, or TAGS is nil."
  (or (null tags)
      (cl-intersection (readq--item-tags item) tags :test #'equal)))

(defun readq--tags-string-of (tags)
  "Return TAGS as text, e.g. \"#cardio #leisure\"."
  (mapconcat (lambda (tag) (concat "#" tag)) tags " "))

(defun readq--tags-string (item)
  "Return the tags of ITEM as text."
  (readq--tags-string-of (readq--item-tags item)))

(defun readq--all-tags ()
  "Return all tags in use, sorted."
  (sort (delete-dups (apply #'append (mapcar (lambda (x) (copy-sequence
                                                          (readq--get x :tags)))
                                             (readq--books))))
        #'string<))

(defvar crm-separator)

(defun readq--read-tags (prompt &optional initial require-some)
  "Read tags with PROMPT, separated by commas or spaces.
INITIAL is a list of tags to start with.  With REQUIRE-SOME, an empty
answer is an error."
  (let* ((crm-separator "[ \t]*[, ][ \t]*")
         (tags (readq--normalize-tags
                (completing-read-multiple
                 prompt (readq--all-tags) nil nil
                 (and initial (mapconcat #'identity initial ", "))))))
    (when (and require-some (null tags))
      (user-error "No tags given"))
    tags))

(defun readq-set-tags (item tags)
  "Set the tags of ITEM (a book, section or extract) to TAGS.
Sections and extracts also have their book's tags; TAGS are their own."
  (interactive
   (let ((item (readq--target-book "Tags of: ")))
     (list item (readq--read-tags (format "Tags of \"%s\": " (readq--get item :title))
                                  (readq--get item :tags)))))
  (readq--put item :tags (readq--normalize-tags tags))
  ;; Tags are the keywords of the notes of extracts.
  (readq--sync-extracts-of (if (readq--section-p item) (readq--item-book item) item))
  (readq--changed item "\"%s\": %s" (readq--get item :title)
                  (let ((all (readq--tags-string item)))
                    (if (string-empty-p all) "no tags" all))))

;;;###autoload
(defun readq-focus (tags)
  "Focus your reading on TAGS: suggest only items with one of them.
`readq-next', `readq-suggest' and the dashboard follow the focus until
you clear it by calling this command with no tags.  The focus is saved
with your queue."
  (interactive (list (readq--read-tags "Focus on tags (empty to clear): "
                                       readq--focus)))
  (setq readq--focus (readq--normalize-tags tags))
  (unless readq--focus (setq readq--focus nil))
  (readq--save)
  (readq--refresh-dashboard)
  (if readq--focus
      (message "Reading focused on %s" (readq--tags-string-of readq--focus))
    (message "Focus cleared: all your books and extracts are suggested")))

;;;; Subset review

;; As in SuperMemo's subset review: before an exam, go through one
;; book, one section, one extract with its sub-extracts, or one tag
;; now, due or not.  `readq-next' then opens only the items of this
;; subset, most important first and without the daily limit, until
;; none is left; each is rescheduled as usual when you have read it.

(defcustom readq-subset-due-only nil
  "Non-nil means `readq-review-subset' takes only the items already due.
By default it takes every active item of the subset, due or not."
  :type 'boolean
  :group 'readq)

(defun readq--made-from-p (item root)
  "Return non-nil when the extract ITEM was made from the extract ROOT.
ITEM may be a sub-extract of a sub-extract, and so on."
  (let ((id (readq--get root :id))
        (seen nil)
        found)
    (while (and item (not found) (not (memq item seen)))
      (push item seen)
      (let ((parent (readq--get item :parent)))
        (if (equal parent id)
            (setq found t)
          (setq item (and parent (readq--book-by-id parent))))))
    found))

(defun readq--top-extract (x)
  "Return the extract of a book that the extract X was made from, or X."
  (let ((seen nil))
    (while (and (readq--get x :parent) (not (memq x seen)))
      (push x seen)
      (setq x (or (readq--book-by-id (readq--get x :parent)) x)))
    x))

(defun readq--in-section-p (x section)
  "Return non-nil when the extract X was made in SECTION of its book.
Sub-extracts count where the extract they come from was made."
  (let* ((x (readq--top-extract x))
         (format (readq--get (readq--item-book section) :format))
         (page (readq--get x :page))
         (start (readq--get section :start))
         (end (readq--get section :end)))
    (if (readq--point-format-p format)
        (let* ((book (readq--item-book section))
               (nodes (readq--book-chapters book))
               (i (and (> (length nodes) 0) (readq--extract-chapter-index book nodes x)))
               found)
          (if (= (length nodes) 0)
              (equal (readq--get x :section) (readq--get section :heading))
            ;; The extract's heading, or one it is under, is SECTION's.
            (while (and i (not found))
              (let ((n (aref nodes i)))
                (if (and (equal (plist-get n :heading) (readq--get section :heading))
                         (eql (or (plist-get n :occurrence) 1)
                              (or (readq--get section :occurrence) 1)))
                    (setq found t)
                  (setq i (plist-get n :up)))))
            found))
      (and (numberp page) start end (<= start page end)))))

(defun readq--subset-member-p (item target)
  "Return non-nil when ITEM is in the subset TARGET.
TARGET is a tag (a string), or a book, section, chapter row or
extract: a book takes its sections and all its extracts, a section or
chapter the extracts made in it, an extract the extracts made from it."
  (cond
   ((stringp target) (readq--tags-match-p item (list target)))
   ((eq item target) t)
   ((readq--extract-p target)
    (and (readq--extract-p item) (readq--made-from-p item target)))
   ((or (readq--section-p target) (readq--chapter-p target))
    (and (readq--extract-p item)
         (equal (readq--get item :book) (readq--get target :book))
         (readq--in-section-p item target)))
   (t (and (not (readq--book-p item))
           (equal (readq--get item :book) (readq--get target :id))))))

(defun readq--subset-of (target)
  "Return the items of the subset TARGET to review, in order.
They are its active items (only due ones with `readq-subset-due-only'),
most important first, then soonest due."
  (sort (cl-remove-if-not
         (lambda (x) (and (readq--active-p x)
                          (not (readq--missing-p x))
                          (or (not readq-subset-due-only) (readq--due-p x))
                          (readq--subset-member-p x target)))
         (readq--books))
        (lambda (a b)
          (let ((pa (readq--get a :priority)) (pb (readq--get b :priority)))
            (if (= pa pb)
                (string< (or (readq--get a :due) "") (or (readq--get b :due) ""))
              (< pa pb))))))

(defun readq--subset-items ()
  "Return the items of the subset still to be opened.
Items paused, finished, dismissed or deleted since are left out."
  (delq nil (mapcar (lambda (id)
                      (let ((x (readq--book-by-id id)))
                        (and x (readq--active-p x) (not (readq--missing-p x)) x)))
                    (plist-get readq--subset :ids))))

(defun readq--subset-drop (item)
  "Take ITEM out of the subset being reviewed."
  (when readq--subset
    (setq readq--subset
          (plist-put readq--subset :ids
                     (delete (readq--get item :id) (plist-get readq--subset :ids))))))

(defun readq--subset-string ()
  "Describe the subset being reviewed, e.g. \"Guyton: 3 of 12 left\"."
  (format "%s: %d of %d left" (plist-get readq--subset :name)
          (length (readq--subset-items)) (plist-get readq--subset :total)))

(defun readq--item-here ()
  "Return the book or extract at point or being read here, or nil."
  (or (and (derived-mode-p 'readq-dashboard-mode)
           (when-let* ((id (tabulated-list-get-id))) (readq--dashboard-item id)))
      (readq--extract-at-point)
      (readq--current-item)
      (and readq--external-session
           (readq--book-by-id (plist-get readq--external-session :id)))))

(defun readq--read-subset-target ()
  "Read a book, section, extract or #tag to review now.
The item at point, if any, is the default."
  (let* ((here (readq--item-here))
         (q (readq--queue))
         (items (cl-remove-if-not #'readq--active-p
                                  (append q (cl-set-difference (readq--books) q))))
         (items (if here (cons here (delq here items)) items))
         (cands (append (mapcar (lambda (b)
                                  (cons (if (readq--chapter-p b)
                                            (format "[chapter] %s" (readq--get b :title))
                                          (readq--book-label b))
                                        b))
                                items)
                        (mapcar (lambda (tag) (cons (concat "#" tag) tag))
                                (readq--all-tags))))
         (table (lambda (str pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action cands str pred)))))
    (unless cands (user-error "Your reading queue is empty; add a book with `readq-add-book'"))
    (cdr (assoc (completing-read "Review now (book, section, extract or #tag): "
                                 table nil t nil nil (car (car cands)))
                cands))))

;;;###autoload
(defun readq-review-subset (target)
  "Review TARGET now, due or not, as in SuperMemo's subset review.
TARGET is a book with its sections and all its extracts, a section
with the extracts made in it, an extract with the extracts made from
it, or a tag (a string) with all the items that have it.

Until all of them have been opened, `readq-next' opens only these, most
important first, even beyond the daily limit (`readq-daily-minutes').
Each is rescheduled as usual when you finish it.  The first one opens
right away.  With `readq-subset-due-only', only items already due are
taken.

With a prefix argument, stop the subset review and go back to your
queue.  In the dashboard, the item at point is proposed."
  (interactive (list (if current-prefix-arg 'stop (readq--read-subset-target))))
  (if (eq target 'stop)
      (progn
        (unless readq--subset (user-error "No subset is being reviewed"))
        (let ((name (plist-get readq--subset :name)))
          (setq readq--subset nil)
          (readq--save)
          (readq--refresh-dashboard)
          (message "Stopped reviewing %s: back to your queue" name)))
    (let ((items (readq--subset-of target))
          (name (if (stringp target) (concat "#" target) (readq--get target :title))))
      (unless items
        (user-error "Nothing to review in %s%s" name
                    (if readq-subset-due-only " (nothing is due)" "")))
      (setq readq--subset (list :name name
                                :ids (mapcar (lambda (x) (readq--get x :id)) items)
                                :total (length items)))
      (readq--save)
      (readq--refresh-dashboard)
      (readq-next)
      (when readq--subset
        (message "Reviewing %s.  %s opens the next, %s stops"
                 (readq--subset-string)
                 (substitute-command-keys "\\[readq-next]")
                 (substitute-command-keys "\\[universal-argument] \\[readq-review-subset]"))))))

(defun readq--next-in-subset (cur)
  "Open the next item of the subset being reviewed, after CUR.
Return non-nil when something was opened."
  (when cur (readq--subset-drop cur))
  (let ((items (delq cur (readq--subset-items)))
        opened)
    (while (and items (not opened))
      (let ((x (pop items)))
        (readq--subset-drop x)
        (setq opened (readq-open x))))
    (unless opened
      (let ((name (plist-get readq--subset :name))
            (total (plist-get readq--subset :total)))
        (setq readq--subset nil)
        (readq--refresh-dashboard)
        (message "Finished reviewing %s (%d item%s).  %s goes on with your queue"
                 name total (if (= total 1) "" "s")
                 (substitute-command-keys "\\[readq-next]"))))
    (readq--save)
    opened))

(provide 'readq-sections)
;;; readq-sections.el ends here
