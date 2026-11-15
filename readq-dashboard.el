;;; readq-dashboard.el --- The dashboard -*- lexical-binding: t; -*-

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

(require 'readq-plan)

(declare-function readq-edit-extract "readq-extract-tools")
(declare-function readq-stale-extracts "readq-extract-tools")
(declare-function readq-find-extract "readq-extract-tools")
(declare-function readq-search "readq-extract-tools")
(declare-function readq-doctor "readq")
(declare-function readq-extract-figure-from-clipboard "readq-extract")
(declare-function readq-extract-figure "readq-extract")
(declare-function readq-export-cards "readq-cards")
(declare-function readq-mark-ready "readq-cards")
(declare-function readq-goto-source "readq-extract-tools")
(declare-function readq-import-highlights "readq-extract-tools")
(declare-function readq-visit-extracts "readq-extract")
(declare-function readq--stale-extracts "readq-extract-tools")
(declare-function readq-update-anki-cards "readq-cards")
(declare-function readq-read-aloud "readq-kokoro")

;;;; Dashboard

(defvar-local readq-dashboard-show-finished nil
  "When non-nil, the dashboard also lists finished books.")

(defvar-local readq-dashboard-show-extracts t
  "When non-nil, the dashboard also lists extracts, under their books.")

(defun readq--due-string (book)
  "Return a description of when BOOK is due."
  (pcase (readq--get book :status)
    ('finished (if (readq--get book :exported) "exported" "finished"))
    ('paused "paused")
    ('ready "ready")
    (_ (if (readq--missing-p book)
           "missing"
         (let ((d (readq--days-until (readq--get book :due))))
           (cond ((= d 0) "today")
                 ((< d 0) (format "%dd late" (- d)))
                 ((= d 1) "tomorrow")
                 (t (format "in %dd" d))))))))

(defun readq--book-face (book)
  "Return the face used for BOOK's title in the dashboard."
  (cond ((readq--chapter-p book) nil)
        ((readq--missing-p book) 'readq-missing-face)
        ((not (readq--active-p book)) 'readq-inactive-face)
        ((readq--due-p book) 'readq-due-face)))

(defun readq--dashboard-books ()
  "Return the books shown in the dashboard, in display order."
  (let* ((shown (lambda (b) (and (or readq-dashboard-show-extracts
                                      (not (readq--extract-p b)))
                                  (readq--tags-match-p b readq--focus))))
         (q (cl-remove-if-not shown (readq--queue)))
         (rest (cl-remove-if (lambda (b) (or (memq b q) (not (funcall shown b))))
                             (readq--books)))
         (rest (if readq-dashboard-show-finished
                   rest
                 (cl-remove-if (lambda (b) (eq (readq--get b :status) 'finished)) rest))))
    (append q (sort rest (lambda (a b) (< (readq--get a :priority)
                                          (readq--get b :priority)))))))


;;;;; Chapters in the dashboard

;; The dashboard lists a book's extracts under the chapters of its table
;; of contents.  A chapter row is not an item of the queue: it is a
;; plist with :format `chapter', made from an outline entry and kept in
;; `readq--chapter-cache', so it stays the same object between redraws.
;; Where a section of the book was made from that entry, the section is
;; listed in its place.

(defvar readq--chapter-cache (make-hash-table :test 'equal)
  "Hash table: book id to (KEY . NODES), the chapter rows of its outline.
KEY is the file and its modification time when they were read; NODES
a vector of chapter plists, in book order.")

(defvar readq--chapters-by-id (make-hash-table :test 'equal)
  "Hash table: id of a chapter row to the chapter.")

(defun readq--chapter-p (item)
  "Return non-nil when ITEM is a chapter row of the dashboard."
  (eq (readq--get item :format) 'chapter))

(defun readq--dashboard-item (id)
  "Return the item or chapter row whose id is ID."
  (or (readq--book-by-id id) (gethash id readq--chapters-by-id)))

(defun readq--book-chapters (book)
  "Return the chapter rows of BOOK as a vector, or nil.
They are read from BOOK's table of contents once, and again when its
file changes.  A book whose table of contents cannot be read has none."
  (when (and (memq (readq--get book :format) '(pdf epub text html))
             (not (eql readq-chapter-depth 0))
             (not (readq--missing-p book)))
    (let* ((id (readq--get book :id))
           (file (readq--get book :file))
           (key (list file (file-attribute-modification-time (file-attributes file))))
           (cached (gethash id readq--chapter-cache)))
      (if (equal (car cached) key)
          (cdr cached)
        (when cached
          (mapc (lambda (n) (remhash (plist-get n :id) readq--chapters-by-id)) (cdr cached)))
        (let* ((outline (ignore-errors
                          (let ((inhibit-message t) (message-log-max nil))
                            (readq--book-outline book))))
               (top (and outline (apply #'min (mapcar (lambda (e) (plist-get e :depth))
                                                      outline))))
               (nodes (make-vector (length outline) nil))
               (stack nil) (i 0))
          (dolist (e outline)
            (let ((depth (1+ (- (plist-get e :depth) top))))
              (while (and stack (>= (plist-get (aref nodes (car stack)) :depth) depth))
                (pop stack))
              (aset nodes i (list :id (format "chapter:%s:%d" id i) :format 'chapter
                                  :book id :index i :up (car stack) :depth depth
                                  :title (if (string-blank-p (or (plist-get e :title) ""))
                                             "(untitled)"
                                           (plist-get e :title))
                                  :start (plist-get e :start) :end (plist-get e :end)
                                  :heading (plist-get e :heading)
                                  :occurrence (plist-get e :occurrence)))
              (puthash (format "chapter:%s:%d" id i) (aref nodes i) readq--chapters-by-id)
              (push i stack)
              (cl-incf i)))
          (puthash id (cons key nodes) readq--chapter-cache)
          nodes)))))

(defun readq--chapter-within-depth (nodes i)
  "Return I, or the chapter of NODES above it shown by the dashboard."
  (while (and i readq-chapter-depth
              (> (plist-get (aref nodes i) :depth) readq-chapter-depth))
    (setq i (plist-get (aref nodes i) :up)))
  i)

(defvar readq--chapter-sections nil
  "While the dashboard is drawn, a hash table: book id to its sections
made from its table of contents, as an alist (INDEX . SECTION).")

(defun readq--chapter-sections (book nodes)
  "Return the sections of BOOK made from chapters of NODES, as (INDEX . SECTION)."
  (let ((id (readq--get book :id)))
    (or (and readq--chapter-sections (gethash id readq--chapter-sections))
        (let ((alist (delq nil
                           (mapcar
                            (lambda (s)
                              (when-let* ((i (cl-position-if
                                             (lambda (n)
                                               (if (plist-get n :heading)
                                                   (and (equal (readq--get s :heading)
                                                               (plist-get n :heading))
                                                        (eql (readq--get s :occurrence)
                                                             (plist-get n :occurrence)))
                                                 (and (eql (readq--get s :start)
                                                           (plist-get n :start))
                                                      (eql (readq--get s :end)
                                                           (plist-get n :end)))))
                                             nodes)))
                                (cons i s)))
                            (readq--sections-of book t)))))
          (when readq--chapter-sections
            (puthash id (or alist (list nil)) readq--chapter-sections))
          alist))))

(defun readq--section-chapter-index (book nodes section)
  "Return the index in NODES of the outline entry SECTION of BOOK was made from."
  (car (rassq section (readq--chapter-sections book nodes))))

(defun readq--extract-chapter-index (book nodes x)
  "Return the index in NODES of the deepest chapter the extract X is in.
X was made from BOOK.  For a PDF or EPUB, that is the last chapter
whose pages hold X's page; for text, the one with X's heading."
  (if (readq--point-format-p (readq--get book :format))
      (when-let* ((heading (readq--get x :section)))
        (cl-position heading nodes :key (lambda (n) (plist-get n :heading)) :test #'equal))
    (when-let* ((page (readq--get x :page)))
      (when (numberp page)
        (cl-position-if (lambda (n) (and (numberp (plist-get n :start))
                                         (numberp (plist-get n :end))
                                         (<= (plist-get n :start) page (plist-get n :end))))
                        nodes :from-end t)))))

(defun readq--chapter-row (book nodes i)
  "Return the dashboard row of chapter I of NODES of BOOK.
That is the section made from it, if any, or else the chapter itself."
  (or (cdr (assq i (readq--chapter-sections book nodes)))
      (aref nodes i)))

(defun readq--chapter-parent (item)
  "Return the chapter row ITEM is listed under, or nil.
ITEM is an extract made right from its book, a section or a chapter row."
  (when-let* ((book (readq--book-by-id (readq--get item :book)))
              (nodes (readq--book-chapters book)))
    (let ((i (cond ((readq--chapter-p item)
                    (plist-get item :up))
                   ((readq--section-p item)
                    (when-let* ((j (readq--section-chapter-index book nodes item)))
                      (readq--chapter-within-depth nodes (plist-get (aref nodes j) :up))))
                   (t (readq--chapter-within-depth
                       nodes (readq--extract-chapter-index book nodes item))))))
      (when i
        (let ((row (readq--chapter-row book nodes i)))
          (unless (eq row item) row))))))

(defun readq--dashboard-order (item)
  "Return ITEM's place in its book's table of contents, or nil.
Chapter rows, and sections made from the table of contents, are listed
in book order."
  (cond ((readq--chapter-p item) (plist-get item :index))
        ((readq--section-p item)
         (when-let* ((book (readq--book-by-id (readq--get item :book)))
                     (nodes (readq--book-chapters book)))
           (readq--section-chapter-index book nodes item)))))

(defun readq--dashboard-parent (item)
  "Return the item ITEM is listed under in the dashboard, or nil.
An extract is listed under the extract it was made from, or else the
chapter of its book it was made in (`readq-chapter-depth'),
or else its book.  A section or a chapter row is listed under the
chapter it is part of, or else its book."
  (cond ((and (readq--extract-p item) (readq--get item :parent))
         (or (readq--book-by-id (readq--get item :parent))
             (readq--book-by-id (readq--get item :book))))
        ((or (readq--extract-p item) (readq--section-p item) (readq--chapter-p item))
         (or (readq--chapter-parent item)
             (readq--book-by-id (readq--get item :book))))))

(defvar-local readq--dashboard-extract-counts nil
  "Hash table: book id to its number of active extracts, as last drawn.")

(defun readq--dashboard-extract-count (book)
  "Return the number of active extracts of BOOK."
  (if readq--dashboard-extract-counts
      (gethash (readq--get book :id) readq--dashboard-extract-counts 0)
    (length (readq--extracts-of book))))

(defvar-local readq--dashboard-folds nil
  "Hash table: item id to `open' or `closed', as you folded it.")

(defvar-local readq--dashboard-rows nil
  "Hash table: id of each row shown to its plist (:depth :kids :open :rank).")

(defun readq--dashboard-tree ()
  "Return the dashboard's rows: items in display order, with their children.
Every item is listed under its parent (`readq--dashboard-parent').
Parents come in the order of their most urgent item, children likewise,
except that the chapters of a book come first, in book order.
An item with children is open when you opened it, or by default when
something under it is due.  Fills `readq--dashboard-rows'."
  (unless readq--dashboard-folds
    (setq readq--dashboard-folds (make-hash-table :test 'equal)))
  (setq readq--dashboard-extract-counts (make-hash-table :test 'equal))
  (dolist (b (readq--books))
    (when (and (readq--extract-p b) (readq--active-p b))
      (cl-incf (gethash (readq--get b :book) readq--dashboard-extract-counts 0))))
  (let* ((readq--chapter-sections (make-hash-table :test 'equal))
         (shown (readq--dashboard-books))
         (rank (make-hash-table :test 'eq))
         (kids (make-hash-table :test 'eq))
         (due-below (make-hash-table :test 'eq))
         (seen (make-hash-table :test 'eq))
         (all nil) (roots nil) (rows nil) (i 0))
    (dolist (b shown) (puthash b (cl-incf i) rank))
    ;; Parents are listed even when they would not be on their own.
    (dolist (b shown)
      (let ((item b) (child nil))
        (while (and item (not (gethash item seen)))
          (puthash item t seen)
          (push item all)
          (when child (push child (gethash item kids)))
          (setq child item item (readq--dashboard-parent item)))
        (when (and item child) (push child (gethash item kids)))))
    (dolist (b all)
      (unless (readq--dashboard-parent b) (push b roots)))
    ;; A chapter row counts the active extracts under it.
    (cl-labels ((count (b)
                  (let ((n 0))
                    (dolist (k (gethash b kids))
                      (cl-incf n (+ (if (and (readq--extract-p k) (readq--active-p k)) 1 0)
                                    (count k))))
                    (when (readq--chapter-p b)
                      (puthash (readq--get b :id) n readq--dashboard-extract-counts))
                    n)))
      (mapc #'count roots))
    ;; A parent ranks as its most urgent descendant.
    (cl-labels ((subtree-rank (b)
                  (let ((r (gethash b rank most-positive-fixnum))
                        (due nil))
                    (dolist (k (gethash b kids))
                      (setq r (min r (subtree-rank k)))
                      (when (or (gethash k due-below)
                                (and (readq--active-p k) (readq--due-p k)))
                        (setq due t)))
                    (puthash b r rank)
                    (puthash b due due-below)
                    r))
                (by-rank (items)
                  ;; Chapters come first, in book order.
                  (sort (delete-dups (copy-sequence items))
                        (lambda (a b)
                          (let ((oa (readq--dashboard-order a))
                                (ob (readq--dashboard-order b)))
                            (cond ((and oa ob) (< oa ob))
                                  (oa t)
                                  (ob nil)
                                  (t (< (gethash a rank) (gethash b rank))))))))
                (walk (b depth path)
                  (let* ((children (by-rank (gethash b kids)))
                         (path (append path (list b)))
                         (fold (gethash (readq--get b :id) readq--dashboard-folds))
                         (open (and children
                                    (if fold (eq fold 'open) (gethash b due-below)))))
                    (puthash (readq--get b :id)
                             (list :depth depth :kids (length children) :open open
                                   :rank (gethash b rank) :path path)
                             readq--dashboard-rows)
                    (push b rows)
                    (when open
                      (dolist (k children) (walk k (1+ depth) path))))))
      (setq readq--dashboard-rows (make-hash-table :test 'equal))
      (dolist (r roots) (subtree-rank r))
      (dolist (r (by-rank roots)) (walk r 0 nil)))
    (nreverse rows)))

(defvar readq--dashboard-fold-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'readq-dashboard-toggle-fold)
    (define-key map [mouse-2] #'readq-dashboard-toggle-fold)
    map)
  "Keymap of the fold marks in the dashboard.")

(defun readq--dashboard-name (item)
  "Return the name of ITEM in the dashboard: a section is listed under its
book by its heading alone."
  (if (and (readq--section-p item) (readq--get item :book))
      (or (readq--get item :heading) (readq--get item :title))
    (readq--get item :title)))

(defun readq--dashboard-title-cell (book)
  "Return the Title cell for BOOK: indented under its parent, with a fold mark."
  (let* ((row (and readq--dashboard-rows
                   (gethash (readq--get book :id) readq--dashboard-rows)))
         (depth (or (plist-get row :depth) 0))
         (mark (cond ((null row) "")
                     ((zerop (plist-get row :kids)) "  ")
                     (t (propertize (if (plist-get row :open) "▾ " "▸ ")
                                    'mouse-face 'highlight
                                    'help-echo "mouse-1, TAB: show or hide what is under it"
                                    'keymap readq--dashboard-fold-map))))
         (indent (make-string (* 2 depth) ?\s))
         (name (readq--dashboard-name book))
         (title (truncate-string-to-width
                 name (max 10 (- readq-title-width (length indent) (length mark)))
                 nil nil "…"))
         (face (readq--book-face book)))
    (concat indent mark (if face (propertize title 'face face) title))))

(defun readq--dashboard-goto (id)
  "Move point to the dashboard row of item ID, if shown."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
    (forward-line 1)))

(defun readq-dashboard-toggle-fold (&optional event)
  "Show or hide the items under the item at point (or clicked, EVENT).
On an item with nothing under it, fold its parent."
  (interactive (list last-nonmenu-event))
  (when (and event (mouse-event-p event))
    (posn-set-point (event-end event)))
  (let* ((id (or (tabulated-list-get-id) (user-error "No item on this line")))
         (row (gethash id readq--dashboard-rows)))
    (if (and row (> (plist-get row :kids) 0))
        (puthash id (if (plist-get row :open) 'closed 'open) readq--dashboard-folds)
      (let ((parent (readq--dashboard-parent (readq--dashboard-item id))))
        (unless parent (user-error "Nothing to show or hide here"))
        (setq id (readq--get parent :id))
        (puthash id 'closed readq--dashboard-folds)))
    (readq--dashboard-print)
    (readq--dashboard-goto id)))

(defun readq-dashboard-toggle-all-folds ()
  "Show everything under every item, or, when something is shown, hide it all."
  (interactive)
  (let* ((open (cl-loop for row being the hash-values of readq--dashboard-rows
                        thereis (plist-get row :open)))
         (id (tabulated-list-get-id)))
    (dolist (b (append (readq--books) (hash-table-values readq--chapters-by-id)))
      (when-let* ((parent (readq--dashboard-parent b)))
        (puthash (readq--get parent :id) (if open 'closed 'open) readq--dashboard-folds)))
    (readq--dashboard-print)
    (let ((item (and id (readq--dashboard-item id))))
      ;; Stay on the line, or on its top item when it was hidden.
      (while (and item (readq--dashboard-parent item)
                  (not (gethash (readq--get item :id) readq--dashboard-rows)))
        (setq item (readq--dashboard-parent item)))
      (when item (readq--dashboard-goto (readq--get item :id))))
    (message (if open "Everything folded" "Everything unfolded"))))

(defun readq--extracts-of (book &optional all)
  "Return the extracts made from BOOK; only active ones unless ALL."
  (cl-remove-if-not (lambda (x) (and (readq--extract-p x)
                                     (or all (readq--active-p x))))
                    (readq--items-of book)))

(declare-function all-the-icons-faicon "ext:all-the-icons")
(declare-function all-the-icons-icon-for-file "ext:all-the-icons")

(defun readq--icons-p ()
  "Return non-nil when the dashboard can show all-the-icons icons."
  (and readq-dashboard-icons
       (display-graphic-p)
       (require 'all-the-icons nil t)))

(defun readq--kind (book)
  "Return the kind of BOOK as a word, e.g. \"pdf\", \"video\"."
  (cond ((readq--extract-p book) (if (readq--get book :figure) "figure" "extract"))
        ((readq--section-p book) "section")
        ((readq--chapter-p book) "chapter")
        ((eq (readq--viewer book) 'sumatra) "sumatra")
        ((eq (readq--get book :format) 'comic) "comic")
        ((eq (readq--get book :format) 'media) (readq--media-kind book))
        ((eq (readq--get book :format) 'text)
         (downcase (or (file-name-extension (readq--get book :file)) "text")))
        (t (symbol-name (readq--get book :format)))))

(defun readq--icon (name face &optional help)
  "Return the Font Awesome icon NAME in FACE, with HELP as tooltip."
  (let ((icon (all-the-icons-faicon name :face face :v-adjust 0.0 :height 1.0)))
    (if help (propertize icon 'help-echo help) icon)))

(defun readq--kind-icon (book)
  "Return an icon for the kind of BOOK."
  (let ((kind (readq--kind book)))
    (pcase kind
      ("extract" (readq--icon "quote-left" 'all-the-icons-yellow "extract"))
      ("figure" (readq--icon "picture-o" 'all-the-icons-purple "figure extract"))
      ("section" (readq--icon "bookmark" 'all-the-icons-dblue "section"))
      ("chapter" (readq--icon "folder-o" 'all-the-icons-dblue "chapter"))
      ("sumatra" (readq--icon "file-pdf-o" 'all-the-icons-orange "PDF, read in SumatraPDF"))
      ("audio" (readq--icon "headphones" 'all-the-icons-lpurple "audio"))
      ("video" (readq--icon "film" 'all-the-icons-blue "video"))
      ("online" (readq--icon "youtube-play" 'all-the-icons-red "online video"))
      ("epub" (readq--icon "book" 'all-the-icons-blue "EPUB"))
      ("comic" (readq--icon "file-image-o" 'all-the-icons-lgreen "comic"))
      ("html" (readq--icon "globe" 'all-the-icons-cyan "web page"))
      (_ (propertize (all-the-icons-icon-for-file (readq--get book :file)
                                                  :v-adjust 0.0 :height 1.0)
                     'help-echo kind)))))

(defun readq--due-cell (book)
  "Return the Due cell for BOOK: when it is due, colored, with an icon."
  (let* ((due (readq--due-string book))
         (face (cond ((string-match-p "late" due) 'readq-overdue-face)
                     ((equal due "today") 'readq-due-face)
                     ((equal due "missing") 'readq-missing-face)
                     ((member due '("paused" "finished" "exported")) 'readq-inactive-face)))
         (text (if face (propertize due 'face face) due)))
    (if (not (readq--icons-p))
        text
      (concat (pcase due
                ((pred (string-match-p "late"))
                 (readq--icon "exclamation-circle" 'all-the-icons-red))
                ("today" (readq--icon "clock-o" 'all-the-icons-orange))
                ("tomorrow" (readq--icon "calendar" 'all-the-icons-silver))
                ("paused" (readq--icon "pause" 'all-the-icons-silver))
                ((or "finished" "exported") (readq--icon "check" 'all-the-icons-green))
                ("ready" (readq--icon "graduation-cap" 'all-the-icons-cyan))
                ("missing" (readq--icon "question-circle" 'all-the-icons-red))
                (_ " "))
              " " text))))

(defun readq--dashboard-column-specs ()
  "Return the specs of every dashboard column, as an alist.
Each is (KEY NAME WIDTH SORT CELL . PROPS), CELL a function of the item."
  (let ((icons (readq--icons-p)))
    `((priority "Pri" 4 ,(readq--sorter (lambda (b) (readq--get b :priority)))
                ,(lambda (b) (format "%d" (round (readq--get b :priority))))
                :right-align t)
      (kind ,(if icons "" "Kind") ,(if icons 2 8) ,(readq--sorter #'readq--kind #'string<)
            ,(lambda (b) (if icons (readq--kind-icon b) (readq--kind b))))
      (title "Title" ,readq-title-width
             ,(readq--sorter (lambda (b) (downcase (readq--dashboard-name b))) #'string<)
             ,#'readq--dashboard-title-cell)
      (tags "Tags" ,readq-tags-width ,(readq--sorter #'readq--tags-string #'string<)
            ,(lambda (b) (propertize (readq--tags-string b) 'face 'readq-tag-face)))
      (progress "Progress" ,(+ readq-progress-bar-width 6)
                ,(readq--sorter (lambda (b) (if (readq--extract-p b) -1
                                              (or (readq--get b :progress) 0))))
                ,(lambda (b) (if (readq--extract-p b) ""
                               (readq--progress-bar (readq--get b :progress)))))
      (position "Position" 11 nil ,#'readq--position-string)
      (extracts "Ext" 4 ,(readq--sorter #'readq--dashboard-extract-count)
                ,(lambda (b) (if (readq--extract-p b) ""
                               (let ((n (readq--dashboard-extract-count b)))
                                 (if (> n 0) (number-to-string n) ""))))
                :right-align t)
      (due "Due" ,(if icons 13 10)
           ,(readq--sorter (lambda (b) (readq--days-until (or (readq--get b :due) (readq--today)))))
           ,#'readq--due-cell)
      (deadline "Deadline" ,readq-deadline-width
                ,(readq--sorter (lambda (b) (let ((dl (readq--effective-deadline b)))
                                              (if dl (readq--days-until (car dl)) 100000))))
                ,#'readq--deadline-column)
      (interval "Ivl" 5 ,(readq--sorter (lambda (b) (readq--get b :interval)))
                ,(lambda (b) (format "%dd" (round (readq--get b :interval))))
                :right-align t)
      (last-read "Last read" 11 ,(readq--sorter (lambda (b) (or (readq--get b :last-read) ""))
                                                #'string<)
                 ,(lambda (b) (or (readq--get b :last-read) "never")))
      (time "Time" 7 ,(readq--sorter (lambda (b) (or (readq--get b :seconds) 0)))
            ,(lambda (b) (if (readq--extract-p b) ""
                           (readq--duration-string (readq--get b :seconds))))))))

(defun readq--dashboard-columns ()
  "Return the dashboard's columns: specs of `readq-dashboard-columns'.
Tags and Deadline are left out when nothing has tags or a deadline."
  (let ((specs (readq--dashboard-column-specs))
        (books (readq--books)))
    (delq nil
          (mapcar
           (lambda (key)
             (and (pcase key
                    ('tags (cl-some (lambda (b) (readq--get b :tags)) books))
                    ('deadline (or readq--tag-deadlines
                                   (cl-some (lambda (b) (readq--get b :deadline)) books)))
                    (_ t))
                  (assq key specs)))
           readq-dashboard-columns))))

(defvar-local readq--dashboard-shown-columns nil
  "The columns the dashboard shows now.")

(defun readq--dashboard-setup-columns ()
  "Set the dashboard's columns, which depend on your items and display."
  (setq readq--dashboard-shown-columns (readq--dashboard-columns)
        tabulated-list-format
        (vconcat (mapcar (lambda (spec)
                           (pcase-let ((`(,_key ,name ,width ,sort ,_cell . ,props) spec))
                             (append (list name width sort) props)))
                         readq--dashboard-shown-columns)))
  (tabulated-list-init-header))

(defun readq--dashboard-entry (book)
  "Return the tabulated-list entry for BOOK.
A chapter row has only its kind, title and number of extracts."
  (list (readq--get book :id)
        (vconcat (mapcar (lambda (spec)
                           (or (cond ((not (readq--chapter-p book))
                                      (funcall (nth 4 spec) book))
                                     ((memq (car spec) '(kind title))
                                      (funcall (nth 4 spec) book))
                                     ((eq (car spec) 'extracts)
                                      (let ((n (readq--dashboard-extract-count book)))
                                        (if (> n 0) (number-to-string n) ""))))
                               ""))
                         (or readq--dashboard-shown-columns (readq--dashboard-columns))))))

(defun readq--dashboard-entries ()
  "Return all tabulated-list entries for the dashboard."
  (mapcar #'readq--dashboard-entry (readq--dashboard-tree)))

(defun readq--sorter (fn &optional lessp)
  "Return a tabulated-list sort predicate comparing items by FN.
LESSP compares the values, by default `<'.  Items stay under their
parents: only items under the same parent are compared."
  (let ((lessp (or lessp #'<)))
    (lambda (a b)
      (let ((pa (plist-get (gethash (car a) readq--dashboard-rows) :path))
            (pb (plist-get (gethash (car b) readq--dashboard-rows) :path))
            ;; tabulated-list sorts in reverse by swapping A and B, which
            ;; must still list parents first.
            (flip (cdr tabulated-list-sort-key)))
        (while (and pa pb (eq (car pa) (car pb)))
          (setq pa (cdr pa) pb (cdr pb)))
        (cond ((null pa) (not flip))      ; A is above B
              ((null pb) flip)            ; B is above A
              (t (let* ((chapter (or (readq--chapter-p (car pa)) (readq--chapter-p (car pb))))
                        ;; Chapter rows have no priority, due date...: they
                        ;; keep their order.
                        (va (unless chapter (funcall fn (car pa))))
                        (vb (unless chapter (funcall fn (car pb)))))
                   (cond ((and (not chapter) (funcall lessp va vb)) t)
                         ((and (not chapter) (funcall lessp vb va)) nil)
                         (t (let ((ra (plist-get (gethash (readq--get (car pa) :id)
                                                          readq--dashboard-rows)
                                                 :rank))
                                  (rb (plist-get (gethash (readq--get (car pb) :id)
                                                          readq--dashboard-rows)
                                                 :rank)))
                              (and ra rb (if flip (> ra rb) (< ra rb)))))))))))))

(defun readq--dashboard-summary ()
  "Return a summary string for the dashboard's mode line."
  (let* ((q (readq--queue nil nil readq--focus))
         (due (cl-count-if #'readq--due-p q))
         (due-x (cl-count-if (lambda (b) (and (readq--extract-p b) (readq--due-p b))) q)))
    (format " %d due (%d extracts), %d in queue%s%s%s" due due-x (length q)
            (let ((n (length (readq--stale-extracts readq--focus))))
              (if (> n 0) (format ", %d stale" n) ""))
            (concat (if readq--focus (concat " — focus: " (readq--tags-string-of readq--focus)) "")
                    (if readq--subset (concat " — reviewing " (readq--subset-string)) ""))
            (if (readq--budget-active-p)
                (let ((s (concat " — today " (readq--budget-string))))
                  (if (readq--budget-used-up-p) (propertize s 'face 'readq-over-budget-face) s))
              ""))))

(defvar readq-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'readq-dashboard-open)
    (define-key map "o" #'readq-dashboard-open)
    (define-key map "N" #'readq-next)
    (define-key map "a" #'readq-add-book)
    (define-key map "A" #'readq-add-directory)
    (define-key map "=" #'readq-set-priority)
    (define-key map "+" #'readq-priority-up)
    (define-key map "-" #'readq-priority-down)
    (define-key map "r" #'readq-reschedule)
    (define-key map "z" #'readq-postpone)
    (define-key map "F" #'readq-toggle-finished)
    (define-key map "x" #'readq-toggle-pause)
    (define-key map "t" #'readq-edit-title)
    (define-key map "l" #'readq-relocate)
    (define-key map "R" #'readq-read-aloud)
    (define-key map "D" #'readq-remove-book)
    (define-key map "H" #'readq-dashboard-toggle-finished)
    (define-key map "." #'readq-dashboard-toggle-extracts)
    (define-key map "E" #'readq-visit-extracts)
    (define-key map "i" #'readq-import-highlights)
    (define-key map "v" #'readq-set-viewer)
    (define-key map "g" #'readq-goto-source)
    (define-key map "G" #'revert-buffer)
    (define-key map "T" #'readq-add-sections)
    (define-key map "u" #'readq-add-url)
    (define-key map "U" #'readq-update-anki-cards)
    (define-key map "M" #'readq-set-media-toc)
    (define-key map "c" #'readq-mark-ready)
    (define-key map "C" #'readq-export-cards)
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
    (define-key map "%" #'readq-stats)
    (define-key map "'" #'readq-edit-extract)
    (define-key map "B" #'readq-restore-backup)
    (define-key map (kbd "TAB") #'readq-dashboard-toggle-fold)
    (define-key map (kbd "<backtab>") #'readq-dashboard-toggle-all-folds)
    map)
  "Keymap for `readq-dashboard-mode'.")

(define-derived-mode readq-dashboard-mode tabulated-list-mode "Reading Queue"
  "Major mode listing the books of your reading queue.

Books are listed in the order you should read them: books due today,
most important (lowest priority number) first, then upcoming books.
Sections and extracts are listed under their books, sub-extracts under
their extracts; TAB shows or hides them, S-TAB all of them.

\\{readq-dashboard-mode-map}"
  (setq tabulated-list-padding 1
        tabulated-list-entries #'readq--dashboard-entries
        mode-line-process '(:eval (readq--dashboard-summary)))
  (add-hook 'tabulated-list-revert-hook #'readq--dashboard-setup-columns nil t)
  (readq--dashboard-setup-columns))

(defun readq--dashboard-print ()
  "Redraw the dashboard in the current buffer."
  (readq--dashboard-setup-columns)
  (tabulated-list-print t))

;;;###autoload
(defun readq ()
  "Show the reading queue dashboard."
  (interactive)
  (unless readq-mode (readq-mode 1))
  (run-hooks 'readq-before-suggest-hook)
  (let ((buf (get-buffer-create "*readq*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'readq-dashboard-mode)
        (readq-dashboard-mode))
      (readq--dashboard-print))
    (pop-to-buffer-same-window buf)
    (readq-suggest)))

(defalias 'readq-list #'readq)

(defun readq--refresh-dashboard ()
  "Refresh the dashboard buffer if it exists."
  (when-let* ((buf (get-buffer "*readq*")))
    (with-current-buffer buf
      (when (derived-mode-p 'readq-dashboard-mode)
        (readq--dashboard-print)))))

(defun readq-dashboard-open ()
  "Open the book at point.  On a chapter, show or hide what is under it."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "No book on this line"))))
    (if (gethash id readq--chapters-by-id)
        (readq-dashboard-toggle-fold)
      (readq-open (readq--book-by-id id)))))

(defun readq-dashboard-toggle-extracts ()
  "Show or hide extracts in the dashboard."
  (interactive)
  (setq readq-dashboard-show-extracts (not readq-dashboard-show-extracts))
  (readq--dashboard-print)
  (message "%s extracts" (if readq-dashboard-show-extracts "Showing" "Hiding")))

(defun readq-dashboard-toggle-finished ()
  "Show or hide finished books in the dashboard."
  (interactive)
  (setq readq-dashboard-show-finished (not readq-dashboard-show-finished))
  (readq--dashboard-print)
  (message "%s finished books" (if readq-dashboard-show-finished "Showing" "Hiding")))

(provide 'readq-dashboard)
;;; readq-dashboard.el ends here
