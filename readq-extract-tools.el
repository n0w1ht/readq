;;; readq-extract-tools.el --- Searching, tidying, editing and importing extracts -*- lexical-binding: t; -*-

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

(require 'readq-extract)

(defvar nov-documents-index)
(defvar readq-review-mode)
(declare-function org-link-set-parameters "ol" (type &rest parameters))
(declare-function org-link-store-props "ol" (&rest plist))
(declare-function pdf-info-gettext "ext:pdf-info"
                  (page edges &optional selection-style file-or-buffer))
(declare-function pdf-info-features "ext:pdf-info" ())
(declare-function nov-goto-document "ext:nov" (index))
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function pdf-view-goto-page "ext:pdf-view" (page &optional window))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-narrow-to-subtree "org" (&optional element))
(declare-function pdf-info-getannots "ext:pdf-info" (&optional pages file-or-buffer))
(declare-function pdf-info-close "ext:pdf-info" (&optional file-or-buffer))
(declare-function org-cut-subtree "org" (&optional n))
(declare-function readq-mark-ready "readq-cards")
(declare-function outline-next-heading "outline" ())
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-find-property "org" (property &optional value))

;;;;; Searching extracts

;; The notes of your extracts may share their folder with notes of
;; your own, so the searches below get the list of files from the
;; database rather than from the directory.  With consult they are live, with preview;
;; without it they fall back to `multi-occur' and `completing-read'.

(declare-function consult-ripgrep "ext:consult" (&optional dir initial))
(declare-function consult-grep "ext:consult" (&optional dir initial))
(declare-function consult--read "ext:consult" (table &rest options))
(declare-function consult--temporary-files "ext:consult" ())
(declare-function consult--jump-state "ext:consult" ())
(declare-function consult--lookup-cdr "ext:consult" (selected candidates &rest _))
(declare-function org-reveal "org" (&optional siblings))

(defcustom readq-search-max-command-length 24000
  "Longest list of notes, in characters, passed to grep at once.
A command line cannot be longer than the system allows; with more
notes than fit, `readq-search' searches the folder that holds them,
with any other notes you keep there."
  :type 'natnum
  :group 'readq-extracts)

(defun readq--search-tags (arg)
  "Return the tags a search is limited to: asked for with ARG, else the focus."
  (if arg
      (readq--read-tags "Search extracts with tags (empty for all): ")
    readq--focus))

(defun readq--search-prompt (what tags)
  "Return a prompt for WHAT, mentioning TAGS."
  (format "%s%s: " what (if tags (concat " (" (readq--tags-string-of tags) ")") "")))

(defun readq--extracts-files (&optional tags)
  "Return the notes that exist of the extracts having TAGS."
  (let (files)
    (dolist (x (readq--books))
      (when (and (readq--extract-p x) (readq--tags-match-p x tags))
        (let ((file (readq--get x :file)))
          (when (and file (file-exists-p file))
            (cl-pushnew (expand-file-name file) files :test #'string=)))))
    (nreverse files)))

(defun readq--search-paths (files)
  "Return FILES, or the folders holding them if FILES are too many to pass."
  (if (<= (cl-reduce #'+ files :key (lambda (f) (1+ (length f))) :initial-value 0)
          readq-search-max-command-length)
      files
    (delete-dups (mapcar #'file-name-directory files))))

(defun readq--common-directory (files)
  "Return the deepest directory holding all FILES, or nil."
  (let ((prefix (try-completion "" (mapcar #'file-name-directory files))))
    (when (and (stringp prefix) (string-match "\\`\\(.*/\\)" prefix))
      (let ((dir (match-string 1 prefix)))
        (and (file-directory-p dir) dir)))))

;;;###autoload
(defun readq-search (&optional arg)
  "Search the text of all your extracts.
With consult, this is `consult-ripgrep' (or `consult-grep' when
ripgrep isn't installed) over the notes of your extracts, with a live
preview; without consult, or with neither ripgrep nor grep
installed, it is `multi-occur'.  Only extracts in the current
focus are searched, see `readq-focus'.  With prefix ARG, ask for
tags to search instead; an empty answer searches everything.

Dismissed extracts still have their notes, so they are found."
  (interactive "P")
  (let* ((tags (readq--search-tags arg))
         (files (or (readq--extracts-files tags)
                    (user-error (if tags "No extracts with %s"
                                  "No extracts yet%s")
                                (readq--tags-string-of tags)))))
    (if (and (require 'consult nil t)
             (or (executable-find "rg") (executable-find "grep")))
        (let ((default-directory (or (readq--common-directory files)
                                     default-directory))
              (paths (readq--search-paths files)))
          (if (executable-find "rg")
              (consult-ripgrep paths)
            (consult-grep paths)))
      (multi-occur (mapcar #'find-file-noselect files)
                   (read-regexp (readq--search-prompt "Search extracts for" tags))))))

(defun readq--extract-candidates (tags)
  "Return (STRING . ITEM) for each extract with TAGS, for completion."
  (let (cands)
    (dolist (x (readq--books))
      (when (and (readq--extract-p x) (readq--tags-match-p x tags))
        (let* ((book (readq--item-book x))
               (snippet (replace-regexp-in-string
                         "[ \t\n]+" " " (or (readq--get x :snippet) "")))
               (title (readq--get x :title))
               (text (concat title
                             (if (or (string-empty-p snippet)
                                     (string-prefix-p (string-trim (truncate-string-to-width
                                                                    title 40))
                                                      snippet))
                                 ""
                               (propertize (concat "  " (truncate-string-to-width snippet 80 nil nil "…"))
                                           'face 'shadow))
                             (let ((tagstr (readq--tags-string x)))
                               (if (string-empty-p tagstr) ""
                                 (propertize (concat "  " tagstr) 'face 'font-lock-constant-face))))))
          (push (cons (propertize text 'readq-book (if book (readq--get book :title) "?")
                                  'readq-item x)
                      x)
                cands))))
    (nreverse cands)))

(defun readq--extract-annotation (cand)
  "Return the annotation of extract candidate CAND."
  (when-let* ((x (get-text-property 0 'readq-item cand)))
    (concat "  "
            (propertize
             (format "%s  pri %s  %s"
                     (if-let* ((page (readq--get x :page)))
                         (readq--source-description (readq--item-book x) page
                                                    (readq--get x :section))
                       "")
                     (readq--get x :priority)
                     (cond ((not (readq--active-p x)) (symbol-name (readq--get x :status)))
                           ((readq--due-p x) "due")
                           (t (concat "due " (or (readq--get x :due) "?")))))
             'face 'completions-annotations))))

(defun readq--extract-group (cand transform)
  "Group extract candidate CAND by book; with TRANSFORM, return CAND."
  (if transform cand (get-text-property 0 'readq-book cand)))

(defun readq--extract-marker (item &optional open)
  "Return a marker where the text of extract ITEM's note starts, or nil.
OPEN is a function that opens a file for preview; without it the
file is visited normally."
  (when-let* ((buf (readq--extract-buffer item open)))
    (with-current-buffer buf
      (copy-marker (readq--note-body-start)))))

(defun readq--goto-extract (item)
  "Show the note of extract ITEM, without starting a review."
  (let ((marker (or (readq--extract-marker item)
                    (user-error "Cannot find \"%s\" in %s; it may have been deleted"
                                (readq--get item :title) (readq--get item :file)))))
    (pop-to-buffer-same-window (marker-buffer marker))
    (widen)
    (goto-char marker)))

;;;###autoload
(defun readq-find-extract (&optional arg)
  "Choose an extract from a list and show it in its Org file.
The list shows each extract's title, the start of its text and its
tags, grouped by book, with its source, priority and due date.  With
consult the extract under the cursor is previewed, and these keys
narrow the list: d due extracts, f figures, p paused or finished.
Only extracts in the current focus are listed, see `readq-focus';
with prefix ARG, ask for tags instead (empty for all).

This doesn't review the extract or reschedule it; `readq-open' does."
  (interactive "P")
  (let* ((tags (readq--search-tags arg))
         (cands (or (readq--extract-candidates tags)
                    (user-error (if tags "No extracts with %s" "No extracts yet%s")
                                (readq--tags-string-of tags))))
         (prompt (readq--search-prompt "Extract" tags))
         (item
          (if (and (require 'consult nil t) (fboundp 'consult--read))
              (consult--read
               cands
               :prompt prompt
               :category 'readq-extract
               :require-match t
               :sort nil
               :lookup #'consult--lookup-cdr
               :group #'readq--extract-group
               :annotate #'readq--extract-annotation
               :narrow
               (list :predicate
                     (lambda (cand)
                       (let ((x (if (consp cand) (cdr cand)
                                  (get-text-property 0 'readq-item cand))))
                         (pcase (bound-and-true-p consult--narrow)
                           (?d (readq--due-p x))
                           (?f (or (readq--get x :figure) (readq--get x :figures)))
                           (?p (not (readq--active-p x)))
                           (_ t))))
                     :keys '((?d . "Due") (?f . "Figures") (?p . "Paused/finished")))
               :state
               (when (and (fboundp 'consult--temporary-files)
                          (fboundp 'consult--jump-state))
                 (let ((open (consult--temporary-files))
                       (jump (consult--jump-state)))
                   (lambda (action item)
                     (unless item (funcall open))
                     (unless (eq action 'return)
                       (funcall jump action
                                (and item (readq--extract-marker item open))))))))
            (let ((choice (completing-read
                           prompt
                           (lambda (str pred action)
                             (if (eq action 'metadata)
                                 '(metadata (category . readq-extract)
                                            (display-sort-function . identity)
                                            (annotation-function . readq--extract-annotation)
                                            (group-function . readq--extract-group))
                               (complete-with-action action cands str pred)))
                           nil t)))
              (cdr (assoc choice cands))))))
    (when item (readq--goto-extract item))))

;;;;; Stale extracts

;; An extract is meant to be worked on: turned into a card, split into
;; sub-extracts, merged with others, or dismissed.  One that keeps
;; coming back and is never acted on is stale; `readq-stale-extracts'
;; goes through them one by one and asks what to do with each.

(defcustom readq-stale-reviews 5
  "Reviews after which an extract nobody acted on counts as stale.
See `readq-stale-extracts'.  nil turns the review count off."
  :type '(choice (const :tag "Don't count reviews" nil) natnum)
  :group 'readq-extracts)

(defcustom readq-stale-days 60
  "Days after which an extract reviewed at least twice counts as stale.
See `readq-stale-extracts'.  nil turns the age off."
  :type '(choice (const :tag "Don't count days" nil) natnum)
  :group 'readq-extracts)

(defcustom readq-stale-priority-step 20
  "How much \"lower priority\" in `readq-stale-extracts' adds to the priority."
  :type 'natnum
  :group 'readq-extracts)

(defun readq--stale-p (item parents &optional now)
  "Return non-nil when extract ITEM is stale on NOW's date.
PARENTS is a hash table of the ids of extracts that have sub-extracts.
Reviews and days are counted since the extract was made, or since you
last chose to keep it."
  (and (readq--extract-p item)
       (readq--active-p item)
       (not (gethash (readq--get item :id) parents))
       (let* ((kept (readq--get item :kept))
              (reviews (- (or (readq--get item :sessions) 0)
                          (or (plist-get kept :sessions) 0)))
              (since (or (plist-get kept :date) (readq--get item :added)))
              (age (if since (- (readq--days-until since now)) 0)))
         (or (and readq-stale-reviews (>= reviews readq-stale-reviews))
             (and readq-stale-days (>= reviews 2) (>= age readq-stale-days))))))

(defun readq--stale-extracts (&optional tags now)
  "Return the stale extracts with TAGS on NOW's date, most reviewed first."
  (let ((parents (make-hash-table :test #'equal)))
    (dolist (x (readq--books))
      (when-let* ((p (and (readq--extract-p x) (readq--get x :parent))))
        (puthash p t parents)))
    (sort (cl-remove-if-not (lambda (x) (and (readq--tags-match-p x tags)
                                             (readq--stale-p x parents now)))
                            (readq--books))
          (lambda (a b) (> (or (readq--get a :sessions) 0)
                           (or (readq--get b :sessions) 0))))))

(defun readq--read-merge-target (item)
  "Ask for the extract to merge ITEM into; extracts of its book come first."
  (let* ((book (readq--get item :book))
         (cands (cl-remove-if (lambda (c) (eq (cdr c) item))
                              (readq--extract-candidates nil)))
         (cands (append (cl-remove-if-not (lambda (c) (equal (readq--get (cdr c) :book) book))
                                          cands)
                        (cl-remove-if (lambda (c) (equal (readq--get (cdr c) :book) book))
                                      cands)))
         (choice (completing-read
                  (format "Merge \"%s\" into: "
                          (truncate-string-to-width (readq--get item :title) 40 nil nil "…"))
                  (lambda (str pred action)
                    (if (eq action 'metadata)
                        '(metadata (category . readq-extract)
                                   (display-sort-function . identity)
                                   (annotation-function . readq--extract-annotation)
                                   (group-function . readq--extract-group))
                      (complete-with-action action cands str pred)))
                  nil t)))
    (or (cdr (assoc choice cands)) (user-error "No extract chosen"))))

(defun readq--relink-source (item text)
  "Return TEXT with links to extract ITEM made links to its place in its book.
Used when ITEM is merged away, so its source link keeps working."
  (let ((book (readq--item-book item))
        (page (readq--get item :page)))
    (if (not (and book (not (readq--extract-p book))))
        text
      (let ((format (readq--get book :format))
            (point (readq--get item :point)))
        (replace-regexp-in-string
         (concat "\\[\\[readq:" (regexp-quote (readq--get item :id)) "\\]")
         (concat "[[readq:" (readq--get book :id)
                 (cond ((and (eq format 'epub) page)
                        (format "::c%d%s" page (if point (format ":%d" point) "")))
                       ((and (readq--point-format-p format) point)
                        (format "::t%d" point))
                       ((numberp page) (format "::p%d" (round page)))
                       (t ""))
                 "]")
         text t t)))))

;;;###autoload
(defun readq-merge-extract (item target)
  "Merge extract ITEM into extract TARGET.
ITEM's text, with its source link and note, goes at the end of
TARGET's note, under a \"Merged from\" line; ITEM's note is deleted
and ITEM leaves the queue.  TARGET keeps its
schedule.  ITEM's highlight stays in the book."
  (interactive
   (let ((item (or (readq--extract-at-point)
                   (readq--target-book "Merge extract: "))))
     (list item (readq--read-merge-target item))))
  (unless (and (readq--extract-p item) (readq--extract-p target))
    (user-error "Only extracts can be merged"))
  (when (eq item target) (user-error "Cannot merge an extract into itself"))
  (when (readq--extract-descendants item)
    (user-error "\"%s\" has sub-extracts; merge or delete them first"
                (readq--get item :title)))
  (require 'org)
  (let ((body (readq--relink-source
               item (concat "Source: " (readq--note-source-link item) "\n"
                            (or (readq--extract-body item)
                                (user-error "The note of \"%s\" is gone"
                                            (readq--get item :title))))))
        (buf (or (readq--extract-buffer target)
                 (user-error "The note of \"%s\" is gone" (readq--get target :title)))))
    (when (and readq-review-mode
               (member readq--review-id (list (readq--get item :id) (readq--get target :id))))
      (readq--end-review))
    (with-current-buffer buf
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-max))
          (skip-chars-backward " \t\n")
          (delete-region (point) (point-max))
          (insert "\n\n")
          (insert "Merged from: " (readq--get item :title) "\n" body "\n")
          (let ((save-silently t)) (save-buffer)))))
    (readq--delete-org-entry item)
    (readq--forget-extract item)
    (readq--put target :seconds (+ (or (readq--get target :seconds) 0)
                                   (or (readq--get item :seconds) 0)))
    (readq--save)
    (readq--refresh-dashboard)
    (message "Merged \"%s\" into \"%s\"" (readq--get item :title) (readq--get target :title))
    target))

(defun readq--keep-extract (item)
  "Mark ITEM as kept: it is not stale again until it has been reviewed
`readq-stale-reviews' more times, or `readq-stale-days' have passed."
  (readq--put item :kept (list :date (readq--today)
                               :sessions (or (readq--get item :sessions) 0)))
  (readq--save))

;;;###autoload
(defun readq-stale-extracts (&optional arg)
  "Go through stale extracts and decide what to do with each.
An extract is stale when it has come back `readq-stale-reviews' times,
or was made `readq-stale-days' ago and reviewed at least twice, and
you have not acted on it: it is not ready for a card and has no
sub-extracts.  Each is shown in its Org file, and you choose:

  c  card: mark it ready for a flashcard (`readq-mark-ready')
  m  merge it into another extract (`readq-merge-extract')
  d  dismiss it: out of the queue, its text stays (`readq-dismiss')
  D  delete it, with its highlight (`readq-delete-extract')
  l  lower its priority by `readq-stale-priority-step', so it comes
     back less often, and keep it
  k  keep it as it is, and stop calling it stale for a while
  e  stop here to edit it: write a cloze, split it, rewrite it
  s  skip it for now
  q  stop

Only extracts in the current focus are shown; with prefix ARG, ask
for tags instead (empty for all)."
  (interactive "P")
  (let* ((tags (readq--search-tags arg))
         (stale (or (readq--stale-extracts tags)
                    (user-error "No stale extracts%s"
                                (if tags (concat " with " (readq--tags-string-of tags)) ""))))
         (total (length stale))
         (n 0)
         (done (list 0))
         stop)
    (when readq-review-mode (readq--finish-review t))
    (while (and stale (not stop))
      (let ((x (pop stale)))
        (cl-incf n)
        ;; An earlier merge may have removed it.
        (when (memq x (readq--books))
          (condition-case nil
              (readq--goto-extract x)
            (user-error (setq x nil)))
          (when x
            (let ((choice
                   (car (read-multiple-choice
                         (format "Stale %d/%d, %d reviews: \"%s\""
                                 n total (or (readq--get x :sessions) 0)
                                 (truncate-string-to-width (readq--get x :title) 40 nil nil "…"))
                         '((?c "card" "mark it ready for a flashcard")
                           (?m "merge" "merge it into another extract")
                           (?d "dismiss" "take it out of the queue, keep its text")
                           (?D "delete" "delete it with its highlight")
                           (?l "lower" "lower its priority and keep it")
                           (?k "keep" "keep it as it is")
                           (?e "edit" "stop here to edit it")
                           (?s "skip" "decide later")
                           (?q "quit" "stop"))))))
              (pcase choice
                (?c (readq-mark-ready x))
                (?m (readq-merge-extract x (readq--read-merge-target x)))
                (?d (readq-dismiss x))
                (?D (unless (readq-delete-extract x) (setq choice ?s)))
                (?l (readq--put x :priority (min 100 (+ (readq--get x :priority)
                                                        readq-stale-priority-step)))
                    (readq--keep-extract x))
                (?k (readq--keep-extract x))
                (?e (setq stop 'edit))
                (?q (setq stop t)))
              (unless (memq choice '(?s ?e ?q)) (cl-incf (car done))))))))
    (readq--refresh-dashboard)
    (message "%s%d of %d stale extract%s handled"
             (if (eq stop 'edit)
                 (substitute-command-keys "Edit away; \\[readq-stale-extracts] goes on.  ")
               "")
             (car done) total (if (= total 1) "" "s"))))

;;;;; Deleting an extract with its highlight

(declare-function pdf-annot-getannots "ext:pdf-annot" (&optional pages types buffer))
(declare-function pdf-annot-delete "ext:pdf-annot" (a))
(declare-function pdf-annot-get "ext:pdf-annot" (a property &optional default))
(declare-function pdf-info-delannot "ext:pdf-info" (id &optional file-or-buffer))
(declare-function pdf-info-save "ext:pdf-info" (&optional file-or-buffer))

(defun readq--extract-descendants (item)
  "Return the sub-extracts of extract ITEM, at any depth."
  (let ((kids (cl-remove-if-not #'readq--extract-p (readq--children-of item))))
    (append kids (mapcan #'readq--extract-descendants kids))))

(defun readq--delete-org-entry (item)
  "Delete the note of extract ITEM and those of its sub-extracts.
Return non-nil if ITEM's note was found.  The files go to the trash
when `delete-by-moving-to-trash' is set."
  (let ((found nil))
    (dolist (x (cons item (readq--extract-descendants item)))
      (when-let* ((file (and (readq--note-p x) (readq--extract-file x))))
        (when (eq x item) (setq found t))
        (when-let* ((buf (find-buffer-visiting file)))
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf))
        (delete-file file t)))
    found))

(defun readq--highlight-match-p (annot page edges-list)
  "Return non-nil when the PDF annotation ANNOT is the highlight of a passage.
The passage is EDGES-LIST on PAGE; ANNOT is an alist from pdf-tools."
  (and (eql (cdr (assq 'page annot)) page)
       (memq (cdr (assq 'type annot)) '(highlight underline squiggly strike-out))
       (> (readq--edges-overlap (or (cdr (assq 'markup-edges annot))
                                    (list (cdr (assq 'edges annot))))
                                edges-list)
          0.5)))

(defun readq--delete-pdf-highlights (item)
  "Delete the highlights of extract ITEM from its PDF.  Return how many.
With the PDF open in Emacs, they are deleted there and the PDF
saved; otherwise the file is changed directly (SumatraPDF highlights too).
Needs pdf-tools."
  (let* ((book (readq--item-book item))
         (pieces (cl-remove-if-not (lambda (p) (and (plist-get p :page) (plist-get p :edges)))
                                   (readq--extract-pieces item)))
         (deleted 0))
    (when (and book pieces (eq (readq--get book :format) 'pdf)
               (not (readq--missing-p book))
               (or (readq--viewer-buffer-visiting (readq--get book :file)
                                                  :delete-highlights)
                   (readq--pdf-info-available-p)))
      (let ((buf (readq--pdf-buffer-visiting book))
            (other (readq--viewer-buffer-visiting (readq--get book :file)
                                                  :delete-highlights))
            (file (expand-file-name (readq--get book :file))))
        (condition-case err
            (cond
             (other
              ;; A viewer that keeps the file open deletes them itself.
              (with-current-buffer other
                (setq deleted (or (readq--viewer-call :delete-highlights pieces) 0))))
             (buf
              (with-current-buffer buf
                (require 'pdf-annot)
                (dolist (p pieces)
                  (dolist (a (pdf-annot-getannots (plist-get p :page)))
                    (when (readq--highlight-match-p a (plist-get p :page)
                                                    (plist-get p :edges))
                      (pdf-annot-delete a)
                      (setq deleted (1+ deleted)))))
                (when (> deleted 0) (save-buffer))))
             (t
              ;; epdfinfo keeps documents open: start from the file as it is.
              (ignore-errors (pdf-info-close file))
              (unwind-protect
                  (progn
                    (dolist (p pieces)
                      (dolist (a (pdf-info-getannots (plist-get p :page) file))
                        (when (readq--highlight-match-p a (plist-get p :page)
                                                        (plist-get p :edges))
                          (pdf-info-delannot (cdr (assq 'id a)) file)
                          (setq deleted (1+ deleted)))))
                    (when (> deleted 0)
                      (let ((saved (pdf-info-save file)))
                        (copy-file saved file t)
                        (delete-file saved))))
                (ignore-errors (pdf-info-close file)))))
          (error
           (message "readq: could not delete the highlight from the PDF (%s)"
                    (error-message-string err))
           (setq deleted 0)))
        (when (> deleted 0)
          (readq--put book :annots-mtime (readq--file-mtime file)))))
    deleted))

(defun readq--extract-to-delete ()
  "Return the extract a deletion command is about, or ask for one.
That is the highlighted passage at point in a book, the extract at
point in its Org file or in the dashboard, or one on the PDF page shown."
  (or (and (derived-mode-p 'readq-dashboard-mode)
           (when-let* ((id (tabulated-list-get-id))
                       (x (readq--book-by-id id)))
             (and (readq--extract-p x) x)))
      (readq--extract-at-point)
      (when-let* ((ov (cl-find-if (lambda (o) (overlay-get o 'readq-extract-id))
                                 (overlays-at (point)))))
        (readq--book-by-id (overlay-get ov 'readq-extract-id)))
      (when-let* (((eq (readq--viewer-get :kind) 'pdf))
                  (book (readq--buffer-book))
                  (page (readq--pdf-page-here))
                  (here (cl-remove-if-not
                         (lambda (x) (cl-some (lambda (p) (eql (plist-get p :page) page))
                                              (readq--extract-pieces x)))
                         (cl-remove-if (lambda (x) (readq--get x :parent))
                                       (readq--extracts-of book t)))))
        (if (cdr here)
            (readq--completing-read-book "Delete which extract on this page? " here)
          (car here)))
      (user-error "No extract here: put point on a highlighted passage, or use the dashboard")))

;;;###autoload
(defun readq-delete-extract (item)
  "Delete extract ITEM with its highlight and its note.
In a book, ITEM is the highlighted passage at point (in a PDF, an
extract on the page shown); it can also be the extract at point in its
Org file or in the dashboard.  Deleted are: the highlight in the book
\(for a PDF, inside the PDF file), the extract's entry in its Org file
\(with its sub-extracts; the text goes to the kill ring), and the
extract in the queue."
  (interactive (list (readq--extract-to-delete)))
  (unless (readq--extract-p item) (user-error "Not an extract"))
  (let* ((kids (readq--extract-descendants item))
         (book (readq--item-book item))
         (passages (length (readq--extract-pieces item))))
    (when (yes-or-no-p
           (format "Delete the extract \"%s\"%s%s with its highlight and note? "
                   (readq--get item :title)
                   (if (> passages 1) (format " (%d passages)" passages) "")
                   (if kids (format " and its %d sub-extract%s" (length kids)
                                    (if (cdr kids) "s" ""))
                     "")))
      (when (and readq-review-mode
                 (member readq--review-id (mapcar (lambda (x) (readq--get x :id))
                                                  (cons item kids))))
        (readq--end-review))
      (let* ((highlights (readq--delete-pdf-highlights item))
             (in-org (readq--delete-org-entry item)))
        (dolist (x (cons item kids))
          ;; A highlight left in the PDF must not be imported again.
          (unless (and (eq x item) (> highlights 0)) (readq--tombstone x))
          (dolist (f (readq--figure-files x))
            (when (file-exists-p f) (delete-file f)))
          (readq--remove-items (list x)))
        (readq--save)
        (when book
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (and readq-book-mode (equal readq--book-id (readq--get book :id)))
                (readq--decorate-extracts)))))
        (readq--refresh-dashboard)
        (message "Deleted \"%s\"%s%s" (readq--get item :title)
                 (if in-org "" " (its note was already gone)")
                 (if (> highlights 0)
                     (format "; %d highlight%s removed from the PDF" highlights
                             (if (= highlights 1) "" "s"))
                   ""))
        item))))

;;;;; Editing an extract beside its source

;; While reading, `readq-edit-extract' (C-c r ') opens the extract you
;; are on in a window beside the book: its note, in an indirect
;; buffer.  Edits go straight into the note.  C-c C-c saves and closes.

(defcustom readq-edit-extract-side 'right
  "Side of the frame where `readq-edit-extract' shows the extract."
  :type '(choice (const right) (const left) (const bottom) (const top))
  :group 'readq-extracts)

(defcustom readq-edit-extract-size 0.4
  "Width (or height, at the top or bottom) of the extract's window.
A fraction of the frame, or a number of columns or lines."
  :type 'number
  :group 'readq-extracts)

(defvar-local readq--edit-extract-id nil
  "Id of the extract edited in this buffer.")

(defun readq--extract-here (verb)
  "Return the extract the user is on, asking if needed.
That is the highlighted passage at point in a book, the extract at
point in its Org file or the dashboard, or one on the page shown (in
SumatraPDF, the page readq last learned).  With several there, or none,
ask among the book's extracts, nearest first; VERB is the question,
e.g. \"Edit\"."
  (or (and (derived-mode-p 'readq-dashboard-mode)
           (when-let* ((id (tabulated-list-get-id))
                       (x (readq--book-by-id id)))
             (and (readq--extract-p x) x)))
      (readq--extract-at-point)
      (when-let* ((ov (cl-find-if (lambda (o) (overlay-get o 'readq-extract-id))
                                 (overlays-at (point)))))
        (readq--book-by-id (overlay-get ov 'readq-extract-id)))
      (let* ((external (and readq--external-session
                            (readq--book-by-id (plist-get readq--external-session :id))))
             (book (or (readq--buffer-book) external
                       (user-error "No extract here: open a book or an extract first")))
             (book (readq--item-book book))
             (page (or (plist-get (ignore-errors (readq--buffer-position)) :page)
                       (readq--get book :page)))
             (extracts (or (readq--extracts-of book t)
                           (user-error "No extracts from \"%s\" yet" (readq--get book :title))))
             (distance (lambda (x)
                         (if (and (numberp page) (numberp (readq--get x :page)))
                             (abs (- (readq--get x :page) page))
                           0)))
             (here (cl-remove-if-not
                    (lambda (x) (cl-some (lambda (p) (eql (plist-get p :page) page))
                                         (readq--extract-pieces x)))
                    extracts)))
        (if (and here (null (cdr here)))
            (car here)
          (readq--completing-read-book
           (format "%s which extract%s? " verb (if here " on this page" ""))
           (or here (sort (copy-sequence extracts)
                          (lambda (a b) (< (funcall distance a) (funcall distance b))))))))))

(defvar readq-edit-extract-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'readq-edit-extract-done)
    (define-key map (kbd "C-c '") #'readq-edit-extract-done)
    (define-key map (kbd "C-c C-k") #'readq-edit-extract-done)
    map)
  "Keymap for `readq-edit-extract-mode'.")

(define-minor-mode readq-edit-extract-mode
  "Minor mode for an extract opened beside its source.
\\<readq-edit-extract-mode-map>\\[readq-edit-extract-done] saves it and closes the window."
  :lighter " RQ:edit"
  (when readq-edit-extract-mode
    (setq header-line-format
          (substitute-command-keys
           "Extract: \\<readq-edit-extract-mode-map>\\[readq-edit-extract-done] to save and close"))))

;;;###autoload
(defun readq-edit-extract (item)
  "Open extract ITEM in a window beside its source, to edit it.
In a book, ITEM is the highlighted passage at point, or an extract on
the page shown; otherwise you choose one, the nearest first.  The
window shows the extract's note;
edits go into its file.  Press C-c C-c there to save and
close.  Editing doesn't review the extract or change its schedule.
The window's side and size are `readq-edit-extract-side' and
`readq-edit-extract-size'."
  (interactive (list (readq--extract-here "Edit")))
  (unless (readq--extract-p item) (user-error "Not an extract"))
  (require 'org)
  (let* ((marker (or (readq--extract-marker item)
                     (user-error "Cannot find \"%s\" in %s; it may have been deleted"
                                 (readq--get item :title) (readq--get item :file))))
         (base (marker-buffer marker))
         (name (format "*readq extract: %s*"
                       (truncate-string-to-width (readq--get item :title) 40 nil nil "…")))
         (buf (or (cl-find-if (lambda (b)
                                (and (eq (buffer-base-buffer b) base)
                                     (equal (buffer-local-value 'readq--edit-extract-id b)
                                            (readq--get item :id))))
                              (buffer-list))
                  (with-current-buffer (make-indirect-buffer base (generate-new-buffer-name name) t)
                    ;; The clone mustn't review: that is the base buffer's.
                    (when readq-review-mode (readq-review-mode -1))
                    (setq readq--edit-extract-id (readq--get item :id))
                    (widen)
                    (goto-char marker)
                    (readq-edit-extract-mode 1)
                    (current-buffer))))
         (win (display-buffer-in-side-window
               buf `((side . ,readq-edit-extract-side)
                     (slot . 0)
                     (,(if (memq readq-edit-extract-side '(left right))
                           'window-width 'window-height)
                      . ,readq-edit-extract-size)
                     (window-parameters . ((no-delete-other-windows . t)))))))
    (select-window win)
    (with-current-buffer buf
      (goto-char (readq--note-body-start)))
    win))

(defun readq-edit-extract-done ()
  "Save the extract edited in this window and close the window.
Its title in the queue and its file name follow its title."
  (interactive)
  (unless readq--edit-extract-id (user-error "Not an extract opened with `readq-edit-extract'"))
  (let ((item (readq--book-by-id readq--edit-extract-id))
        (buf (current-buffer)))
    (with-current-buffer (buffer-base-buffer buf)
      (when (buffer-modified-p) (let ((save-silently t)) (save-buffer))))
    (let ((win (get-buffer-window buf)))
      (kill-buffer buf)
      (when (window-live-p win) (delete-window win)))
    (when item
      (readq--sync-extract item)
      (readq--save))
    (readq--refresh-dashboard)))

;;;;; Going back to the source

(defun readq-goto-source (item)
  "Show the place in its book where extract ITEM comes from.
Your reading position in the book is not changed; `readq-open' takes
you back to it."
  (interactive (list (or (readq--extract-at-point)
                         (readq--target-book "Go to source of: "))))
  (if (not (readq--extract-p item))
      (readq-open item)
    (let ((book (readq--book-by-id (readq--get item :book))))
      (unless book (user-error "The book of this extract is not in your queue anymore"))
      (readq--visit-location book (readq--get item :page) (readq--get item :point)
                             (readq--get item :snippet)))))

(defun readq--find-text (snippet &optional near)
  "Find SNIPPET in the current buffer, preferring matches NEAR.
Return (BEG . END) or nil.  Whitespace may differ, since nov.el and
eww refill text to the window width."
  (let* ((words (split-string (or snippet "") "[ \t\n\r]+" t))
         (words (cl-subseq words 0 (min 30 (length words))))
         best)
    (when words
      (let ((re (mapconcat #'regexp-quote words "[ \t\n\r]+")))
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward re nil t)
            (let ((m (cons (match-beginning 0) (match-end 0))))
              (when (or (null best)
                        (and near (< (abs (- (car m) near)) (abs (- (car best) near)))))
                (setq best m)))))))
    best))

(defun readq--visit-location (book page &optional point snippet)
  "Show PAGE of BOOK without moving your bookmark in it.
For an EPUB, PAGE is a chapter index; POINT and SNIPPET locate the
passage in it.  For text and web pages, POINT and SNIPPET locate it."
  (unless readq-mode (readq-mode 1))
  (when (readq--missing-p book)
    (user-error "Missing file: %s" (readq--get book :file)))
  (cond
   ((eq (readq--get book :format) 'media)
    ;; Play from a little before the moment, without moving your place.
    (readq--open-media book (max 0 (- (or point page 0) readq-mpv-mark-lead)) t))
   ((eq (readq--viewer book) 'sumatra)
    (readq--sumatra-launch (readq--get book :file) page))
   (t
    (let ((buf (readq--book-buffer book)))
      (cond
       (buf (pop-to-buffer buf))
       ((eq (readq--get book :format) 'html)
        ;; eww may render later: tell `readq--eww-after-render' where to go.
        (let ((readq--eww-jump (list :point point :anchor snippet))
              (display-buffer-overriding-action
               '(display-buffer-pop-up-window (inhibit-same-window . t))))
          (readq--eww-open (readq--get book :file)))
        (unless readq-book-mode
          (setq readq--eww-pending-jump (list :point point :anchor snippet))))
       (t
        (let ((readq--inhibit-restore t))
          (readq--find-book-file book t))))
      (when readq-book-mode
        ;; Save where you were reading before jumping away.  A buffer
        ;; opened just now is not at your bookmark, so skip it then.
        (when buf (readq--record-position))
        (setq readq--peeking t))
      (cond
       ((readq--point-format-p (readq--get book :format))
        (when readq-book-mode
          (readq--goto-text point snippet)
          (ignore-errors (recenter))))
       ((not page))
       ((readq--viewer-get :goto)
        (readq--viewer-call :goto (list :page page :point point))
        (when (readq--viewer-get :text)
          (readq--goto-text point snippet)
          (ignore-errors (recenter)))))
      (when readq-book-mode
        (message "Showing the source.  Your bookmark stays at %s; %s goes back to it."
                 (readq--position-string book)
                 (substitute-command-keys "\\[readq-open]")))))))

(defun readq--text-tail (text)
  "Return the last words of TEXT, used to find where the passage ends."
  (let ((words (split-string (or text "") "[ \t\n\r]+" t)))
    (and words (mapconcat #'identity (last words 8) " "))))

(defun readq--collapsed-forward (start length)
  "Return the position LENGTH characters after START, counting as unfilled.
Like `readq--unfill', a run of whitespace counts as one character, or
two when it holds a blank line (a paragraph break)."
  (save-excursion
    (goto-char start)
    (let ((left length))
      (while (and (> left 0) (not (eobp)))
        (if (looking-at "[ \t\n\r]+")
            (progn
              (setq left (- left (if (string-match-p "\n[ \t]*\n" (match-string 0)) 2 1)))
              (goto-char (match-end 0)))
          (forward-char 1)
          (setq left (1- left))))
      (skip-chars-backward " \t\n\r" start)
      (point))))

(defun readq--passage-end (start piece unfilled)
  "Return where the passage PIECE found at START ends in this buffer.
PIECE's :length is the length of its text, which UNFILLED means had its
whitespace collapsed; its :tail, its last words, gives the exact end."
  (let* ((length (or (plist-get piece :length) 0))
         (estimate (if unfilled
                       (readq--collapsed-forward start length)
                     (min (point-max) (+ start length))))
         (tail (plist-get piece :tail))
         best)
    (when tail
      (let ((re (mapconcat #'regexp-quote (split-string tail " " t) "[ \t\n\r]+"))
            (bound (min (point-max) (+ estimate 200 (/ length 2)))))
        (save-excursion
          (goto-char start)
          (while (re-search-forward re bound t)
            (when (or (null best) (< (abs (- (match-end 0) estimate))
                                     (abs (- best estimate))))
              (setq best (match-end 0)))
            (goto-char (1+ (match-beginning 0)))))))
    (or best estimate)))

(defun readq--decorate-extracts ()
  "Highlight the passages of this book buffer that you extracted.
For an EPUB, only those of the current chapter.  PDFs have their own
highlights."
  (remove-overlays (point-min) (point-max) 'readq-extract t)
  (when-let* ((book (and readq-show-extracts-in-epub (readq--buffer-book)))
              (format (readq--get book :format))
              ((or (eq format 'epub) (readq--point-format-p format))))
    (dolist (x (cl-remove-if (lambda (x) (or (readq--get x :parent) (readq--get x :figure)))
                             (readq--extracts-of book t)))
      (dolist (piece (readq--extract-pieces x))
        (when (or (not (eq format 'epub))
                  (eql (plist-get piece :page) nov-documents-index))
          (when-let* ((m (readq--find-text (plist-get piece :snippet)
                                          (plist-get piece :point))))
            (let ((ov (make-overlay (car m)
                                    (max (cdr m)
                                         (readq--passage-end
                                          (car m) piece
                                          ;; nov.el and eww text was unfilled.
                                          (memq format '(epub html)))))))
              (overlay-put ov 'readq-extract t)
              (overlay-put ov 'readq-extract-id (readq--get x :id))
              (overlay-put ov 'face 'readq-extract-face)
              (overlay-put ov 'help-echo
                           (concat "Extract: " (readq--get x :title)
                                   (substitute-command-keys
                                    "\n\\[readq-delete-extract] deletes it with its note"))))))))))

;;;;; Importing PDF highlights (SumatraPDF, pdf-tools, ...)

(defun readq--pdf-info-available-p ()
  "Return non-nil when pdf-tools' epdfinfo server can be used."
  (and (require 'pdf-info nil t)
       (condition-case nil (progn (pdf-info-features) t) (error nil))))

(defun readq--file-mtime (file)
  "Return the modification time of FILE as a float, or nil."
  (when-let* ((attrs (file-attributes file)))
    (float-time (file-attribute-modification-time attrs))))

(defun readq--color-rgb (color)
  "Return COLOR, a \"#rrggbb\" string, as a list of floats 0.0-1.0."
  (when (and (stringp color) (string-match "\\`#\\([[:xdigit:]]+\\)\\'" color))
    (let* ((hex (match-string 1 color))
           (n (/ (length hex) 3)))
      (when (and (> n 0) (= (length hex) (* 3 n)))
        (mapcar (lambda (i)
                  (/ (string-to-number (substring hex (* i n) (* (1+ i) n)) 16)
                     (float (1- (expt 16 n)))))
                '(0 1 2))))))

(defun readq--color-name (color)
  "Return the name of the basic color closest to COLOR, a hex string."
  (when-let* ((rgb (readq--color-rgb color)))
    (pcase-let* ((`(,r ,g ,b) rgb)
                 (mx (max r g b))
                 (d (- mx (min r g b))))
      (cond ((< mx 0.2) "black")
            ((< d 0.15) (if (> mx 0.85) "white" "gray"))
            (t (let ((h (cond ((= mx r) (mod (* 60 (/ (- g b) d)) 360))
                              ((= mx g) (+ 120 (* 60 (/ (- b r) d))))
                              (t (+ 240 (* 60 (/ (- r g) d)))))))
                 (cond ((or (< h 15) (>= h 330)) "red")
                       ((< h 45) "orange")
                       ((< h 70) "yellow")
                       ((< h 165) "green")
                       ((< h 260) "blue")
                       (t "purple"))))))))

(defun readq--color-action (color)
  "Return the action of `readq-highlight-color-rules' for COLOR."
  (let ((rule (or (assoc (readq--color-name color) readq-highlight-color-rules)
                  (assq t readq-highlight-color-rules))))
    (cdr rule)))

(defun readq--edges-area (edges-list)
  "Return the total area of EDGES-LIST, a list of (LEFT TOP RIGHT BOTTOM)."
  (apply #'+ 0.0 (mapcar (lambda (e) (pcase-let ((`(,l ,top ,r ,bot) e))
                                       (* (max 0 (- r l)) (max 0 (- bot top)))))
                         edges-list)))

(defun readq--edges-overlap (as bs)
  "Return how much the areas AS and BS overlap, from 0.0 to 1.0.
The overlap is relative to the smaller of the two."
  (if (not (and as bs))
      0.0
    (let ((inter 0.0))
      (dolist (a as)
        (dolist (b bs)
          (setq inter (+ inter (readq--edges-area
                                (list (list (max (nth 0 a) (nth 0 b))
                                            (max (nth 1 a) (nth 1 b))
                                            (min (nth 2 a) (nth 2 b))
                                            (min (nth 3 a) (nth 3 b)))))))))
      (/ inter (max 1e-12 (min (readq--edges-area as) (readq--edges-area bs)))))))

(defun readq--known-highlight-p (book page edges key)
  "Return non-nil when BOOK already has an extract for a highlight.
PAGE, EDGES and KEY describe the highlight.  Removed extracts count too."
  (cl-some (lambda (x)
             (and (eql (plist-get x :page) page)
                  (or (and key (equal key (plist-get x :key)))
                      (> (readq--edges-overlap edges (plist-get x :edges)) 0.5))))
           (append (mapcan #'readq--extract-pieces
                           (cl-remove-if (lambda (x) (readq--get x :parent))
                                         (readq--extracts-of book t)))
                   (readq--get book :dismissed))))

(defun readq--extract-pieces (x)
  "Return the passages of extract X as plists (:page :point :edges :key
:snippet :length :tail): one, or several for an extract of several
selections."
  (or (copy-tree (readq--get x :parts))
      (list (list :page (readq--get x :page) :point (readq--get x :point)
                  :edges (readq--get x :edges) :key (readq--get x :key)
                  :snippet (readq--get x :snippet) :length (readq--get x :length)
                  :tail (readq--get x :tail)))))

(defun readq--annot-text (page edges source)
  "Return the text under the highlight EDGES on PAGE of SOURCE.
Each area is read along its vertical middle: highlight boxes drawn by
viewers usually overlap the neighboring lines."
  (readq--clean-text
   (mapconcat (lambda (e)
                (pcase-let* ((`(,l ,top ,r ,bot) e)
                             (y (/ (+ top bot) 2.0)))
                  (or (ignore-errors
                        (pdf-info-gettext page (list l y r y)
                                          readq-highlight-selection-style source))
                      "")))
              edges "\n")))

(defun readq--pdf-buffer-visiting (book)
  "Return a pdf-tools buffer visiting BOOK's file, or nil."
  (cl-find-if (lambda (buf)
                (with-current-buffer buf
                  (and (derived-mode-p 'pdf-view-mode) buffer-file-name
                       (readq--same-file-p (readq--normalize-file buffer-file-name)
                                           (readq--get book :file)))))
              (buffer-list)))

(defun readq-import-highlights (book &optional quiet)
  "Turn the highlights in the PDF BOOK into extracts.
Highlights made in any viewer that saves them into the PDF (SumatraPDF,
pdf-tools, Okular, Acrobat...) are imported once; running this again
only adds new ones.  A highlight's note becomes the extract's note and
its color can set its priority, see `readq-highlight-color-rules'.
With QUIET, only report when something was imported.  Return the
number of new extracts."
  (interactive (list (readq--target-book "Import highlights from: ")))
  (when (readq--extract-p book)
    (setq book (readq--book-by-id (readq--get book :book))))
  (unless (eq (readq--get book :format) 'pdf)
    (user-error "Highlights can only be imported from PDFs"))
  (unless (readq--pdf-info-available-p)
    (user-error "Importing highlights needs pdf-tools and its epdfinfo program"))
  (let* ((file (expand-file-name (readq--get book :file)))
         (visiting (readq--pdf-buffer-visiting book))
         (source (or visiting file))
         (new 0))
    ;; epdfinfo keeps documents open and does not notice when another
    ;; program saves them, so reopen the file.  Closing it afterwards
    ;; also releases it for SumatraPDF on Windows.
    (unless visiting (ignore-errors (pdf-info-close file)))
    (unwind-protect
        (let ((annots (cl-remove-if-not
                       (lambda (a) (memq (cdr (assq 'type a)) readq-import-annotation-types))
                       (pdf-info-getannots nil source))))
          (setq annots (sort annots
                             (lambda (a b)
                               (let ((pa (cdr (assq 'page a))) (pb (cdr (assq 'page b))))
                                 (if (/= pa pb) (< pa pb)
                                   (< (nth 1 (cdr (assq 'edges a)))
                                      (nth 1 (cdr (assq 'edges b)))))))))
          (dolist (a annots)
            (let* ((page (cdr (assq 'page a)))
                   (edges (or (cdr (assq 'markup-edges a)) (list (cdr (assq 'edges a)))))
                   (color (cdr (assq 'color a)))
                   (action (readq--color-action color))
                   (text (readq--annot-text page edges source)))
              (unless (or (eq action 'skip)
                          (readq--known-highlight-p book page edges (readq--text-key text)))
                (readq--create-extract book text :page page :edges edges
                                       :comment (cdr (assq 'contents a))
                                       :color color
                                       :priority (and (numberp action) action))
                (setq new (1+ new))))))
      (unless visiting (ignore-errors (pdf-info-close file))))
    (readq--put book :annots-mtime (readq--file-mtime file))
    (readq--save)
    (readq--refresh-dashboard)
    (when (or (not quiet) (> new 0))
      (message "Imported %d new highlight%s from \"%s\""
               new (if (= new 1) "" "s") (readq--get book :title)))
    new))

(defun readq--highlights-stale-p (book)
  "Return non-nil when BOOK is a PDF changed since its last import."
  (and (eq (readq--get book :format) 'pdf)
       (not (eq (readq--get book :status) 'finished))
       (not (readq--missing-p book))
       (not (equal (readq--get book :annots-mtime)
                   (readq--file-mtime (readq--get book :file))))))

(defun readq--auto-import-highlights ()
  "Import highlights from PDFs changed since their last import."
  (when (and readq-auto-import-highlights
             (cl-some #'readq--highlights-stale-p (readq--books))
             (readq--pdf-info-available-p))
    (dolist (book (cl-remove-if-not #'readq--highlights-stale-p (readq--books)))
      (condition-case err
          (readq-import-highlights book t)
        (error
         ;; Do not retry a file that cannot be read until it changes.
         (readq--put book :annots-mtime (readq--file-mtime (readq--get book :file)))
         (message "readq: could not import highlights from %s: %s"
                  (readq--get book :title) (error-message-string err)))))))

(add-hook 'readq-before-suggest-hook #'readq--auto-import-highlights)

(defun readq-import-all-highlights ()
  "Import new highlights from all PDFs in the queue."
  (interactive)
  (let ((total 0))
    (dolist (book (readq--books))
      (when (and (eq (readq--get book :format) 'pdf) (not (readq--missing-p book)))
        (setq total (+ total (readq-import-highlights book t)))))
    (message "Imported %d new highlight%s" total (if (= total 1) "" "s"))
    total))

;;;;; Org links

(defun readq--org-follow (path &optional _arg)
  "Follow a readq: link to PATH.
PATH is an extract id, or a book id followed by ::pPAGE (PDF),
::cCHAPTER:POINT (EPUB) or ::tPOINT (text and web pages)."
  (let* ((parts (split-string path "::"))
         (item (readq--book-by-id (car parts)))
         (loc (or (cadr parts) "")))
    (cond
     ((null item) (user-error "Nothing with id %s in your reading queue" (car parts)))
     ((readq--extract-p item) (readq-goto-source item))
     ((string-match "\\`p\\([0-9]+\\)\\'" loc)
      (readq--visit-location item (string-to-number (match-string 1 loc))))
     ((string-match "\\`c\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\'" loc)
      (let ((chapter (string-to-number (match-string 1 loc)))
            (point (and (match-string 2 loc) (string-to-number (match-string 2 loc)))))
        (readq--visit-location item chapter point)))
     ((string-match "\\`t\\([0-9]+\\)\\'" loc)
      (readq--visit-location item nil (string-to-number (match-string 1 loc))))
     (t (readq-open item)))))

(defun readq--org-store-link (&optional _interactive)
  "Store a readq: link to the current page of a queued book."
  ;; Org books keep Org's own links.
  (when (and readq-org-store-links (bound-and-true-p readq-book-mode)
             (not (derived-mode-p 'org-mode)))
    (when-let* ((book (readq--buffer-book))
                (pos (readq--buffer-position))
                (page (plist-get pos :page)))
      (let ((format (readq--get book :format)))
        (org-link-store-props
         :type "readq"
         :link (format "readq:%s::%s" (readq--get book :id)
                       (cond ((eq format 'epub)
                              (format "c%d:%d" page (plist-get pos :point)))
                             ((readq--point-format-p format)
                              (format "t%d" (plist-get pos :point)))
                             (t (format "p%d" page))))
         :description (readq--source-description
                       book page (and (readq--point-format-p format)
                                      (readq--section-at (plist-get pos :point))))))
      t)))

(with-eval-after-load 'ol
  (org-link-set-parameters "readq"
                           :follow #'readq--org-follow
                           :store #'readq--org-store-link))

(provide 'readq-extract-tools)
;;; readq-extract-tools.el ends here
