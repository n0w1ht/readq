;;; readq-extract.el --- Making, storing and reviewing extracts -*- lexical-binding: t; -*-

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

(require 'readq-dashboard)

(defvar nov-documents-index)
(defvar readq-figures-directory)
(defvar readq-review-mode)
(declare-function readq--extract-pieces "readq-extract-tools")
(declare-function readq--decorate-extracts "readq-extract-tools")
(declare-function readq--edges-overlap "readq-extract-tools")
(declare-function pdf-canvas-annotate "ext:pdf-canvas" (type &optional contents color))
(declare-function pdf-canvas-save "ext:pdf-canvas" ())
(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function pdf-canvas-clear-selections "ext:pdf-canvas" ())
(declare-function pdf-canvas-selections "ext:pdf-canvas" ())
(declare-function pdf-canvas-region-image "ext:pdf-canvas" (page edges &optional dpi))
(declare-function readq--text-tail "readq-extract-tools")

;;;; Extracts

;; An extract is a passage of a book that becomes an item of its own in
;; the queue, with its own priority and schedule.  Its text lives in an
;; Org file, one per book, saved in ~/notes/ or next to the book (see
;; `readq-extracts-directory'):
;;
;;   * Systole is the phase of contraction of the ventricles, which…
;;   :PROPERTIES:
;;   :READQ_ID: 66f3a1b2c3d4
;;   :END:
;;   Source: [[readq:66f3a1b2c3d4][Gray's Anatomy, p. 57]]
;;   #+begin_quote
;;   Systole is the phase of contraction of the ventricles, which ejects
;;   blood into the aorta and pulmonary trunk.
;;   #+end_quote
;;
;; You can edit the heading and the text freely; readq finds the extract
;; again by its READQ_ID property.

(declare-function org-find-property "org" (property &optional value))
(declare-function org-narrow-to-subtree "org" (&optional element))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-current-level "org" ())
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading element))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-cut-subtree "org" (&optional n))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-show-subtree "org" ())
(declare-function org-fold-show-subtree "org-fold" ())
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function org-link-store-props "ol" (&rest plist))
(declare-function pdf-view-active-region-p "ext:pdf-view" ())
(declare-function pdf-view-active-region "ext:pdf-view" (&optional deactivate-p))
(declare-function pdf-view-active-region-text "ext:pdf-view" ())
(declare-function pdf-view-deactivate-region "ext:pdf-view" ())
(declare-function pdf-annot-add-markup-annotation "ext:pdf-annot"
                  (region type &optional color property-alist))
(declare-function pdf-info-getannots "ext:pdf-info" (&optional pages file-or-buffer))
(declare-function pdf-info-gettext "ext:pdf-info"
                  (page edges &optional selection-style file-or-buffer))
(declare-function pdf-info-close "ext:pdf-info" (&optional file-or-buffer))
(declare-function pdf-info-features "ext:pdf-info" ())

(defun readq--extract-at-point ()
  "Return the extract whose Org entry contains point, or nil."
  (when (derived-mode-p 'org-mode)
    (when-let* ((id (ignore-errors (org-entry-get nil "READQ_ID" t)))
                (item (readq--book-by-id id)))
      (and (readq--extract-p item) item))))

(defun readq--clean-text (text)
  "Join hyphenated line breaks and collapse whitespace in TEXT (from a PDF)."
  (let ((case-fold-search nil))
    (string-trim
     (replace-regexp-in-string
      "[ \t\n\r\f]+" " "
      (replace-regexp-in-string "\\([[:alpha:]]\\)-[ \t]*\n[ \t]*\\([[:lower:]]\\)"
                                "\\1\\2" (or text ""))))))

(defun readq--unfill (text)
  "Join the lines of each paragraph of TEXT, keeping paragraph breaks.
nov.el wraps lines with hard newlines; they do not belong in extracts."
  (mapconcat (lambda (para)
               (string-trim (replace-regexp-in-string "[ \t\n]+" " " para)))
             (split-string text "\n[ \t]*\n" t "[ \t\n]+")
             "\n\n"))

(defun readq--text-key (text)
  "Return a key identifying TEXT regardless of spacing and punctuation."
  (let ((letters (downcase (replace-regexp-in-string "[^[:alnum:]]+" "" (or text "")))))
    (and (> (length letters) 0) (md5 letters))))

(defun readq--extract-title (text)
  "Return a heading for an extract of TEXT, or nil if TEXT is blank."
  (let ((line (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))))
    (unless (string-empty-p line)
      (truncate-string-to-width line readq-extract-title-length nil nil "…"))))

(defun readq--source-description (book page &optional section)
  "Describe PAGE of BOOK, e.g. \"Title, p. 57\".
PAGE is a page, a chapter index (EPUB) or a section number (text and
web pages), where SECTION is the title of the section, if any."
  (let ((format (readq--get book :format)))
    (cond ((eq format 'media)
           (if page (format "%s, %s" (readq--get book :title) (readq--format-time page))
             (readq--get book :title)))
          ((and (readq--point-format-p format) section)
           (format "%s, %s" (readq--get book :title) section))
          ((readq--point-format-p format)
           (if (and page (> page 0))
               (format "%s, §%d" (readq--get book :title) page)
             (readq--get book :title)))
          (t (format "%s, %s" (readq--get book :title)
                     (cond ((null page) "start")
                           ((eq format 'epub) (format "ch. %d" (1+ page)))
                           (t (format "p. %d" page))))))))

(defun readq--slug (string)
  "Return STRING turned into a safe file name."
  (string-trim (truncate-string-to-width
                (downcase (replace-regexp-in-string "[^[:alnum:]]+" "-" string)) 60)
               "-+" "-+"))

(defun readq--extracts-file-of-p (file book)
  "Return non-nil when FILE is the extracts file readq made for BOOK."
  (with-temp-buffer
    (ignore-errors (insert-file-contents file nil 0 2000))
    (goto-char (point-min))
    (re-search-forward (concat "^#\\+READQ_BOOK: " (regexp-quote (readq--get book :id)) "$")
                       nil t)))

(defun readq--extracts-file-free-p (file book)
  "Return non-nil when BOOK may use FILE for its extracts.
FILE must not belong to another book, and must not be an existing
file that readq did not create for BOOK (such as your own notes)."
  (let ((name (abbreviate-file-name file)))
    (and (not (cl-some (lambda (b) (and (not (eq b book))
                                        (readq--same-file-p
                                         (readq--get b :extracts-file) name)))
                       (readq--books)))
         (or (not (file-exists-p file))
             (readq--extracts-file-of-p file book)))))

(defun readq--extracts-file (book)
  "Return the Org file holding BOOK's extracts, choosing one if needed.
See `readq-extracts-directory'."
  (or (readq--get book :extracts-file)
      (let* ((url (readq--url-p (readq--get book :file)))
             (book-dir (unless url
                         (file-name-directory (expand-file-name (readq--get book :file)))))
             (dir (cond (readq-extracts-directory)
                        ;; Online videos have no folder of their own.
                        (url readq-extracts-fallback-directory)
                        ((file-writable-p book-dir) book-dir)
                        (t (message "readq: cannot write in %s; extracts of \"%s\" go to %s"
                                    book-dir (readq--get book :title)
                                    readq-extracts-fallback-directory)
                           readq-extracts-fallback-directory)))
             (base (if (equal dir book-dir)
                       (file-name-sans-extension
                        (file-name-nondirectory (readq--get book :file)))
                     (readq--slug (readq--get book :title))))
             (base (if (string-empty-p base) (readq--get book :id) base))
             (n 0)
             (file (expand-file-name (concat base ".org") dir)))
        (while (not (readq--extracts-file-free-p file book))
          (setq n (1+ n)
                file (expand-file-name (if (= n 1) (format "%s-extracts.org" base)
                                         (format "%s-extracts-%d.org" base n))
                                       dir)))
        (readq--put book :extracts-file (abbreviate-file-name file))
        (readq--get book :extracts-file))))

(defun readq--set-extracts-file (book file)
  "Record FILE as the extracts file of BOOK and of all its extracts."
  (let ((name (abbreviate-file-name (expand-file-name file))))
    (readq--put book :extracts-file name)
    (dolist (x (readq--extracts-of book t))
      (readq--put x :file name))))

(defun readq--move-extracts-file (book old-book-file)
  "Keep BOOK's extracts file next to BOOK after it moved from OLD-BOOK-FILE.
Only an extracts file that was next to the old book file is moved.
Return the extracts file in use afterwards."
  (let ((xfile (readq--get book :extracts-file)))
    (when (and xfile
               (not (readq--url-p old-book-file))
               (not (readq--url-p (readq--get book :file)))
               (readq--same-file-p
                (file-name-directory (expand-file-name xfile))
                (file-name-directory (expand-file-name old-book-file))))
      (let ((new (expand-file-name (file-name-nondirectory xfile)
                                   (file-name-directory
                                    (expand-file-name (readq--get book :file))))))
        (cond
         ((readq--same-file-p (expand-file-name xfile) new))
         ;; The whole folder moved: the extracts file is already there.
         ((and (file-exists-p new) (readq--extracts-file-of-p new book))
          (readq--set-extracts-file book new))
         ((and (file-exists-p xfile) (not (file-exists-p new)))
          (let ((buf (find-buffer-visiting xfile)))
            (when (and buf (buffer-modified-p buf))
              (with-current-buffer buf (save-buffer)))
            (rename-file xfile new)
            (when buf
              (with-current-buffer buf (set-visited-file-name new t t))))
          (readq--set-extracts-file book new)
          (message "Moved the extracts of \"%s\" to %s" (readq--get book :title) new))
         ((file-exists-p xfile)
          (message "readq: %s exists; the extracts of \"%s\" stay in %s"
                   new (readq--get book :title) xfile)))))
    (readq--get book :extracts-file)))

(defun readq--extracts-buffer (file book)
  "Return a buffer visiting the extracts FILE of BOOK."
  (require 'org)
  (make-directory (file-name-directory (expand-file-name file)) t)
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (when (= (buffer-size) 0)
        (insert (format "#+TITLE: Extracts from %s\n#+READQ_BOOK: %s\n#+STARTUP: overview\n\n"
                        (readq--get book :title) (readq--get book :id)))))
    buf))

(defun readq--org-escape (text)
  "Escape lines of TEXT that Org would read as syntax inside a block."
  (replace-regexp-in-string "^\\([ \t]*\\)\\(,*\\(?:\\*\\|#\\+\\)\\)" "\\1,\\2" text))

(defun readq--org-unescape (text)
  "Undo `readq--org-escape' on TEXT and drop quote block delimiters."
  (string-trim
   (replace-regexp-in-string
    "^\\([ \t]*\\),\\(,*\\(?:\\*\\|#\\+\\)\\)" "\\1\\2"
    (replace-regexp-in-string "^[ \t]*#\\+\\(begin\\|end\\)_quote.*\n?" "" text))))

(defun readq--extract-heading (item book text level comment &optional body)
  "Return the Org text of extract ITEM of BOOK at heading LEVEL.
TEXT is the extracted passage and COMMENT an optional note.  BODY, if
given, is the Org text written in place of TEXT's quote."
  (let ((id (readq--get item :id)))
    (concat (make-string level ?*) " " (readq--get item :title) "\n"
            ":PROPERTIES:\n:READQ_ID: " id "\n:END:\n"
            "Source: [[readq:" id "]["
            (readq--source-description book (readq--get item :page)
                                       (readq--get item :section))
            "]]\n"
            (if (readq--get item :figure)
                (concat "[[file:" (readq--get item :figure) "]]\n")
              "")
            (cond (body body)
                  ((string-empty-p text) "")
                  (t (readq--quote-block text)))
            (if (and comment (not (string-empty-p (string-trim comment))))
                (concat "Note: " (string-trim comment) "\n")
              "")
            "\n")))

(defun readq--quote-block (text)
  "Return TEXT as an Org quote block."
  (concat "#+begin_quote\n" (readq--org-escape text) "\n#+end_quote\n"))

(defun readq--insert-extract-heading (item book text comment parent &optional body)
  "Write extract ITEM of BOOK to its Org file, as a child of PARENT if any.
Otherwise ITEM goes under the heading of the chapter it was made in
\(see `readq-chapter-depth').  TEXT is the passage and COMMENT an
optional note; BODY is as in `readq--extract-heading'."
  (let ((path (and (not parent) (readq--extract-chapter-path book item))))
    (with-current-buffer (readq--extracts-buffer (readq--get item :file) book)
      (save-excursion
        (save-restriction
          (widen)
          (let ((level 1)
                (ppos (and parent (org-find-property "READQ_ID" (readq--get parent :id)))))
            (cond
             (ppos
              (goto-char ppos)
              (setq level (1+ (or (org-current-level) 0)))
              (org-end-of-subtree t t))
             (path (setq level (1+ (readq--goto-chapter-place book path))))
             (t (goto-char (point-max))))
            (unless (bolp) (insert "\n"))
            (insert (readq--extract-heading item book text level comment body)))))
      (let ((save-silently t)) (save-buffer)))))

;;;;; Chapters in extracts files

;; In a book's extracts file, an extract made right from the book goes
;; under a heading for the chapter it was made in, as in the dashboard
;; (see `readq--book-chapters'): one level of headings for each level
;; of the table of contents, up to `readq-chapter-depth'.  A chapter
;; heading has a READQ_CHAPTER property, and is made when its first
;; extract is; chapters come in book order, and in each chapter its own
;; extracts come before its sub-chapters.

(defun readq--extract-chapter-path (book x)
  "Return the chapters of BOOK the extract X was made in, outermost first.
They are chapter rows (see `readq--book-chapters'), down to the
level of `readq-chapter-depth'.  nil when BOOK has no table of contents
or X is in none of its chapters."
  (when-let* ((nodes (readq--book-chapters book))
              (i (readq--chapter-within-depth
                  nodes (readq--extract-chapter-index book nodes x))))
    (let (path)
      (while i
        (push (aref nodes i) path)
        (setq i (plist-get (aref nodes i) :up)))
      path)))

(defun readq--chapter-key (chapter)
  "Return the value of the READQ_CHAPTER property of CHAPTER's heading."
  (if (plist-get chapter :heading)
      (format "%s #%d" (plist-get chapter :heading) (or (plist-get chapter :occurrence) 1))
    (format "%s %s" (plist-get chapter :start) (plist-get chapter :title))))

(defun readq--chapter-headings (level beg end)
  "Return the chapter headings at LEVEL between BEG and END, as (POS . KEY)."
  (let ((re (format "^\\*\\{%d\\} " level))
        result)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward re end t)
        (let ((pos (line-beginning-position)))
          (when-let* ((key (org-entry-get pos "READQ_CHAPTER")))
            (push (cons pos key) result)))))
    (nreverse result)))

(defun readq--goto-chapter-place (book path)
  "Go to where a new extract in the chapter PATH of BOOK goes; return its level.
PATH is from `readq--extract-chapter-path'.  The headings of the
chapters in PATH are made where missing, in book order, before the
extracts that are in no chapter.  The extract goes after what the last
chapter holds, before its first sub-chapter."
  (let* ((nodes (readq--book-chapters book))
         (order (lambda (key) (or (cl-position key nodes :key #'readq--chapter-key
                                               :test #'equal)
                                  most-positive-fixnum)))
         (beg (point-min)) (end (point-max)) (level 0))
    (dolist (chapter path)
      (setq level (1+ level))
      (let* ((key (readq--chapter-key chapter))
             (siblings (readq--chapter-headings level beg end))
             (pos (car (rassoc key siblings))))
        (unless pos
          (let* ((n (funcall order key))
                 (next (cl-find-if (lambda (s) (> (funcall order (cdr s)) n)) siblings)))
            (goto-char (cond (next (car next))
                             ((> level 1) end)
                             ;; At the top, extracts in no chapter come last.
                             (siblings (save-excursion
                                         (goto-char (car (car (last siblings))))
                                         (org-end-of-subtree t t)
                                         (point)))
                             (t (save-excursion
                                  (goto-char beg)
                                  (if (re-search-forward "^\\* " end t)
                                      (line-beginning-position)
                                    end)))))
            (unless (bolp) (insert "\n"))
            (setq pos (point))
            (insert (make-string level ?*) " " (plist-get chapter :title) "\n"
                    ":PROPERTIES:\n:READQ_CHAPTER: " key "\n:END:\n\n")))
        (goto-char pos)
        (setq beg pos
              end (save-excursion (org-end-of-subtree t t) (point)))))
    (goto-char (or (car (car (readq--chapter-headings (1+ level) beg end))) end))
    level))

(defun readq--prune-chapter-headings (pos)
  "Delete the chapter headings that held an entry just deleted at POS.
Only those left without any extract are deleted."
  (save-excursion
    (goto-char pos)
    (unless (bobp) (backward-char))
    (let ((done nil))
      (while (and (not done)
                  (ignore-errors (org-back-to-heading t) t)
                  (org-entry-get nil "READQ_CHAPTER"))
        (let ((beg (point))
              (end (save-excursion (org-end-of-subtree t t) (point))))
          (if (save-excursion (re-search-forward "^[ \t]*:READQ_ID:" end t))
              (setq done t)
            (delete-region beg end)
            (if (bobp) (setq done t) (goto-char (1- beg)))))))))

;;;###autoload
(defun readq-group-extracts (book)
  "Group the extracts in BOOK's extracts file under its chapters.
New extracts are put under the chapter they were made in by
themselves (see `readq-chapter-depth'); this moves the ones made
before, with their sub-extracts and notes, under chapter headings
taken from BOOK's table of contents.  Return how many were moved."
  (interactive (list (let ((b (readq--target-book "Group the extracts of: ")))
                       (readq--item-book b))))
  (let* ((file (readq--get book :extracts-file))
         (moved 0))
    (unless (and file (file-exists-p file))
      (user-error "\"%s\" has no extracts file" (readq--get book :title)))
    (unless (and (readq--book-chapters book)
                 (> (length (readq--book-chapters book)) 0))
      (user-error "No table of contents found in \"%s\"" (readq--get book :title)))
    (with-current-buffer (readq--extracts-buffer file book)
      (save-excursion
        (save-restriction
          (widen)
          (let (ids)
            (goto-char (point-min))
            (while (re-search-forward "^\\* " nil t)
              (when-let* ((id (org-entry-get (line-beginning-position) "READQ_ID")))
                (push id ids)))
            (dolist (id (nreverse ids))
              (let* ((x (readq--book-by-id id))
                     (path (and x (readq--extract-chapter-path book x))))
                (when path
                  (goto-char (org-find-property "READQ_ID" id))
                  (let* ((beg (point))
                         (end (save-excursion (org-end-of-subtree t t) (point)))
                         (tree (buffer-substring beg end)))
                    (delete-region beg end)
                    (let ((level (readq--goto-chapter-place book path)))
                      (unless (bolp) (insert "\n"))
                      (insert (replace-regexp-in-string
                               "^\\*+ " (lambda (m) (concat (make-string level ?*) m))
                               (if (string-suffix-p "\n" tree) tree (concat tree "\n"))
                               t t)))
                    (cl-incf moved)))))))
        (let ((save-silently t)) (save-buffer))))
    (message "Grouped %d extract%s of \"%s\" under its chapters"
             moved (if (= moved 1) "" "s") (readq--get book :title))
    moved))

(cl-defun readq--create-extract (source text &key page point edges comment color
                                        priority ask section parts tags figure title
                                        body figures)
  "Create an extract of TEXT from SOURCE (a book or a parent extract).
PAGE is the page (PDF) or chapter index (EPUB); POINT the position in
an EPUB chapter or text; EDGES the PDF areas of the passage; SECTION
the heading of the passage in a text or web page.  PARTS describes the
passages of an extract made of several selections, as plists
\(:page :point :edges :key :snippet :length).  TAGS are the extract's
own tags (it also has its book's).  COMMENT is a note
and COLOR the highlight color.  FIGURE is the image file of a
figure extract, relative to the extracts file; TITLE overrides the
heading.  BODY is Org text written instead of TEXT's quote, for an
extract of passages and pictures, and FIGURES the image files it
links.  PRIORITY defaults to SOURCE's priority
plus `readq-extract-priority-offset'; with ASK, it is read from the
user.  Return the new extract."
  (let* ((parent (and (readq--extract-p source) source))
         (book (if parent (readq--book-by-id (readq--get parent :book)) source))
         (default (min 100 (max 0 (+ (readq--get source :priority)
                                     readq-extract-priority-offset))))
         (priority (cond (priority (min 100 (max 0 priority)))
                         (ask (readq--read-priority default))
                         (t default)))
         (text (or text ""))
         (item (list :id (readq--new-id)
                     :format 'extract
                     :book (readq--get book :id)
                     :parent (and parent (readq--get parent :id))
                     :title (or title
                                (readq--extract-title text)
                                (if (eq (readq--get book :format) 'media)
                                    (format "%s at %s" (readq--get book :title)
                                            (readq--format-time page))
                                  (format "Highlight on %s"
                                          (readq--source-description book page section))))
                     :file (readq--extracts-file book)
                     :priority priority
                     :status 'active
                     :added (readq--today)
                     :due (readq--date-in readq-extract-initial-interval)
                     :interval (float (max readq-min-interval
                                           readq-extract-initial-interval))
                     :page page :point point :edges edges :section section
                     :parts parts :tags tags :figure figure
                     :key (readq--text-key text)
                     :snippet (truncate-string-to-width text 300)
                     :tail (readq--text-tail text)
                     :length (length text)
                     :color color
                     :sessions 0 :last-read nil :history nil)))
    (when figures (setq item (append item (list :figures figures))))
    (readq--insert-extract-heading item book text comment parent body)
    (setq readq--books (append (readq--books) (list item)))
    (readq--save)
    (readq--refresh-dashboard)
    item))

;;;###autoload
(defun readq-extract (&optional arg)
  "Turn the selected text into an extract.
Works in a PDF (pdf-tools or pdf-canvas), an EPUB (nov.el), a text book (Org,
Markdown, plain text), a web page in eww, and inside an extract being
reviewed (making a sub-extract).

Several passages can be selected at once with multi-region
\(`multi-region-mode') or, in a PDF, with C-drag; they become one
extract, see `readq-extract-multiple'.

With multi-region 0.4 or later, pictures can be selected with the
passages (in a PDF, with M-drag); they are saved in
`readq-figures-directory' and linked in the extract where they were.

The extract inherits the priority of its source.  With one
\\[universal-argument] (ARG), ask for the priority.  With two, handle several
selections the other way than `readq-extract-multiple' says.  Return
the extract, or the list of extracts when several were made."
  (interactive "P")
  (let* ((ask (equal arg '(4)))
         (mode (if (equal arg '(16))
                   (if (eq readq-extract-multiple 'separate) 'combine 'separate)
                 readq-extract-multiple))
         (items
          (cond
           ((derived-mode-p 'pdf-view-mode 'pdf-canvas-mode)
            (readq--extract-from-pdf ask mode))
           ((derived-mode-p 'readq-comic-mode)
            (user-error "A comic has no text to extract; take the page as a figure with `readq-extract-figure'"))
           ((or (derived-mode-p 'nov-mode)
                (and readq-book-mode
                     (readq--point-format-p (readq--get (readq--buffer-book) :format))))
            (readq--extract-from-text ask mode))
           ((readq--extract-at-point) (readq--extract-from-org ask mode))
           (t (user-error "Select text in a book from your queue or in an extract first")))))
    (if (cdr items)
        (message "%d extracts created with priority %s, due %s"
                 (length items) (readq--get (car items) :priority)
                 (readq--get (car items) :due))
      (message "Extract created with priority %s, due %s: %s"
               (readq--get (car items) :priority) (readq--get (car items) :due)
               (readq--get (car items) :title)))
    (if (cdr items) items (car items))))

(defun readq--source-book-here ()
  "Return the queued book shown in this buffer, or signal an error."
  (or (readq--buffer-book)
      (user-error "Add this book to your queue first (`readq-add-book')")))

;;;;; Figures

;; A figure extract is an image: a diagram cropped from a PDF page, an
;; image of an EPUB, web page, Org or Markdown book, a frame of a video,
;; or whatever you copied in SumatraPDF.  The image is saved in
;; `readq-figures-directory' and shown in the extract's Org entry; the
;; extract is reviewed, tagged and scheduled like any other.

(defcustom readq-figures-directory "~/notes/readq-figures/"
  "The folder where readq saves the images of all figure extracts.
Their names give the book, the date and time they were taken, and the
page, so that the figures of each book sort by date:
guyton-physiology_2026-10-07_221346_p112.png."
  :type 'directory
  :group 'readq-extracts)

(defcustom readq-figure-dpi 200
  "Resolution, in dots per inch, of figures cropped from PDF pages."
  :type 'integer
  :group 'readq-extracts)

(defcustom readq-ask-figure-caption t
  "When non-nil, ask for a caption when you capture a figure.
The caption becomes the extract's heading; leave it empty for a default
one.  Figures marked in mpv never ask."
  :type 'boolean
  :group 'readq-extracts)

(defcustom readq-figure-display-width 600
  "Width in pixels at which figures are shown while reviewing, or nil.
nil leaves `org-image-actual-width' alone."
  :type '(choice (const :tag "As Org decides" nil) integer)
  :group 'readq-extracts)

(defvar org-image-actual-width)
(declare-function org-display-inline-images "org" (&optional include-linked refresh beg end))
(declare-function pdf-info-pagesize "pdf-info" (page &optional file-or-buffer))
(defvar pdf-view-use-scaling)
(declare-function image-search-load-path "image" (file &optional path))

(defconst readq--image-extensions '("png" "jpg" "jpeg" "gif" "svg" "webp" "bmp" "tif" "tiff")
  "File extensions of images readq can take as figures.")

(defun readq--figure-place (book page)
  "Return a short label of PAGE of BOOK for a figure's file name, or nil."
  (let ((format (readq--get book :format)))
    (cond ((null page) nil)
          ((eq format 'media)
           (let* ((s (floor page)) (h (/ s 3600)) (m (/ (% s 3600) 60)))
             (if (> h 0) (format "%dh%02dm%02ds" h m (% s 60))
               (format "%02dm%02ds" m (% s 60)))))
          ((eq format 'epub) (format "ch%d" (1+ page)))
          ((readq--point-format-p format) (and (> page 0) (format "s%d" page)))
          (t (format "p%d" page)))))

(defun readq--figure-name (book page ext &optional time)
  "Return a new file name in `readq-figures-directory' for a figure.
The name gives BOOK, then TIME (default now), then PAGE, so that the
figures of a book sort by date: guyton-physiology_2026-10-07_221346_p112.png.
EXT is the file extension."
  (let* ((dir (file-name-as-directory (expand-file-name readq-figures-directory)))
         (slug (let ((slug (readq--slug (readq--get book :title))))
                 (and (not (string-empty-p slug)) (truncate-string-to-width slug 40))))
         (stamp (format-time-string "%Y-%m-%d_%H%M%S" time))
         (place (readq--figure-place book page))
         (name (lambda (suffix)
                 (expand-file-name
                  (concat (mapconcat #'identity (delq nil (list slug (concat stamp suffix) place))
                                     "_")
                          "." ext)
                  dir)))
         (file (funcall name ""))
         (n ?a))
    ;; Several in the same second get b, c, ... after the time, which
    ;; keeps them in order: 221346_p1 sorts before 221346b_p1.
    (while (file-exists-p file)
      (setq n (1+ n)
            file (funcall name (if (<= n ?z) (string n) (format "z%d" (- n ?z))))))
    file))

(defun readq--figure-file (item &optional rel)
  "Return the absolute file name of figure extract ITEM's image, or nil.
The image is recorded by its full name, or relative to the extracts
file.  If it is not there, it is looked for by name in
`readq-figures-directory', in case that folder moved.  With REL, return
the absolute name of that image of ITEM instead."
  (when-let* ((rel (or rel (readq--get item :figure))))
    (let ((file (expand-file-name rel (file-name-directory
                                       (expand-file-name (readq--get item :file))))))
      (if (file-exists-p file)
          file
        (let ((moved (expand-file-name (file-name-nondirectory file) readq-figures-directory)))
          (if (file-exists-p moved) moved file))))))

(defun readq--figure-files (item)
  "Return the absolute names of all images saved for extract ITEM.
That is the image of a figure extract, or the pictures of an extract
made of passages and pictures."
  (delq nil (cons (readq--figure-file item)
                  (mapcar (lambda (rel) (readq--figure-file item rel))
                          (readq--get item :figures)))))

(defun readq--image-type-extension (type)
  "Return a file extension for the image TYPE (a symbol), default png."
  (pcase type
    ('jpeg "jpg") ('svg "svg") ('gif "gif") ('webp "webp") ('tiff "tif") ('bmp "bmp")
    (_ "png")))

(cl-defun readq--create-figure (source image &key page point section caption
                                       priority ask tags time)
  "Create a figure extract of SOURCE (a book or an extract).
IMAGE is (:file FILE), copied, or (:data DATA :type TYPE), written into
`readq-figures-directory'.  PAGE, POINT and SECTION locate it as for
`readq--create-extract'; CAPTION is its heading; TIME is when it was
taken, by default now.  Return the new extract."
  (let* ((book (if (readq--extract-p source) (readq--item-book source) source))
         (file (readq--save-figure-image book page image time)))
    (readq--create-extract
     source "" :page page :point point :section section
     :priority priority :ask ask :tags tags
     :figure (abbreviate-file-name file)
     :title (if (and caption (not (string-empty-p (string-trim caption))))
                (string-trim caption)
              (format "Figure: %s"
                      (if (eq (readq--get book :format) 'media)
                          (format "%s at %s" (readq--get book :title) (readq--format-time page))
                        (readq--source-description book page section)))))))

(defun readq--save-figure-image (book page image &optional time)
  "Save IMAGE of BOOK's PAGE in `readq-figures-directory'; return its name.
IMAGE is (:file FILE), copied, or (:data DATA :type TYPE).  TIME, by
default now, goes in the name, see `readq--figure-name'."
  (let* ((ext (or (and (plist-get image :file)
                       (let ((e (file-name-extension (plist-get image :file))))
                         (and e (downcase e))))
                  (readq--image-type-extension (plist-get image :type))))
         (file (readq--figure-name book page ext time)))
    (make-directory (file-name-directory file) t)
    (if (plist-get image :file)
        (copy-file (plist-get image :file) file t)
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file file
          (set-buffer-multibyte nil)
          (insert (plist-get image :data)))))
    file))

(defun readq--read-caption ()
  "Ask for a figure's caption when `readq-ask-figure-caption' says so."
  (and readq-ask-figure-caption
       (read-string "Caption (empty for none): ")))

;;;;;; Finding the image

(defun readq--image-spec-p (x)
  "Return non-nil when X is an image descriptor."
  (and (consp x) (eq (car x) 'image)))

(defun readq--display-image (display)
  "Return the image in the `display' property value DISPLAY, if any."
  (cond ((readq--image-spec-p display) display)
        ((and (consp display) (not (keywordp (car display))))
         (cl-find-if #'readq--image-spec-p display))))

(defun readq--image-at (pos)
  "Return the image shown at POS, as a descriptor, or nil."
  (or (readq--display-image (get-text-property pos 'display))
      (cl-some (lambda (ov) (readq--display-image (overlay-get ov 'display)))
               (overlays-at pos))))

(defun readq--image-file-link-at-point ()
  "Return the image file of the Org or Markdown link at point, or nil.
Without one at point, take the first image link on this line."
  (let* ((re (concat "\\[\\[\\(?:file:\\)?\\([^]]+\\)\\]\\(?:\\[[^]]*\\]\\)?\\]"
                     "\\|!\\[[^]]*\\](<?\\([^)> ]+\\)[^)]*)"))
         (pos (point))
         links)
    (save-excursion
      (beginning-of-line)
      (while (re-search-forward re (line-end-position) t)
        (let ((file (or (match-string-no-properties 1) (match-string-no-properties 2))))
          (when (and (member (downcase (or (file-name-extension file) ""))
                             readq--image-extensions)
                     (not (string-match-p "\\`[a-z]+://" file)))
            (push (list (match-beginning 0) (match-end 0) file) links)))))
    (setq links (nreverse links))
    (when-let* ((link (or (cl-find-if (lambda (l) (<= (car l) pos (cadr l))) links)
                         (car links))))
      (expand-file-name (caddr link)))))

(defun readq--image-here ()
  "Return (POS . IMAGE) for the image at point, in the region or on this line.
IMAGE is (:file FILE) or (:data DATA :type TYPE).  Return nil if none."
  (let* ((candidates
          (append (list (point) (max (point-min) (1- (point))))
                  (and (use-region-p)
                       (number-sequence (region-beginning) (1- (region-end))))
                  (number-sequence (line-beginning-position)
                                   (max (line-beginning-position) (1- (line-end-position))))))
         (pos (cl-find-if #'readq--image-at candidates)))
    (cond
     (pos
      (let* ((spec (cdr (readq--image-at pos)))
             (file (plist-get spec :file)))
        (cons pos
              (if (and file (file-exists-p (setq file (if (file-name-absolute-p file) file
                                                       (image-search-load-path file)))))
                  (list :file file)
                (list :data (plist-get spec :data) :type (plist-get spec :type))))))
     ((readq--image-file-link-at-point)
      (cons (point) (list :file (readq--image-file-link-at-point)))))))

(defun readq--figure-from-text ()
  "Create a figure extract from the image at point in a text-like book."
  (let* ((book (readq--source-book-here))
         (found (or (readq--image-here)
                    (user-error "Put point on an image (or an image link) first")))
         (pos (car found))
         (nov (derived-mode-p 'nov-mode))
         (point-book (readq--point-format-p (readq--get book :format))))
    (when (and (null (plist-get (cdr found) :file)) (null (plist-get (cdr found) :data)))
      (user-error "This image is not loaded yet"))
    (readq--create-figure book (cdr found)
                          :page (cond (nov nov-documents-index)
                                      (point-book (readq--section-number pos)))
                          :point pos
                          :section (and point-book (readq--section-at pos))
                          :caption (readq--read-caption)
                          :ask current-prefix-arg)))

(declare-function pdf-info-renderpage "pdf-info")

(defun readq--pdf-crop (file page edges)
  "Return PNG data of the area EDGES (relative) of PAGE of the PDF FILE.
In a pdf-canvas buffer the PDF shown there is used, and FILE ignored."
  (if (derived-mode-p 'pdf-canvas-mode)
      (pdf-canvas-region-image page edges readq-figure-dpi)
    (require 'pdf-info)
    (require 'pdf-util)
    (let* ((size (pdf-info-pagesize page file))
           (width (round (* (car size) (/ readq-figure-dpi 72.0))))
           ;; Exactly `readq-figure-dpi', whatever the screen's scaling.
           (pdf-view-use-scaling nil))
      (pdf-info-renderpage page width file :crop-to edges))))

(defun readq--edges-union (edges-list)
  "Return the smallest edges containing all of EDGES-LIST."
  (list (apply #'min (mapcar #'car edges-list))
        (apply #'min (mapcar #'cadr edges-list))
        (apply #'max (mapcar #'caddr edges-list))
        (apply #'max (mapcar #'cadddr edges-list))))

(defun readq--figure-from-pdf ()
  "Create a figure extract from the area selected on this PDF page.
Select the area with M-drag (a rectangle) or drag over text; without a
selection, offer the whole page."
  (let* ((book (readq--source-book-here))
         (canvas (derived-mode-p 'pdf-canvas-mode))
         ;; In pdf-canvas, the page of the selection made last, and what
         ;; is selected on that page.
         (last (and canvas
                    (car (sort (pdf-canvas-selections)
                               (lambda (a b) (> (plist-get a :index)
                                                (plist-get b :index)))))))
         (region (if canvas
                     (and last
                          (cons (plist-get last :page)
                                (mapcar (lambda (s) (plist-get s :edges))
                                        (cl-remove-if-not
                                         (lambda (s) (eql (plist-get s :page)
                                                          (plist-get last :page)))
                                         (pdf-canvas-selections)))))
                   (and (pdf-view-active-region-p) (pdf-view-active-region))))
         (page (if (and region (numberp (car region))) (car region)
                 (readq--pdf-page-here)))
         (edges (cond ((null region) nil)
                      ((numberp (car region)) (cdr region))
                      (t region))))
    (unless (or edges (y-or-n-p "No area selected (M-drag selects one).  Take the whole page? "))
      (user-error "Select the figure with M-drag first"))
    (let* ((box (if edges (readq--edges-union edges) '(0 0 1 1)))
           (data (readq--pdf-crop (readq--get book :file) page box))
           (x (readq--create-figure book (list :data data :type 'png)
                                    :page page
                                    :caption (readq--read-caption)
                                    :ask current-prefix-arg)))
      (readq--put x :figure-edges box)
      (when region
        (if canvas
            (pdf-canvas-clear-selections)
          (pdf-view-deactivate-region)))
      x)))

;;;;;; From the clipboard (SumatraPDF...)

(defun readq--clipboard-image ()
  "Return (:data DATA :type TYPE) for an image on the clipboard, or nil."
  (or
   (cl-some (lambda (type)
              (let ((data (ignore-errors (gui-get-selection 'CLIPBOARD type))))
                (and (stringp data) (> (length data) 0)
                     (list :data (if (multibyte-string-p data)
                                     (encode-coding-string data 'no-conversion)
                                   data)
                           :type (intern (cadr (split-string (symbol-name type) "/")))))))
            '(image/png image/jpeg))
   (when (eq system-type 'windows-nt)
     (let ((tmp (make-temp-file "readq-clip" nil ".png")))
       (unwind-protect
           (when (and (eql 0 (call-process
                              "powershell" nil nil nil "-NoProfile" "-STA" "-Command"
                              (format "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; \
$i = [System.Windows.Forms.Clipboard]::GetImage(); \
if ($i) { $i.Save('%s', [System.Drawing.Imaging.ImageFormat]::Png); exit 0 } else { exit 1 }"
                                      (replace-regexp-in-string
                                       "'" "''" (convert-standard-filename tmp)))))
                      (> (or (file-attribute-size (file-attributes tmp)) 0) 0))
             (list :data (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally tmp)
                           (buffer-string))
                   :type 'png))
         (delete-file tmp))))))

;;;###autoload
(defun readq-extract-figure-from-clipboard (book page)
  "Make a figure extract of BOOK from the image on the clipboard.
Use it with SumatraPDF: select the figure by dragging with Ctrl held
down, copy it with Ctrl+C, and run this.  PAGE is the page it is on."
  (interactive
   (let* ((ext (and readq--external-session
                    (readq--book-by-id (plist-get readq--external-session :id))))
          (book (or ext (readq--buffer-book) (readq--target-book "Figure of: "))))
     (list book
           (and (not (eq (readq--get book :format) 'media))
                (read-number "Page of the figure: " (or (readq--get book :page) 1))))))
  (let ((image (or (readq--clipboard-image)
                   (user-error "No image on the clipboard; copy the figure first"))))
    (readq--create-figure book image :page page :caption (readq--read-caption))))

;;;;;; From audio and video

(defun readq--media-frame (book time)
  "Return the PNG file of the frame of media BOOK at TIME, or nil.
The file is in a temporary folder; delete it after use."
  (let ((dir (make-temp-file "readq-frame" t)))
    (apply #'call-process (readq--mpv-program) nil nil nil
           (append (list "--no-config" "--no-audio" "--really-quiet"
                         (format "--start=%.3f" time) "--frames=1"
                         "--vo=image" "--vo-image-format=png"
                         (concat "--vo-image-outdir=" dir))
                   (readq--mpv-ytdl-args)
                   (list "--" (readq--media-target book))))
    (let ((files (directory-files dir t "\\.png\\'")))
      (if files (car files)
        (delete-directory dir t)
        nil))))

(defun readq--figure-from-media ()
  "Capture the frame playing in mpv as a figure extract."
  (let* ((session readq--media-session)
         (item (readq--book-by-id (plist-get session :id)))
         (book (readq--item-book item))
         (time (or (plist-get session :time)
                   (user-error "mpv has not reported a position yet")))
         (frame (or (readq--media-frame book time)
                    (user-error "No picture at %s (is it audio only?)"
                                (readq--format-time time)))))
    (unwind-protect
        (readq--create-figure book (list :file frame) :page time :point time
                              :caption (readq--read-caption)
                              :tags (and (readq--section-p item) (readq--get item :tags)))
      (delete-directory (file-name-directory frame) t))))

;;;###autoload
(defun readq-extract-figure (&optional arg)
  "Turn a figure into an extract: an image you review like a passage.
- In a PDF (pdf-tools): the area selected with M-drag, cropped from the
  page at `readq-figure-dpi'; without a selection, the whole page.
- In a comic: the page shown.
- In an EPUB (nov.el), a web page (eww), or an Org, Markdown or HTML
  book: the image at point (or in the region, or on this line); in
  Org and Markdown also an image link.
- While a video plays in mpv: the frame playing now.  In mpv itself,
  `readq-mpv-figure-key' does the same.
- Reading in SumatraPDF, or anywhere else: the image on the clipboard, see
  `readq-extract-figure-from-clipboard'.
With a prefix argument (ARG), ask for the priority.  Return the extract."
  (interactive "P")
  (let* ((current-prefix-arg arg)
         (x (cond
             ((and (derived-mode-p 'pdf-view-mode 'pdf-canvas-mode)
                   (readq--buffer-book))
              (readq--figure-from-pdf))
             ((derived-mode-p 'readq-comic-mode) (readq--figure-from-comic))
             ((and (readq--buffer-book)
                   (or (derived-mode-p 'nov-mode 'eww-mode)
                       (readq--point-format-p (readq--get (readq--buffer-book) :format))))
              (readq--figure-from-text))
             ((readq--media-playing-p) (readq--figure-from-media))
             (t (call-interactively #'readq-extract-figure-from-clipboard)))))
    (message "Figure extract created with priority %s, due %s: %s"
             (readq--get x :priority) (readq--get x :due) (readq--get x :title))
    x))

(defun readq--show-figures ()
  "Show the images of the extract being reviewed, if this Emacs can."
  (when (display-images-p)
    (let ((org-image-actual-width (if readq-figure-display-width
                                      (list readq-figure-display-width)
                                    org-image-actual-width)))
      ;; Org 9.8 renamed `org-display-inline-images'; same arguments
      (if (fboundp 'org-link-preview-region)
          (org-link-preview-region nil t (point-min) (point-max))
        (with-no-warnings
          (org-display-inline-images nil t (point-min) (point-max)))))))

;;;;;; Figures in flashcards

(defconst readq--image-link-re
  (concat "\\[\\[\\(?:file:\\)?\\([^]]+\\.\\(?:"
          (regexp-opt readq--image-extensions)
          "\\)\\)\\]\\(?:\\[[^]]*\\]\\)?\\]")
  "Regexp matching an Org link to an image; group 1 is the file.")

(defun readq--card-directory (card)
  "Return the folder that CARD's relative image links start from."
  (file-name-directory (expand-file-name (readq--get (plist-get card :item) :file))))

(defun readq--card-images (card)
  "Return the image files linked in CARD's text, as absolute names."
  (let ((text (plist-get card :text))
        (dir (readq--card-directory card))
        (start 0) files)
    (while (string-match readq--image-link-re text start)
      (push (expand-file-name (match-string 1 text) dir) files)
      (setq start (match-end 0)))
    (nreverse files)))

(defun readq--anki-media-name (file)
  "Return the name of the image FILE in Anki's media folder."
  (concat "readq-" (file-name-nondirectory file)))

(defun readq--images-for-anki (text dir)
  "Replace the image links of TEXT (relative to DIR) by HTML img tags."
  (replace-regexp-in-string
   readq--image-link-re
   (lambda (m)
     (save-match-data
       (string-match readq--image-link-re m)
       (format "@@html:<img src=\"%s\">@@"
               (readq--anki-media-name (expand-file-name (match-string 1 m) dir)))))
   text t t))

(defun readq--images-for-org (text dir)
  "Make the image links of TEXT (relative to DIR) absolute.
Return (TEXT . LINKS): in TEXT the links are replaced by placeholders,
so that cloze conversion leaves them alone; LINKS are the links in order."
  (let (links)
    (cons (replace-regexp-in-string
           readq--image-link-re
           (lambda (m)
             (save-match-data
               (string-match readq--image-link-re m)
               (push (format "[[file:%s]]" (expand-file-name (match-string 1 m) dir)) links)
               (format "\0IMG%d\0" (1- (length links)))))
           text t t)
          (nreverse links))))

(defun readq--restore-org-images (text links)
  "Put LINKS back in place of their placeholders in TEXT."
  (replace-regexp-in-string "\0IMG\\([0-9]+\\)\0"
                            (lambda (m) (nth (string-to-number (match-string 1 m)) links))
                            text t t))

(defcustom readq-anki-media-directory nil
  "Anki's media folder, for figures in the import file.
With `readq-anki-method' `file', images can't go in the file; readq
copies them here.  It is the collection.media folder of your Anki
profile, e.g. on Windows
\"~/AppData/Roaming/Anki2/User 1/collection.media/\".  With
AnkiConnect, this is not needed."
  :type '(choice (const :tag "Not set" nil) directory)
  :group 'readq-flashcards)

(defun readq--anki-media (card)
  "Return the images of CARD as card-export media: (NAME-IN-ANKI . FILE)."
  (mapcar (lambda (f) (cons (readq--anki-media-name f) f)) (readq--card-images card)))

;;;;; Selections

(declare-function multi-region-selections "multi-region" (&optional absorb))
(declare-function multi-region-clear "multi-region" ())
(defvar multi-region-mode)
(defvar pdf-view-active-region)

(defun readq--multi-region-p ()
  "Return non-nil when multi-region selections can be read here."
  (and (bound-and-true-p multi-region-mode) (fboundp 'multi-region-selections)))

(defun readq--done-selecting ()
  "Deselect what was just extracted."
  (deactivate-mark)
  (when (readq--multi-region-p) (multi-region-clear)))

(defun readq--section-number (pos)
  "Return the number of headings at or before POS."
  (cl-count-if (lambda (h) (<= (car h) pos)) (readq--headings)))

(defun readq--selection-pieces (sel clean)
  "Split the selection SEL into its text and its pictures, in order.
SEL is a plist from `multi-region-selections'.  Return a list of
\(:text TEXT :beg POS) and (:image IMAGE :beg POS), IMAGE being (:file
FILE) or (:data DATA :type TYPE); CLEAN is applied to the text, and
text left empty is dropped.  The characters under a picture, its alt
or link text, are left out."
  (let* ((beg (plist-get sel :beg))
         (text (or (plist-get sel :text)
                   (buffer-substring-no-properties beg (plist-get sel :end))))
         (len (length text))
         (pos 0)
         pieces)
    (dolist (img (sort (copy-sequence (plist-get sel :images))
                       (lambda (a b) (< (plist-get a :beg) (plist-get b :beg)))))
      (let ((from (max pos (min len (- (plist-get img :beg) beg))))
            (to (max pos (min len (- (plist-get img :end) beg)))))
        (push (list :text (substring text pos from) :beg (+ beg pos)) pieces)
        (push (list :image (if (plist-get img :file)
                               (list :file (plist-get img :file))
                             (list :data (plist-get img :data) :type (plist-get img :type)))
                    :beg (plist-get img :beg))
              pieces)
        (setq pos to)))
    (push (list :text (substring text pos) :beg (+ beg pos)) pieces)
    (delq nil (mapcar (lambda (piece)
                        (if (plist-get piece :image)
                            piece
                          (let ((text (funcall clean (plist-get piece :text))))
                            (unless (string-empty-p text)
                              (plist-put piece :text text)))))
                      (nreverse pieces)))))

(defun readq--text-parts (clean)
  "Return the passages selected in this buffer, in reading order.
They come from multi-region if it has selections, else from the
region.  Each is a plist (:text :page :point :section); CLEAN is
applied to the text.  A picture selected with multi-region is a
plist (:image :page :point :section) instead, see
`readq--selection-pieces'."
  (let ((sels (or (and (readq--multi-region-p) (multi-region-selections t))
                  (and (use-region-p)
                       (list (list :beg (region-beginning) :end (region-end))))))
        (nov (derived-mode-p 'nov-mode))
        (point-book (and readq-book-mode
                         (readq--point-format-p
                          (readq--get (readq--buffer-book) :format)))))
    (unless sels (user-error "Select some text first"))
    (mapcan
     (lambda (sel)
       (mapcar (lambda (piece)
                 (let ((beg (plist-get piece :beg)))
                   (append (if (plist-get piece :image)
                               (list :image (plist-get piece :image))
                             (list :text (plist-get piece :text)))
                           (list :point beg
                                 :page (cond (nov (or (plist-get sel :chapter)
                                                      nov-documents-index))
                                             (point-book (readq--section-number beg)))
                                 :section (and point-book (readq--section-at beg))))))
               (readq--selection-pieces sel clean)))
     sels)))

(defun readq--pdf-paged-p (region)
  "Return non-nil if this pdf-tools keeps regions as (PAGE . EDGES).
REGION is the active region, if any.  Older pdf-tools keep a plain
list of edges."
  (if (consp region)
      (numberp (car region))
    (let ((doc (get 'pdf-view-active-region 'variable-documentation)))
      (and (stringp doc) (string-match-p "\\bpage\\b" doc) t))))

(defun readq--pdf-parts ()
  "Return the passages selected in this PDF, in reading order.
They come from multi-region if it has selections, else from the
pdf-tools region (several with C-drag).  Each is a plist (:text :page
:edges).  A picture area selected with multi-region is a plist (:image
\(:pdf-area EDGES) :page :edges) instead."
  (let ((sels (or (and (readq--multi-region-p) (multi-region-selections))
                  ;; pdf-canvas reports its selections in the same form.
                  (and (derived-mode-p 'pdf-canvas-mode)
                       (pdf-canvas-selections)))))
    (cond
     (sels
      (mapcar (lambda (sel)
                (if (plist-get sel :figure)
                    (list :image (list :pdf-area (plist-get sel :edges))
                          :page (plist-get sel :page)
                          :edges (list (plist-get sel :edges)))
                  (list :text (readq--clean-text (plist-get sel :text))
                        :page (plist-get sel :page)
                        :edges (list (plist-get sel :edges)))))
              sels))
     ((derived-mode-p 'pdf-canvas-mode)
      (user-error "Select some text first (drag with the mouse)"))
     ((pdf-view-active-region-p)
      (let* ((region (pdf-view-active-region))
             ;; Newer pdf-tools: (PAGE . EDGES-LIST); older: EDGES-LIST.
             (page (if (numberp (car region)) (car region)
                     (image-mode-window-get 'page)))
             (edges (if (numberp (car region)) (cdr region) region)))
        (cl-mapcar (lambda (e text) (list :text (readq--clean-text text)
                                          :page page :edges (list e)))
                   edges (pdf-view-active-region-text))))
     (t (user-error "Select some text first (drag with the mouse)")))))

(defun readq--extract-parts (source parts ask mode)
  "Make extracts of SOURCE from PARTS, combined or not according to MODE.
PARTS are plists from `readq--text-parts' or `readq--pdf-parts'.  With
ASK, read the priority once.  Return the list of extracts."
  (let* ((parts (cl-remove-if (lambda (p) (and (not (plist-get p :image))
                                               (string-empty-p (plist-get p :text))))
                              parts))
         ;; Extracts made while reading a section take its priority.
         (from (if (and readq-book-mode (readq--section-p (readq--current-item)))
                   (readq--current-item)
                 source))
         (default (min 100 (max 0 (+ (readq--get from :priority)
                                     readq-extract-priority-offset))))
         (priority (cond ((and ask parts) (readq--read-priority default))
                         ((not (eq from source)) default)))
         ;; A section's or a parent extract's own tags carry over.
         (tags (and (not (readq--book-p from)) (readq--get from :tags))))
    (unless parts (user-error "The selection has no text"))
    (cond
     ((cl-some (lambda (p) (plist-get p :image)) parts)
      (if (or (eq mode 'separate) (null (cdr parts)))
          ;; Each picture a figure extract, each passage an extract.
          (mapcar (lambda (p)
                    (if (plist-get p :image)
                        (readq--create-figure source (plist-get p :image)
                                              :page (plist-get p :page)
                                              :point (plist-get p :point)
                                              :section (plist-get p :section)
                                              :priority priority :tags tags)
                      (readq--create-extract source (plist-get p :text)
                                             :page (plist-get p :page)
                                             :point (plist-get p :point)
                                             :edges (plist-get p :edges)
                                             :section (plist-get p :section)
                                             :priority priority :tags tags)))
                  parts)
        (list (readq--create-mixed-extract source parts priority tags))))
     ((or (eq mode 'separate) (null (cdr parts)))
        (mapcar (lambda (p)
                  (readq--create-extract source (plist-get p :text)
                                         :page (plist-get p :page)
                                         :point (plist-get p :point)
                                         :edges (plist-get p :edges)
                                         :section (plist-get p :section)
                                         :priority priority
                                         :tags tags))
                parts))
     (t
      (let ((first (car parts)))
        (list (readq--create-extract
               source
               (mapconcat (lambda (p) (plist-get p :text)) parts readq-extract-separator)
               :page (plist-get first :page)
               :point (plist-get first :point)
               :edges (plist-get first :edges)
               :section (plist-get first :section)
               :priority priority
               :tags tags
               :parts (mapcar (lambda (p)
                                (let ((text (plist-get p :text)))
                                  (list :page (plist-get p :page)
                                        :point (plist-get p :point)
                                        :edges (plist-get p :edges)
                                        :key (readq--text-key text)
                                        :snippet (truncate-string-to-width text 300)
                                        :tail (readq--text-tail text)
                                        :length (length text))))
                              parts))))))))

(defun readq--part-meta (part)
  "Return what an extract keeps of the passage PART, to find it again."
  (let ((text (plist-get part :text)))
    (list :page (plist-get part :page)
          :point (plist-get part :point)
          :edges (plist-get part :edges)
          :key (readq--text-key text)
          :snippet (truncate-string-to-width text 300)
          :tail (readq--text-tail text)
          :length (length text))))

(defun readq--create-mixed-extract (source parts priority tags)
  "Make one extract of SOURCE from PARTS, passages and pictures in order.
Each picture is saved in `readq-figures-directory' and linked where it
was; each passage is quoted.  PRIORITY and TAGS are as in
`readq--create-extract'.  Return the extract."
  (let* ((book (if (readq--extract-p source) (readq--item-book source) source))
         (texts (cl-remove-if (lambda (p) (plist-get p :image)) parts))
         (text (mapconcat (lambda (p) (plist-get p :text)) texts readq-extract-separator))
         (first (car parts))
         (time (current-time))
         (body "")
         figures)
    (dolist (p parts)
      (if-let* ((image (plist-get p :image)))
          (let ((file (abbreviate-file-name
                       (readq--save-figure-image book (plist-get p :page) image time))))
            (push file figures)
            (setq body (concat body "[[file:" file "]]\n")))
        (setq body (concat body (readq--quote-block (plist-get p :text))))))
    (readq--create-extract
     source text
     :page (plist-get first :page)
     :point (plist-get first :point)
     :edges (plist-get (car texts) :edges)
     :section (plist-get first :section)
     :priority priority
     :tags tags
     :title (unless texts
              (format "Figures: %s" (readq--source-description
                                     book (plist-get first :page)
                                     (plist-get first :section))))
     :parts (and texts (mapcar #'readq--part-meta texts))
     :body body
     :figures (nreverse figures))))

(defun readq--extract-from-pdf (ask mode)
  "Create extracts from the selections of a pdf-tools or pdf-canvas buffer.
ASK and MODE are as in `readq--extract-parts'."
  (let* ((book (readq--source-book-here))
         (canvas (derived-mode-p 'pdf-canvas-mode))
         (region (and (not canvas)
                      (pdf-view-active-region-p) (pdf-view-active-region)))
         (paged (readq--pdf-paged-p (or region (bound-and-true-p pdf-view-active-region))))
         (parts (mapcar (lambda (p)
                          (if-let* ((area (plist-get (plist-get p :image) :pdf-area)))
                              (plist-put p :image
                                         (list :data (readq--pdf-crop (readq--get book :file)
                                                                      (plist-get p :page) area)
                                               :type 'png))
                            p))
                        (readq--pdf-parts)))
         highlighted skipped)
    (when (and readq-extract-add-highlight canvas)
      (readq--canvas-highlight parts)
      (condition-case err
          (pdf-canvas-save)
        (error (message "readq: could not save the highlight (%s)"
                        (error-message-string err)))))
    (when (and readq-extract-add-highlight (not canvas))
      (dolist (p (cl-remove-if (lambda (p) (plist-get p :image)) parts))
        (let ((page (plist-get p :page))
              (edges (plist-get p :edges)))
          ;; Older pdf-tools can only annotate the page on display.
          (if (not (or paged (eql page (image-mode-window-get 'page))))
              (setq skipped t)
            (condition-case err
                (let ((annot (pdf-annot-add-markup-annotation
                              (if paged (cons page edges) edges)
                              'highlight readq-extract-highlight-color)))
                  (plist-put p :edges (or (cdr (assq 'markup-edges annot)) edges))
                  (setq highlighted t))
              (error (message "readq: could not highlight page %s (%s)"
                              page (error-message-string err)))))))
      (when highlighted
        (condition-case err
            (save-buffer)
          (error (message "readq: could not save the highlight (%s)"
                          (error-message-string err)))))
      (when skipped
        (message "readq: passages on other pages were not highlighted (update pdf-tools)")))
    (prog1 (readq--extract-parts book parts ask mode)
      (if canvas
          (pdf-canvas-clear-selections)
        (pdf-view-deactivate-region))
      (readq--done-selecting))))

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

(defun readq--extract-from-text (ask mode)
  "Create extracts from the selections of an EPUB, text book or eww page.
ASK and MODE are as in `readq--extract-parts'."
  (let* ((book (readq--source-book-here))
         ;; nov.el and eww wrap lines; text files keep their lines.
         (parts (readq--text-parts (if (derived-mode-p 'nov-mode 'eww-mode)
                                       #'readq--unfill
                                     #'string-trim))))
    (prog1 (readq--extract-parts book parts ask mode)
      (readq--done-selecting)
      (readq--decorate-extracts))))

(defun readq--extract-from-org (ask mode)
  "Create sub-extracts from the selections inside an extract.
ASK and MODE are as in `readq--extract-parts'."
  (let* ((parent (readq--extract-at-point))
         (parts (mapcar (lambda (p)
                          (list :text (plist-get p :text)
                                :image (plist-get p :image)
                                :page (readq--get parent :page)
                                :point (readq--get parent :point)
                                :section (readq--get parent :section)))
                        (readq--text-parts #'readq--org-unescape))))
    (prog1 (readq--extract-parts parent parts ask mode)
      (readq--done-selecting))))

;;;;; Reviewing extracts

(define-minor-mode readq-review-mode
  "Minor mode for the Org buffer of an extract you are reviewing.
Use `readq-next' when you are done, `readq-dismiss' when you no longer
need the extract, and `readq-extract' on a selection to make a
sub-extract."
  :lighter " RQ:extract"
  (if readq-review-mode
      (add-hook 'kill-buffer-hook #'readq--on-kill-review nil t)
    (remove-hook 'kill-buffer-hook #'readq--on-kill-review t)
    (setq readq--review-id nil)))

(defun readq--on-kill-review ()
  "Finish the review when its buffer is killed or Emacs quits.
The Org buffer is not saved: Emacs has asked about that already."
  (condition-case err
      (readq--finish-review t t)
    (error (message "readq: error while saving review: %S" err))))

(defun readq--show-subtree ()
  "Unfold the Org subtree at point."
  (if (fboundp 'org-fold-show-subtree)
      (org-fold-show-subtree)
    (with-no-warnings (org-show-subtree))))

(defun readq--open-extract (item)
  "Show extract ITEM for review.  Return non-nil on success."
  (require 'org)
  (let ((file (readq--get item :file)))
    (if (not (file-exists-p file))
        (progn (message "readq: extracts file %s not found" file) nil)
      (find-file file)
      (when readq-review-mode (readq--end-review))
      (widen)
      (let ((pos (org-find-property "READQ_ID" (readq--get item :id))))
        (if (not pos)
            (progn
              (readq--forget-extract item)
              (message "readq: the heading of \"%s\" was deleted; removed it from the queue"
                       (readq--get item :title))
              nil)
          (goto-char pos)
          (readq--show-subtree)
          (when readq-narrow-to-extract (org-narrow-to-subtree))
          (readq-review-mode 1)
          (setq readq--review-id (readq--get item :id)
                readq--session-seconds 0)
          (readq--show-figures)
          (message "Extract, priority %s.  %s when done, %s to dismiss it."
                   (readq--get item :priority)
                   (substitute-command-keys "\\[readq-next]")
                   (substitute-command-keys "\\[readq-dismiss]"))
          t)))))

(defun readq--end-review (&optional unsaved)
  "Save the Org buffer, sync the extract's title, and leave review mode.
With UNSAVED, leave the Org buffer unsaved."
  (let ((item (readq--book-by-id readq--review-id)))
    (when item
      (save-restriction
        (widen)
        (when-let* ((pos (org-find-property "READQ_ID" (readq--get item :id))))
          (save-excursion
            (goto-char pos)
            (let ((title (org-get-heading t t t t)))
              (unless (string-empty-p title) (readq--put item :title title)))))))
    (when (and (buffer-modified-p) (not unsaved))
      (let ((save-silently t)) (save-buffer)))
    (when readq-narrow-to-extract (widen))
    (readq-review-mode -1)
    item))

(defun readq--finish-review (&optional quiet unsaved)
  "Finish reviewing the extract in this buffer and reschedule it.
Return the extract.  With QUIET, do not report.  With UNSAVED (the
buffer is being killed), leave the Org buffer unsaved, and, as for a
book, reschedule only if you edited the extract or spent
`readq-min-session-seconds' on it."
  (let* ((secs readq--session-seconds)
         (counts (or (not unsaved) (buffer-modified-p)
                     (>= secs readq-min-session-seconds)))
         (item (readq--end-review unsaved)))
    (when (and item (readq--active-p item))
      ;; Only the extract's own time: a book's time is its reading.
      (readq--put item :seconds (+ (or (readq--get item :seconds) 0) secs))
      (readq--log-reading secs 0)
      (when counts
        (readq--count-session item (readq--get item :page) nil secs))
      (readq--save)
      (readq--refresh-dashboard)
      (unless quiet (readq--report-rescheduled item "Extract reviewed")))
    item))

(defun readq-dismiss (item)
  "Mark ITEM (usually an extract) as done so it is not suggested again.
When you are reviewing it, go on with `readq-next'.  Its text stays in
the Org file."
  (interactive (list (readq--target-book "Dismiss: ")))
  (let ((reviewing (and readq-review-mode
                        (equal readq--review-id (readq--get item :id)))))
    (when reviewing (readq--end-review))
    (readq--put item :status 'finished)
    (readq--save)
    (readq--refresh-dashboard)
    (message "\"%s\" is done" (readq--get item :title))
    (when reviewing (readq-next))))

(defun readq--tombstone (item)
  "Remember extract ITEM's PDF location so it is never imported again."
  (when-let* ((book (and (null (readq--get item :parent))
                        (readq--book-by-id (readq--get item :book)))))
    (dolist (piece (readq--extract-pieces item))
      (when (or (plist-get piece :key) (plist-get piece :edges))
        (readq--put book :dismissed
                    (cons (list :page (plist-get piece :page)
                                :key (plist-get piece :key)
                                :edges (plist-get piece :edges))
                          (readq--get book :dismissed)))))))

(defun readq--forget-extract (item)
  "Remove extract ITEM from the queue without touching its Org file."
  (readq--tombstone item)
  (setq readq--books (delq item (readq--books)))
  (readq--save)
  (readq--refresh-dashboard))

(defun readq-visit-extracts (book)
  "Open the Org file with the extracts of BOOK."
  (interactive (list (readq--target-book "Extracts of: ")))
  (when (readq--extract-p book)
    (setq book (readq--book-by-id (readq--get book :book))))
  (let ((file (readq--get book :extracts-file)))
    (unless (and file (file-exists-p file))
      (user-error "No extracts from \"%s\" yet" (readq--get book :title)))
    (find-file file)))

(provide 'readq-extract)
;;; readq-extract.el ends here
