;;; readq.el --- Incremental reading queue for books and documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: convenience, docs, multimedia

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

;; readq keeps a queue of the books you are reading incrementally and
;; tells you which one to pick up next.
;;
;; Every book has a priority from 0 (most important) to 100 (least
;; important), in the spirit of SuperMemo's incremental reading.  Each
;; time you finish a reading session the book is rescheduled: its
;; interval (in days) is multiplied by a factor that depends on its
;; priority.  High-priority books come back almost daily, low-priority
;; ones drift further apart.  `readq-next' closes the session in the
;; current book and opens the most important book that is due.
;;
;; Positions are tracked automatically for:
;;   - PDF files in `pdf-view-mode' (pdf-tools) or `doc-view-mode'
;;   - EPUB files in `nov-mode' (nov.el)
;;   - Org, Markdown and plain text files, in whatever mode they open
;;   - HTML files, read in eww
;;
;; Quick start:
;;
;;   (require 'readq)
;;   (readq-mode 1)
;;   (global-set-key (kbd "C-c r") readq-command-map)
;;
;; Then `C-c r a' to add a book, `C-c r l' (or M-x readq) to see your
;; queue and `C-c r n' to read the next book.
;;
;; Extracts: select a passage (pdf-tools, nov.el, or inside another
;; extract) and press `C-c r e'.  The passage is stored in an Org file
;; and becomes an item of the queue with its own priority and schedule.
;; Highlights saved into PDFs by other viewers, such as SumatraPDF, are
;; imported as extracts too (`C-c r i'; automatic when a PDF changes).
;; A PDF can be set to open in SumatraPDF with `C-c r v'; readq follows
;; your page there.
;;
;; Audio and video: add files like books, or online videos (YouTube) with
;; `C-c r u'.  They play in mpv, which readq starts; your position is
;; saved when mpv closes, Ctrl+b in mpv marks a moment as an extract, and
;; chapters can be chosen as sections.
;;
;; Tags: `C-c r #' tags a book (#cardio, #leisure...); `C-u C-c r n'
;; reads next only from some tags, and `C-c r /' focuses all suggestions
;; on them until cleared.
;;
;; Sections: `C-c r T' lists a book's table of contents (PDF outline,
;; EPUB table of contents, Org/Markdown/HTML headings); the chapters
;; you mark become queue items of their own, with their own priority and
;; schedule, read in the book without moving its bookmark.
;;
;; Flashcards: mark an extract ready with `C-c r c' (add cloze deletions
;; first with `C-c r k' if you like), then `C-c r C' exports all ready
;; extracts to org-drill or Anki.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)

(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function pdf-view-goto-page "ext:pdf-view" (page &optional window))
(declare-function pdf-cache-number-of-pages "ext:pdf-cache" (&optional file-or-buffer))
(declare-function pdf-info-number-of-pages "ext:pdf-info" (&optional file-or-buffer))
(declare-function doc-view-goto-page "doc-view" (page))
(declare-function doc-view-last-page-number "doc-view" ())
(declare-function nov-goto-document "ext:nov" (index))

(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-file-name)

;;;; Customization

(defgroup readq nil
  "Incremental reading queue for PDF and EPUB books."
  :group 'applications
  :prefix "readq-")

(defcustom readq-db-file (locate-user-emacs-file "readq.eld")
  "File where readq stores your books and reading progress."
  :type 'file)

(defcustom readq-file-extensions
  '(("pdf" . pdf) ("epub" . epub)
    ("org" . text) ("md" . text) ("markdown" . text) ("txt" . text)
    ("html" . html) ("htm" . html)
    ("mp3" . media) ("m4a" . media) ("m4b" . media) ("aac" . media) ("ogg" . media)
    ("opus" . media) ("flac" . media) ("wav" . media)
    ("mp4" . media) ("m4v" . media) ("mkv" . media) ("webm" . media) ("mov" . media)
    ("avi" . media))
  "Alist mapping file extensions to book formats.
The format `pdf' means a page-based document (pdf-tools or doc-view);
`epub' a chapter-based document read with nov.el; `text' a text file
read in its usual mode (Org, Markdown, plain text); `html' a web page
read in eww; `media' audio or video, played in mpv."
  :type '(alist :key-type string
                :value-type (choice (const :tag "Page based (PDF)" pdf)
                                    (const :tag "Chapter based (EPUB)" epub)
                                    (const :tag "Text (Org, Markdown...)" text)
                                    (const :tag "Web page, read in eww" html)
                                    (const :tag "Audio or video, played in mpv" media))))

(defcustom readq-default-priority 50
  "Default priority for new books: 0 is most important, 100 least."
  :type 'number)

(defcustom readq-priority-step 5
  "How much `readq-priority-up' and `readq-priority-down' change priority."
  :type 'number)

(defcustom readq-initial-interval 1
  "Interval in days given to a newly added book."
  :type 'number)

(defcustom readq-min-afactor 1.2
  "Interval multiplier used for books with priority 0.
After each session the interval of a book is multiplied by a factor
between `readq-min-afactor' (priority 0) and `readq-max-afactor'
\(priority 100)."
  :type 'number)

(defcustom readq-max-afactor 2.5
  "Interval multiplier used for books with priority 100.
See `readq-min-afactor'."
  :type 'number)

(defcustom readq-min-interval 1
  "Shortest interval in days between two sessions of the same book."
  :type 'number)

(defcustom readq-max-interval 60
  "Longest interval in days between two sessions of the same book."
  :type 'number)

(defcustom readq-postpone-factor 1.5
  "Factor applied to the interval of a book when you postpone it."
  :type 'number)

(defcustom readq-randomization 0.0
  "Amount of randomness used when `readq-next' picks a book.
0 means strictly by priority.  1 means each priority is shifted by up
to +/-50 points, so lower-priority books occasionally get a turn."
  :type 'number)

(defcustom readq-restore-position t
  "When non-nil, jump to the saved position when a tracked book is opened."
  :type 'boolean)

(defcustom readq-kill-buffer-after-session nil
  "When non-nil, `readq-next' kills the buffer of the book you just finished."
  :type 'boolean)

(defcustom readq-min-session-seconds 60
  "Reading time needed for a session to count when you did not move.
A session that ends with you on the same page counts as a review (and
reschedules the book) only if you read for at least this many seconds.
Sessions where you advanced always count."
  :type 'integer)

(defcustom readq-idle-threshold 300
  "Seconds of idleness after which reading time stops being counted."
  :type 'integer)

(defcustom readq-tick-interval 15
  "Seconds between two automatic position saves and time measurements."
  :type 'integer)

(defcustom readq-queue-extracts t
  "When non-nil, extracts are suggested by `readq-next' along with books."
  :type 'boolean)

(defcustom readq-finished-threshold 0.99
  "Progress (0.0-1.0) from which a book counts as read to the end."
  :type 'number)

(defcustom readq-tags-width 16
  "Width of the Tags column in the readq dashboard."
  :type 'integer)

(defcustom readq-ask-tags t
  "When non-nil, adding books asks for their tags (you can leave them empty)."
  :type 'boolean)

(defcustom readq-title-width 40
  "Width of the Title column in the readq dashboard."
  :type 'integer)

(defcustom readq-progress-bar-width 12
  "Width of the progress bar in the readq dashboard."
  :type 'integer)

(defcustom readq-progress-bar-chars '(?█ . ?░)
  "Characters used to draw progress bars: (DONE . REMAINING)."
  :type '(cons character character))

(defcustom readq-dashboard-columns
  '(priority kind title tags progress position extracts due deadline time)
  "Columns of the readq dashboard, in order.
The Tags and Deadline columns appear only when something has tags or
a deadline.  Also available: `interval' (days until the item comes back
after its next review) and `last-read'."
  :type '(repeat (choice (const :tag "Priority" priority)
                         (const :tag "Kind (icon)" kind)
                         (const :tag "Title" title)
                         (const :tag "Tags" tags)
                         (const :tag "Progress bar" progress)
                         (const :tag "Position" position)
                         (const :tag "Number of extracts" extracts)
                         (const :tag "Due" due)
                         (const :tag "Deadline" deadline)
                         (const :tag "Interval" interval)
                         (const :tag "Last read" last-read)
                         (const :tag "Reading time" time))))

(defcustom readq-dashboard-icons t
  "When non-nil, the dashboard shows icons from the all-the-icons package.
Icons mark each item's kind (PDF, EPUB, recording, extract...) and
whether it is due, late, paused or finished.  They need all-the-icons
and its fonts (`all-the-icons-install-fonts'), and a graphical Emacs;
otherwise the dashboard shows words."
  :type 'boolean)

(defface readq-due-face '((t :inherit bold))
  "Face for books that are due today or overdue.")

(defface readq-overdue-face '((t :inherit warning))
  "Face for the Due column of overdue books.")

(defface readq-inactive-face '((t :inherit shadow))
  "Face for paused and finished books.")

(defface readq-missing-face '((t :inherit error))
  "Face for books whose file cannot be found.")

(defface readq-progress-face '((t :inherit success))
  "Face for the filled part of progress bars.")

(defgroup readq-extracts nil
  "Extracts: passages of your books that you review incrementally."
  :group 'readq
  :prefix "readq-")

(defcustom readq-extracts-directory nil
  "Where the Org files holding your extracts go, one file per book.
When nil, each book's extracts are saved in the book's own directory,
in an Org file named after the book: the extracts of
\"Gray's Anatomy.pdf\" go to \"Gray's Anatomy.org\".  When a
directory, all extracts files go there instead.

If the book's directory is not writable, extracts go to
`readq-extracts-fallback-directory'.  A book whose extracts file
already exists keeps it; changing this option affects new books."
  :type '(choice (const :tag "Next to each book" nil) directory))

(defcustom readq-extracts-fallback-directory (locate-user-emacs-file "readq-extracts/")
  "Where extracts go when the directory of their book is not writable."
  :type 'directory)

(defcustom readq-extract-initial-interval 1
  "Days until a new extract is first due for review."
  :type 'number)

(defcustom readq-extract-priority-offset 0
  "Added to the source's priority to get a new extract's priority.
A negative value makes extracts more important than their book."
  :type 'number)

(defcustom readq-extract-add-highlight t
  "When non-nil, `readq-extract' in pdf-tools also highlights the passage.
The highlight is saved into the PDF, so you see it in SumatraPDF too."
  :type 'boolean)

(defcustom readq-extract-highlight-color "#ffff00"
  "Color of the highlights `readq-extract' adds to PDFs."
  :type 'color)

(defcustom readq-extract-multiple 'combine
  "What `readq-extract' does when several passages are selected.
Several passages are selected with multi-region (`multi-region-mode')
or, in a PDF, with pdf-tools' C-drag.  `combine' makes one extract of
all of them, as separate paragraphs; `separate' makes one extract per
passage.  \\[universal-argument] \\[universal-argument] \\[readq-extract] does the other."
  :type '(choice (const :tag "One extract with all passages" combine)
                 (const :tag "One extract per passage" separate)))

(defcustom readq-extract-separator "\n\n"
  "Text between the passages of an extract made of several selections."
  :type 'string)

(defcustom readq-extract-title-length 60
  "Number of characters of an extract used as its Org heading."
  :type 'integer)

(defcustom readq-narrow-to-extract t
  "When non-nil, narrow the Org buffer to the extract being reviewed."
  :type 'boolean)

(defcustom readq-auto-import-highlights t
  "When non-nil, import new PDF highlights automatically.
This happens when you open the dashboard or run `readq-next', for each
PDF modified since its last import.  It needs pdf-tools."
  :type 'boolean)

(defcustom readq-import-annotation-types '(highlight underline squiggly strike-out)
  "PDF annotation types that `readq-import-highlights' turns into extracts."
  :type '(set (const highlight) (const underline) (const squiggly)
              (const strike-out)))

(defcustom readq-highlight-color-rules nil
  "What to do with imported highlights depending on their color.
An alist of (COLOR . ACTION).  COLOR is one of the names \"red\",
\"orange\", \"yellow\", \"green\", \"blue\", \"purple\", \"gray\",
\"black\" or \"white\", or t for any other color.  ACTION is a number
\(the priority of the new extract), `skip' (do not import), or nil (use
the book's priority).  For example:

  \\='((\"red\" . 5) (\"yellow\" . nil) (\"green\" . skip))"
  :type '(alist :key-type (choice string (const :tag "Any other color" t))
                :value-type (choice (const :tag "Book's priority" nil)
                                    (const :tag "Do not import" skip)
                                    (number :tag "Priority"))))

(defcustom readq-highlight-selection-style 'word
  "How text under a highlight is read: `glyph', `word' or `line'.
With `word', a highlight that stops in the middle of a word still
imports the whole word."
  :type '(choice (const glyph) (const word) (const line)))

(defcustom readq-show-extracts-in-epub t
  "When non-nil, passages you extracted are highlighted in their book.
This applies to EPUBs (nov.el), text books and web pages."
  :type 'boolean)

(defcustom readq-org-store-links t
  "When non-nil, `org-store-link' in a book stores a readq: link to the page."
  :type 'boolean)

(defcustom readq-default-pdf-viewer 'emacs
  "Viewer used for PDFs, unless chosen per book with `readq-set-viewer'."
  :type '(choice (const :tag "Emacs (pdf-tools or doc-view)" emacs)
                 (const :tag "SumatraPDF" sumatra)))

(defcustom readq-sumatra-program nil
  "SumatraPDF executable, or nil to look for it.
readq looks in PATH and in the usual install folders, e.g.
\"~/AppData/Local/SumatraPDF/SumatraPDF.exe\"."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom readq-sumatra-settings-file nil
  "SumatraPDF's settings file, where it remembers your page, or nil.
nil looks for SumatraPDF-settings.txt next to the program (portable
version), then in %LOCALAPPDATA%/SumatraPDF/ (installed version)."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom readq-sumatra-poll-interval 5
  "Seconds between two looks at SumatraPDF's settings during a session."
  :type 'number)

(defcustom readq-external-max-session-minutes 120
  "Longest reading time counted for one session in SumatraPDF.
Time is measured from opening to closing the document, so this caps
sessions where you walked away."
  :type 'integer)

(defface readq-extract-face '((t :inherit highlight))
  "Face for extracted passages in EPUB buffers.")

(defgroup readq-flashcards nil
  "Turning extracts into flashcards (org-drill or Anki)."
  :group 'readq
  :prefix "readq-")

(defcustom readq-flashcard-backend 'ask
  "Where `readq-export-cards' sends flashcards.
`anki' for Anki, `org-drill' for org-drill files, or `ask' to choose
at each export."
  :type '(choice (const :tag "Ask each time" ask)
                 (const :tag "Anki" anki)
                 (const :tag "org-drill" org-drill)))

(defcustom readq-card-ready-tag "ready"
  "Org tag of extracts that are ready to become flashcards.
`readq-mark-ready' adds it; you can also add it by hand."
  :type 'string)

(defcustom readq-card-exported-tag "exported"
  "Org tag given to extracts once they were exported as flashcards."
  :type 'string)

(defcustom readq-dismiss-after-export t
  "When non-nil, an extract leaves the reading queue once exported.
Its flashcard takes over.  When nil, it goes back into the queue."
  :type 'boolean)

(defcustom readq-drill-file nil
  "Org file that receives org-drill cards.
When nil, each book gets its own cards file next to its extracts file,
e.g. \"Gray's Anatomy-cards.org\".  Run `org-drill' in that file (or
set `org-drill-scope' to `directory' to drill all books of a folder)."
  :type '(choice (const :tag "One file per book, next to the book" nil) file))

(defcustom readq-anki-method 'ankiconnect
  "How cards reach Anki.
`ankiconnect' adds them directly to the running Anki through the
AnkiConnect add-on; if Anki cannot be reached, readq offers to write
the import file instead.  `file' always writes `readq-anki-export-file',
which you import with File > Import in Anki."
  :type '(choice (const :tag "AnkiConnect add-on" ankiconnect)
                 (const :tag "Import file" file)))

(defcustom readq-anki-connect-url "http://127.0.0.1:8765"
  "Address of AnkiConnect."
  :type 'string)

(defcustom readq-anki-export-file "~/readq-anki-import.txt"
  "File written for Anki's File > Import when AnkiConnect is not used.
New cards are added to the end; delete the file after importing it."
  :type 'file)

(defcustom readq-anki-deck "readq"
  "Anki deck receiving the cards."
  :type 'string)

(defcustom readq-anki-subdeck-per-book t
  "When non-nil, each book gets a subdeck, e.g. \"readq::Gray's Anatomy\"."
  :type 'boolean)

(defcustom readq-anki-tags '("readq")
  "Tags given to Anki notes, in addition to a tag naming the book."
  :type '(repeat string))

(defcustom readq-anki-basic-model '("Basic" "Front" "Back")
  "Anki note type for question/answer cards: (NAME FRONT-FIELD BACK-FIELD).
Change it if your Anki uses other names, e.g. in another language."
  :type '(list string string string))

(defcustom readq-anki-cloze-model '("Cloze" "Text" "Back Extra")
  "Anki note type for cloze cards: (NAME TEXT-FIELD EXTRA-FIELD)."
  :type '(list string string string))

;;;; Database

(defvar readq--books nil
  "List of book plists.  Use `readq--books' (the function) to access it.")

(defvar readq--loaded nil
  "Non-nil once `readq-db-file' has been read.")

(defvar readq--dirty nil
  "Non-nil when there are unsaved changes.")

(defvar readq--known-probe nil
  "(URL . PROBE) just found by `readq-add-url', so it is not asked twice.")

;; json.el is loaded only when needed; its settings are special variables.
(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)
(defvar json-false)

(defvar readq--focus nil
  "Tags the reading is focused on, or nil.  See `readq-focus'.
Saved with the database.")

(defvar readq--log nil
  "Reading done per day: a list of (DATE :seconds SECS :items N), newest first.
Saved with the database.  See `readq-daily-minutes'.")

(defvar readq--tag-deadlines nil
  "Deadlines of tags: a list of (TAG . DATE).  Saved with the database.
See `readq-set-tag-deadline'.")

(defvar readq--spread-date nil
  "The date on which items over the daily budget were last spread out.
Saved with the database.")

(defun readq--load ()
  "Read the database from `readq-db-file'."
  (setq readq--books nil
        readq--focus nil
        readq--log nil
        readq--spread-date nil
        readq--tag-deadlines nil)
  (when (file-readable-p readq-db-file)
    (with-temp-buffer
      (insert-file-contents readq-db-file)
      (goto-char (point-min))
      (let ((data (condition-case err
                      (read (current-buffer))
                    (error
                     (error "readq: cannot read %s: %S" readq-db-file err)))))
        (setq readq--books (copy-tree (plist-get data :books))
              readq--focus (plist-get data :focus)
              readq--log (copy-tree (plist-get data :log))
              readq--spread-date (plist-get data :spread-date)
              readq--tag-deadlines (copy-tree (plist-get data :tag-deadlines))))))
  (setq readq--loaded t
        readq--dirty nil))

(defun readq--books ()
  "Return the list of all books, loading the database if needed."
  (unless readq--loaded (readq--load))
  readq--books)

(defun readq--save ()
  "Write the database to `readq-db-file'."
  (when readq--loaded
    (let ((print-length nil)
          (print-level nil)
          (print-escape-newlines t)
          (coding-system-for-write 'utf-8-unix)
          (dir (file-name-directory (expand-file-name readq-db-file))))
      (make-directory dir t)
      (with-temp-file readq-db-file
        (insert ";;; readq database  -*- mode: lisp-data; coding: utf-8 -*-\n"
                (format "(:version 1\n :focus %S\n :tag-deadlines %S\n :spread-date %S\n :log %S\n :books\n ("
                        readq--focus readq--tag-deadlines readq--spread-date readq--log))
        (dolist (book readq--books)
          (prin1 book (current-buffer))
          (insert "\n  "))
        (insert "))\n")))
    (setq readq--dirty nil)))

(defun readq--get (book key)
  "Return the value of KEY in BOOK."
  (plist-get book key))

(defun readq--put (book &rest kvs)
  "Set keys in BOOK from the alternating KVS.  Mark the database dirty."
  (while kvs
    (let ((k (pop kvs)) (v (pop kvs)))
      (unless (equal (plist-get book k) v)
        (plist-put book k v)
        (setq readq--dirty t))))
  book)

(defun readq--url-p (file)
  "Return non-nil when FILE is a URL (an online video, for example)."
  (and (stringp file) (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" file)))

(defun readq--normalize-file (file)
  "Return the canonical name used to identify FILE.  URLs are kept as is."
  (if (readq--url-p file)
      file
    (abbreviate-file-name (file-truename (expand-file-name file)))))

(defvar readq--id-index nil
  "Hash table of items by id, while the dashboard is drawn, or nil.")

(defun readq--book-by-id (id)
  "Return the book whose id is ID."
  (if readq--id-index
      (gethash id readq--id-index)
    (cl-find id (readq--books) :key (lambda (b) (readq--get b :id)) :test #'equal)))

(defun readq--same-file-p (a b)
  "Return non-nil when normalized file names A and B are the same file.
File names are compared case-insensitively on Windows."
  (and a b
       (if (memq system-type '(windows-nt ms-dos cygwin))
           (eq t (compare-strings a nil nil b nil nil t))
         (string= a b))))

(defun readq--extract-p (item)
  "Return non-nil when ITEM is an extract rather than a book."
  (eq (readq--get item :format) 'extract))

(defun readq--section-p (item)
  "Return non-nil when ITEM is a section of a book."
  (eq (readq--get item :format) 'section))

(defun readq--book-p (item)
  "Return non-nil when ITEM is a book (not an extract or a section)."
  (not (memq (readq--get item :format) '(extract section))))

(defun readq--item-book (item)
  "Return the book ITEM belongs to: ITEM itself if it is a book."
  (if (readq--book-p item) item (readq--book-by-id (readq--get item :book))))

(defun readq--book-by-file (file)
  "Return the book stored for FILE, or nil."
  (when file
    (let ((name (readq--normalize-file file)))
      (cl-find-if (lambda (b) (and (readq--book-p b)
                                   (readq--same-file-p name (readq--get b :file))))
                  (readq--books)))))

(defun readq--new-id ()
  "Return a fresh, unique book id."
  (let (id)
    (while (or (null id) (readq--book-by-id id))
      (setq id (format "%x%04x" (truncate (float-time)) (random 65536))))
    id))

(defun readq--format (file)
  "Return the book format of FILE according to `readq-file-extensions'.
URLs are `media': they are played in mpv."
  (if (readq--url-p file)
      'media
    (when-let ((ext (file-name-extension file)))
      (cdr (assoc (downcase ext) readq-file-extensions)))))

;;;; Dates and scheduling

(defun readq--today-noon (&optional now)
  "Return noon of the day of NOW (default: the current time)."
  (let ((d (decode-time (or now (current-time)))))
    (encode-time (list 0 0 12 (nth 3 d) (nth 4 d) (nth 5 d) nil -1 nil))))

(defun readq--today (&optional now)
  "Return today's date (or NOW's date) as a YYYY-MM-DD string."
  (format-time-string "%F" (or now (current-time))))

(defun readq--date-in (days &optional now)
  "Return the YYYY-MM-DD date DAYS days after NOW."
  (format-time-string "%F" (time-add (readq--today-noon now)
                                     (* 86400 (round days)))))

(defun readq--date-noon (date)
  "Return noon of the YYYY-MM-DD string DATE as a time value."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (encode-time (list 0 0 12 d m y nil -1 nil))))

(defun readq--days-until (date &optional now)
  "Return the number of days from NOW until DATE (negative when past)."
  (round (/ (float-time (time-subtract (readq--date-noon date)
                                       (readq--today-noon now)))
            86400.0)))

(defun readq--afactor (priority)
  "Return the interval multiplier for PRIORITY."
  (let ((p (/ (min 100.0 (max 0.0 (float priority))) 100.0)))
    (+ readq-min-afactor (* p (- readq-max-afactor readq-min-afactor)))))

(defun readq--next-interval (interval priority)
  "Return the interval following INTERVAL for a book of PRIORITY."
  (min (float readq-max-interval)
       (max (float readq-min-interval)
            (* (float (or interval readq-initial-interval))
               (readq--afactor priority)))))

(defun readq--reschedule (book &optional now)
  "Compute a new interval for BOOK and set its due date relative to NOW."
  (let ((interval (readq--next-interval (readq--get book :interval)
                                        (readq--get book :priority))))
    (readq--put book
                :interval interval
                :due (readq--date-in (max 1 (round interval)) now))
    (readq--apply-deadline book now)))

(defun readq--active-p (book)
  "Return non-nil when BOOK is neither paused nor finished."
  (eq (readq--get book :status) 'active))

(defun readq--due-p (book &optional now)
  "Return non-nil when BOOK is active and due on NOW's date."
  (and (readq--active-p book)
       (not (string< (readq--today now) (or (readq--get book :due) "")))))

(defun readq--missing-p (book)
  "Return non-nil when BOOK's file does not exist.  URLs never are."
  (let ((file (readq--get book :file)))
    (and (not (readq--url-p file)) (not (file-exists-p file)))))

(defun readq--queue (&optional randomize now tags)
  "Return active, available books in the order they should be read.
Books due on NOW's date come first, most important first; then books
that are not due yet, soonest first.  With RANDOMIZE, priorities of
due books are shifted by `readq-randomization'.  With TAGS, only items
with one of these tags are included, see `readq--tags-match-p'."
  (let* ((today (readq--today now))
         (keyed
          (mapcar
           (lambda (b)
             (let ((pri (float (readq--get b :priority))))
               (when (and randomize (> readq-randomization 0))
                 (setq pri (+ pri (* readq-randomization 100.0
                                     (- (/ (random 10001) 10000.0) 0.5)))))
               (list b (if (readq--due-p b now) 0 1) pri
                     (or (readq--get b :due) today))))
           (cl-remove-if-not (lambda (b) (and (readq--active-p b)
                                              (or readq-queue-extracts
                                                  (not (readq--extract-p b)))
                                              (readq--tags-match-p b tags)
                                              (not (readq--missing-p b))))
                             (readq--books)))))
    (mapcar #'car
            (sort keyed
                  (lambda (a b)
                    (pcase-let ((`(,_ ,da ,pa ,ya) a)
                                (`(,_ ,db ,pb ,yb) b))
                      (cond ((/= da db) (< da db))
                            ((= da 0) (if (= pa pb) (string< ya yb) (< pa pb)))
                            ((string= ya yb) (< pa pb))
                            (t (string< ya yb)))))))))

;;;; Progress

(defun readq--progress-from (format page point point-max total)
  "Return progress (0.0-1.0) for a position in a book of FORMAT.
PAGE is the 1-based page (pdf) or 0-based chapter index (epub).
POINT and POINT-MAX describe the position in an epub chapter.
TOTAL is the number of pages or chapters."
  (cond
   ((readq--point-format-p format)
    (and point point-max
         (min 1.0 (/ (float (1- point)) (max 1 (1- point-max))))))
   ((not (and page total (> total 0))) nil)
   ((eq format 'epub)
    (let ((frac (if (and point point-max (> point-max 1))
                    (/ (float (1- point)) (1- point-max))
                  0.0)))
      (min 1.0 (/ (+ page frac) (float total)))))
   (t (min 1.0 (/ (float page) total)))))

(defun readq--at-end-p (book)
  "Return non-nil when BOOK (or a section) has been read to the end."
  (let ((page (readq--get book :page))
        (total (if (readq--section-p book) (readq--get book :end) (readq--get book :total)))
        (format (readq--get (readq--item-book book) :format)))
    (if (and (eq format 'pdf) page total)
        (>= page total)
      (>= (or (readq--get book :progress) 0) readq-finished-threshold))))

(defun readq--position-string (book)
  "Return a short description of BOOK's position.
For an extract, return the position of the extract in its source."
  (let ((page (readq--get book :page))
        (total (readq--get book :total)))
    (cond ((readq--section-p book)
           (let ((start (readq--get book :start)) (end (readq--get book :end)))
             (pcase (readq--get (readq--item-book book) :format)
               ('pdf (format "p %d (%d–%d)" (or page start) start end))
               ('epub (format "ch %d (%d–%d)" (1+ (or page start)) (1+ start) (1+ end)))
               ('media (format "%s (%s)" (readq--format-time (or (readq--get book :time) start))
                               (readq--section-location book)))
               (_ (format "%s %d%%" (readq--section-location book)
                          (floor (* 100 (or (readq--get book :progress) 0))))))))
          ((and (eq (readq--get book :format) 'media) (not (readq--extract-p book)))
           (format "%s / %s" (readq--format-time (or (readq--get book :time) 0))
                   (if total (readq--format-time total) "?")))
          ((null page) "-")
          ((readq--extract-p book)
           (let ((format (readq--get (readq--book-by-id (readq--get book :book))
                                     :format)))
             (cond ((eq format 'epub) (format "ch %d" (1+ page)))
                   ((eq format 'media) (readq--format-time page))
                   ((readq--point-format-p format)
                    (if (> page 0) (format "§ %d" page) "start"))
                   (t (format "p %d" page)))))
          ((eq (readq--get book :format) 'epub)
           (format "ch %d/%s" (1+ page) (or total "?")))
          ((readq--point-format-p (readq--get book :format))
           (if (and total (> total 0))
               (format "§ %d/%d" page total)
             (format "%d%%" (floor (* 100 (or (readq--get book :progress) 0))))))
          (t (format "p %d/%s" page (or total "?"))))))

(defun readq--progress-bar (progress)
  "Return a progress bar string for PROGRESS (0.0-1.0)."
  (let* ((w readq-progress-bar-width)
         (n (round (* w (min 1.0 (max 0.0 (or progress 0)))))))
    (concat (propertize (make-string n (car readq-progress-bar-chars))
                        'face 'readq-progress-face)
            (make-string (- w n) (cdr readq-progress-bar-chars))
            (format " %3d%%" (floor (* 100 (or progress 0)))))))

(defun readq--duration-string (seconds)
  "Return SECONDS as a compact duration like 3h05m."
  (let* ((m (round (or seconds 0) 60)))
    (if (< m 60) (format "%dm" m) (format "%dh%02dm" (/ m 60) (% m 60)))))

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
        buffer-file-name)))

(defun readq--buffer-book (&optional buffer)
  "Return the book shown in BUFFER (default: current buffer), or nil."
  (with-current-buffer (or buffer (current-buffer))
    (if readq--book-id
        (readq--book-by-id readq--book-id)
      (let ((file (readq--buffer-file)))
        (and file (readq--format file) (readq--book-by-file file))))))

(defun readq--buffer-position ()
  "Return the position in the current buffer as a plist, or nil.
Keys are :page, :point, :point-max and :total."
  (let ((win (get-buffer-window (current-buffer) t)))
    (cond
     ((derived-mode-p 'pdf-view-mode)
      (list :page (image-mode-window-get 'page win)
            :total (ignore-errors (pdf-cache-number-of-pages))))
     ((derived-mode-p 'doc-view-mode)
      (list :page (image-mode-window-get 'page win)
            :total (let ((n (ignore-errors (doc-view-last-page-number))))
                     (and (integerp n) (> n 0) n))))
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
    (when-let ((win (get-buffer-window (current-buffer) t)))
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
            (when-let ((progress (readq--section-progress item pos)))
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
       ((derived-mode-p 'doc-view-mode)
        (doc-view-goto-page page))
       ((derived-mode-p 'nov-mode)
        (unless (eql page nov-documents-index)
          (nov-goto-document page))
        (goto-char (max (point-min) (min (or point (point-min)) (point-max))))
        (when-let ((win (get-buffer-window (current-buffer) t)))
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
  (when-let ((book (readq--current-item)))
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

(defun readq--tick ()
  "Count reading time and save the position of the book being read."
  (condition-case err
      (let ((buf (window-buffer (selected-window))))
        (when (buffer-local-value 'readq-review-mode buf)
          (let ((idle (current-idle-time)))
            (when (or (null idle) (< (float-time idle) readq-idle-threshold))
              (with-current-buffer buf
                (setq readq--session-seconds
                      (+ readq--session-seconds readq-tick-interval))))))
        (when (buffer-local-value 'readq-book-mode buf)
          (with-current-buffer buf
            (let ((idle (current-idle-time)))
              (when (or (null idle) (< (float-time idle) readq-idle-threshold))
                (setq readq--session-seconds
                      (+ readq--session-seconds readq-tick-interval))))
            (readq--record-position)))
        (when readq--dirty (readq--save)))
    (error (message "readq: %S" err))))

(defun readq--save-all ()
  "Save every open session and the database (for `kill-emacs-hook')."
  (when (readq--media-playing-p) (ignore-errors (readq--media-stop)))
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'readq-book-mode buf)
      (with-current-buffer buf (readq--on-kill))))
  (when readq--dirty (readq--save)))

(defvar readq--timer nil
  "Timer running `readq--tick'.")

(defconst readq--mode-hooks
  '(pdf-view-mode-hook doc-view-mode-hook nov-mode-hook find-file-hook)
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
           (when-let ((id (tabulated-list-get-id))) (readq--book-by-id id)))
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
  "Return non-nil when FILE is an extracts or flashcards file of readq."
  (and (member (downcase (or (file-name-extension file) "")) '("org" "txt" "md"))
       (file-readable-p file)
       (with-temp-buffer
         (ignore-errors (insert-file-contents file nil 0 4000))
         (goto-char (point-min))
         (re-search-forward "^#\\+READQ_BOOK:\\|^:READQ_ID:\\|^:READQ_CARD_OF:" nil t))))

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
        (readq--put section :file (readq--get book :file)))
      (readq--move-extracts-file book old)))
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
PDFs whose viewer is SumatraPDF (see `readq-set-viewer') open there.
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
         ((not existing) (find-file file))
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
\"read next, but only from #cardio\"."
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
          (kill-buffer cur-buf)))))))

;;;###autoload
(defun readq-suggest ()
  "Show which books and extracts you should read next, in order."
  (interactive)
  (let* ((q (readq--queue nil nil readq--focus))
         (due (cl-remove-if-not #'readq--due-p q))
         (in (if readq--focus (concat " in " (readq--tags-string-of readq--focus)) "")))
    (cond ((null q) (message "Your reading queue is empty%s." in))
          ((null due)
           (message "Nothing is due today%s.  Next up: \"%s\" on %s"
                    in (readq--get (car q) :title) (readq--get (car q) :due)))
          (t (message "%d due today%s: %s" (length due) in
                      (mapconcat (lambda (b) (format "\"%s\"" (readq--get b :title)))
                                 (cl-subseq due 0 (min 3 (length due))) ", "))))))

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
  (let ((book (readq--item-book book)))
    (if (and book (eq (readq--get book :format) 'pdf))
        (let ((viewer (or (readq--get book :viewer) readq-default-pdf-viewer)))
          ;; Books once set to Okular, which readq no longer supports.
          (if (eq viewer 'okular) 'sumatra viewer))
      'emacs)))

(defun readq-set-viewer (book viewer)
  "Choose the VIEWER (`emacs' or `sumatra') used to read the PDF BOOK."
  (interactive
   (let ((b (readq--target-book "Set viewer of: ")))
     (unless (eq (readq--get b :format) 'pdf)
       (user-error "Only PDFs can be read in an external viewer"))
     (list b (intern (completing-read "Read this PDF in: " '("emacs" "sumatra")
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
                        (list (when-let ((local (getenv "LOCALAPPDATA")))
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
                        (list (when-let ((prog (ignore-errors (readq--sumatra-program))))
                                (expand-file-name "SumatraPDF-settings.txt"
                                                  (file-name-directory prog)))
                              (when-let ((local (getenv "LOCALAPPDATA")))
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
          (when-let ((progress (if section
                                   (readq--section-progress book (list :page page))
                                 (readq--progress-from 'pdf page nil nil total))))
            (readq--put book :progress progress))
          (readq--add-seconds book secs)
          (readq--count-session book from-page from secs)
          (readq--save)
          (readq--refresh-dashboard)
          (readq--report-rescheduled
           book (format "Session saved at page %d%s" page
                        (if auto (substitute-command-keys
                                  " (\\[readq-next] for the next item)")
                          "")))
          book)))))

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
      (when-let ((bounds (and point (readq--section-bounds section))))
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
      ('pdf (if (eql start end) (format "p %d" start) (format "p %d–%d" start end)))
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
                        (when-let ((href (cdr (assq 'href (cadr node)))))
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
     (unless (eq (readq--get b :format) 'pdf)
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
         (t (let ((readq--inhibit-restore t)) (find-file file))))
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
      (when-let ((bounds (readq--section-bounds section)))
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
    (when-let ((book (readq--buffer-book)))
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
                       ('pdf (format "p %d–%d" (plist-get e :start) (plist-get e :end)))
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
                  (if (eq (readq--get book :format) 'pdf)
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
  (when-let ((i (tabulated-list-get-id)))
    (puthash i (or priority (gethash i readq--sections-marks)
                   (readq--sections-default-priority))
             readq--sections-marks)
    (tabulated-list-print t)
    (forward-line 1)))

(defun readq-sections-unmark ()
  "Unmark the section at point; move down."
  (interactive)
  (when-let ((i (tabulated-list-get-id)))
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
  (when-let ((i (tabulated-list-get-id)))
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
  "Face for tags in the readq dashboard.")

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

;;;; Audio and video (mpv)

;; Audio and video files, and online videos (URLs, YouTube...), are
;; played in mpv, started by readq.  A small Lua script readq gives mpv
;; reports on mpv's standard output: the duration, title and chapters
;; when the file is loaded, the position every `readq-mpv-interval'
;; seconds, the moments you mark (`readq-mpv-mark-key'), and how
;; playback ended.  When mpv closes, the session is saved: position,
;; progress, listening time, and an extract for each mark.  If mpv's
;; output does not reach Emacs, the position mpv saves on quitting
;; (--save-position-on-quit, in a folder of its own) is used instead.

(defgroup readq-media nil
  "Audio and video in readq, played in mpv."
  :group 'readq
  :prefix "readq-")

(defcustom readq-mpv-program nil
  "The mpv program, or nil to look for it.
On Windows readq prefers mpv.com (next to mpv.exe), whose output
reaches Emacs."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom readq-mpv-args '("--force-window=yes")
  "Extra arguments for mpv when playing.
--force-window=yes gives audio files a window too, so you can pause,
mark and quit there."
  :type '(repeat string))

(defcustom readq-mpv-mark-key "Ctrl+b"
  "Key, in mpv's notation, that marks the current moment as an extract."
  :type 'string)

(defcustom readq-mpv-figure-key "Ctrl+f"
  "Key, in mpv's notation, that saves the frame shown as a figure extract."
  :type 'string)

(defcustom readq-mpv-mark-lead 10
  "Seconds before a marked moment that playing it back starts."
  :type 'number)

(defcustom readq-mpv-interval 5
  "Seconds between two position reports from mpv."
  :type 'number)

(defcustom readq-media-finish-at-end t
  "When non-nil, audio or video played to its end is marked finished.
For a section (a chapter), this is the end of the chapter."
  :type 'boolean)

(defcustom readq-mpv-ytdl-format nil
  "Format for online videos, passed to mpv as --ytdl-format, or nil.
For example \"bestvideo[height<=?720]+bestaudio/best\", or \"bestaudio\"
to only listen."
  :type '(choice (const :tag "mpv's default" nil) string))

(defcustom readq-mpv-ytdl-path nil
  "The yt-dlp program mpv uses for online videos, or nil for mpv's choice."
  :type '(choice (const :tag "mpv's choice" nil) file))

(defconst readq--mpv-script
  "-- readq: report playback to Emacs.  Written by readq.el; do not edit.
local utils = require 'mp.utils'
local opts = {interval = 5, probe = 'no', markkey = 'Ctrl+b', figkey = 'Ctrl+f', shotdir = ''}
require('mp.options').read_options(opts, 'readq')
local last = nil
local function emit(t)
  io.stdout:write('READQ ' .. utils.format_json(t) .. '\\n')
  io.stdout:flush()
end
mp.observe_property('time-pos', 'number', function(_, v) if v then last = v end end)
local loaded, reported = false, false
local function report()
  if reported then return end
  reported = true
  emit({event = 'loaded', duration = mp.get_property_number('duration'),
        title = mp.get_property('media-title'),
        chapters = mp.get_property_native('chapter-list')})
  if opts.probe == 'yes' then mp.command('quit') end
end
-- Streams may learn their duration a moment after loading.
mp.observe_property('duration', 'number', function(_, v)
  if v and loaded then
    if reported then emit({event = 'duration', duration = v}) else report() end
  end
end)
mp.register_event('file-loaded', function()
  loaded = true
  if mp.get_property_number('duration') or opts.probe ~= 'yes' then
    report()
  else
    mp.add_timeout(3, report)
  end
end)
mp.add_periodic_timer(tonumber(opts.interval), function()
  if last then emit({event = 'pos', pos = last}) end
end)
local function mark()
  if last then
    emit({event = 'mark', pos = last})
    mp.osd_message('readq: marked ' .. mp.format_time(last))
  end
end
mp.add_forced_key_binding(opts.markkey, 'readq-mark', mark)
mp.register_script_message('readq-mark', mark)
local shots = 0
local function figure()
  if opts.shotdir == '' then return end
  local pos = mp.get_property_number('time-pos') or last
  shots = shots + 1
  local file = utils.join_path(opts.shotdir, string.format('fig-%d.png', shots))
  if pos and mp.commandv('screenshot-to-file', file, 'video') then
    emit({event = 'figure', pos = pos, file = file})
    mp.osd_message('readq: figure at ' .. mp.format_time(pos))
  else
    mp.osd_message('readq: no picture to take')
  end
end
mp.add_forced_key_binding(opts.figkey, 'readq-figure', figure)
mp.register_script_message('readq-figure', figure)
mp.register_event('end-file', function(e)
  emit({event = 'end', reason = e.reason, pos = last})
end)
"
  "The Lua script readq gives mpv.")

(defvar readq--media-session nil
  "The audio or video playing in mpv, as a plist, or nil.")

(defvar readq--mpv-last-command nil
  "The last command line readq ran mpv with (for troubleshooting).")

(defvar url-allow-non-local-files)

(defun readq--format-time (seconds)
  "Return SECONDS as \"m:ss\" or \"h:mm:ss\"."
  (if (null seconds)
      "?"
    (let* ((s (round seconds)) (h (/ s 3600)) (m (/ (% s 3600) 60)) (sec (% s 60)))
      (if (> h 0) (format "%d:%02d:%02d" h m sec) (format "%d:%02d" m sec)))))

(defun readq--media-p (item)
  "Return non-nil when ITEM is audio or video, or a section of one."
  (and (not (readq--extract-p item))
       (eq (readq--get (readq--item-book item) :format) 'media)))

(defun readq--media-kind (book)
  "Return \"online\", \"video\" or \"audio\" for the media BOOK."
  (cond ((readq--url-p (readq--get book :file)) "online")
        ((member (downcase (or (file-name-extension (readq--get book :file)) ""))
                 '("mp4" "m4v" "mkv" "webm" "mov" "avi"))
         "video")
        (t "audio")))

(defun readq--media-target (book)
  "Return what mpv plays for BOOK: its file name or URL."
  (let ((file (readq--get book :file)))
    (if (readq--url-p file) file (expand-file-name file))))

(defun readq--mpv-program ()
  "Return the mpv program to run."
  (let ((windows (memq system-type '(windows-nt ms-dos cygwin))))
    (or readq-mpv-program
        (let ((exe (executable-find "mpv")))
          (if (and exe windows)
              (let ((com (concat (file-name-sans-extension exe) ".com")))
                (if (file-exists-p com) com exe))
            exe))
        (and windows
             (cl-find-if #'file-exists-p
                         (delq nil
                               (list "C:/Program Files/mpv/mpv.com"
                                     "C:/Program Files/mpv/mpv.exe"
                                     (when-let ((home (getenv "USERPROFILE")))
                                       (expand-file-name "scoop/apps/mpv/current/mpv.com"
                                                         home))))))
        (user-error "Cannot find mpv; install it or set `readq-mpv-program'"))))

(defun readq--mpv-script-file ()
  "Return the file of readq's mpv script, writing it if needed."
  ;; An absolute name: mpv and Emacs may not agree on "~" (Windows).
  (let ((file (expand-file-name (locate-user-emacs-file "readq-mpv.lua"))))
    (unless (and (file-exists-p file)
                 (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                        readq--mpv-script))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert readq--mpv-script)))
    file))

(defun readq--mpv-ytdl-args ()
  "Return mpv's arguments for online videos."
  (append (and readq-mpv-ytdl-format
               (list (concat "--ytdl-format=" readq-mpv-ytdl-format)))
          (and readq-mpv-ytdl-path
               (list (concat "--script-opts-append=ytdl_hook-ytdl_path="
                             (expand-file-name readq-mpv-ytdl-path))))))

(defun readq--mpv-parse (line)
  "Return the event in an output LINE of readq's mpv script, or nil."
  ;; mpv's status line can come first on the same line.
  (when (string-match "READQ \\({.*}\\)" line)
    (require 'json)
    (let ((json-object-type 'plist)
          (json-array-type 'list)
          (json-key-type 'keyword)
          (json-false nil))
      (ignore-errors (json-read-from-string (match-string 1 line))))))

(defun readq--mpv-probe (target)
  "Ask mpv about TARGET, a file or URL.
Return a plist (:duration :title :chapters), or nil if mpv is missing
or cannot play it.  Online videos take a few seconds."
  (when-let ((program (ignore-errors (readq--mpv-program))))
    (let* ((buf (generate-new-buffer " *readq-mpv-probe*"))
           (proc (make-process
                  :name "readq-mpv-probe" :buffer buf :noquery t
                  :connection-type 'pipe :sentinel #'ignore
                  :command (append (list program "--no-config" "--really-quiet"
                                         "--vo=null" "--ao=null"
                                         (concat "--script=" (readq--mpv-script-file))
                                         "--script-opts-append=readq-probe=yes")
                                   (readq--mpv-ytdl-args)
                                   (list "--" (if (readq--url-p target) target
                                                (expand-file-name target))))))
           (deadline (+ (float-time) (if (readq--url-p target) 120 20))))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.1))
      (when (process-live-p proc) (delete-process proc))
      (prog1
          (with-current-buffer buf
            (goto-char (point-min))
            (let (event)
              (while (and (not event) (re-search-forward "READQ {.*}" nil t))
                (let ((ev (readq--mpv-parse (match-string 0))))
                  (when (equal (plist-get ev :event) "loaded") (setq event ev))))
              (when event
                (list :duration (plist-get event :duration)
                      :title (plist-get event :title)
                      :chapters (plist-get event :chapters)))))
        (kill-buffer buf)))))

(defun readq--media-outline (book)
  "Return the chapters of the media BOOK as plists (:title :depth :start :end).
They come from its table of contents with timestamps, if it has one
\(see `readq-set-media-toc'), or else from the chapters in the file."
  (if-let ((toc (readq--media-toc book)))
      (let ((duration (or (readq--get book :total)
                          (let ((d (plist-get (readq--mpv-probe (readq--media-target book))
                                              :duration)))
                            (when d (readq--put book :total (float d)))
                            d))))
        (message "Sections from %s" (car toc))
        (readq--media-toc-paths (readq--media-toc-ends (cdr toc) duration)))
    (readq--media-embedded-chapters book)))

(defun readq--media-embedded-chapters (book)
  "Return the chapters stored in the media BOOK's file.
They are plists as for `readq--media-outline'."
  (let* ((probe (or (readq--mpv-probe (readq--media-target book))
                    (user-error "mpv could not open \"%s\"" (readq--get book :title))))
         (duration (or (plist-get probe :duration) (readq--get book :total)))
         (chapters (plist-get probe :chapters)))
    (when (and duration (not (readq--get book :total)))
      (readq--put book :total duration))
    (cl-loop for (c . rest) on chapters
             for start = (float (plist-get c :time))
             for end = (float (if rest (plist-get (car rest) :time) (or duration start)))
             when (> end start)
             collect (list :title (or (plist-get c :title)
                                      (format "Chapter at %s" (readq--format-time start)))
                           :depth 1 :start start :end end))))

;;;;; Tables of contents for audio and video

;; A table of contents is text with one timestamp per section:
;;
;;   00:02:03 Section 1              * Section 1
;;   00:04:55 Section 2              00:01:04 Sub-section 1
;;                                   00:03:24 Sub-section 2
;;                                   * Section 2
;;                                   00:11:04 Sub-section 1
;;
;; Times are H:MM:SS, MM:SS or M:SS (with fractions, in brackets or not),
;; at the start or end of the line.  Org "*" or Markdown "#" headings
;; give levels; a heading without a time starts with its first timed line.

(defcustom readq-media-toc-names
  '("%s.toc" "%s.chapters" "%s.chapters.txt" "%s.txt" "%s.org" "%s.md")
  "Files next to an audio or video file that can be its table of contents.
In each, %s is the media file's name without extension.  The first that
has timestamps is used, unless one was chosen with `readq-set-media-toc'."
  :type '(repeat string))

(defconst readq--toc-time-re
  "\\(?:\\([0-9]+\\):\\)?\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\(?:[.,]\\([0-9]+\\)\\)?"
  "Regexp matching a timestamp; groups: hours, minutes, seconds, fraction.")

(defun readq--toc-seconds (string &optional offset)
  "Return the seconds of the timestamp matched by `readq--toc-time-re' in STRING.
Its groups come OFFSET groups after the start of the regexp matched (0
by default).  Return nil when it is not a valid time."
  (let* ((o (or offset 0))
         (hours (match-beginning (+ o 1)))
         (h (if hours (string-to-number (match-string (+ o 1) string)) 0))
         (m (string-to-number (match-string (+ o 2) string)))
         (s (string-to-number (match-string (+ o 3) string)))
         (frac (match-string (+ o 4) string)))
    (when (and (< s 60) (or (not hours) (< m 60)))
      (+ (* 3600 h) (* 60 m) s
         (if frac (/ (string-to-number frac) (expt 10.0 (length frac))) 0)))))

(defun readq--toc-split (text)
  "Split TEXT, one line of a table of contents, into (SECONDS . TITLE).
Return nil when it has no timestamp."
  (let ((case-fold-search nil)
        (marker "\\`[-–—•+*]?[ \t]*\\(?:[0-9]+[.)][ \t]+\\)?")
        ;; "]" first in a class is literal; Emacs classes have no escapes.
        (sep "[ \t]*[]–—:|.)-]?[ \t]*"))
    (cond
     ;; "00:01:04 Title", "- [1:04] Title", "1. 01:04 - Title"
     ((string-match (concat marker "[[(]?" readq--toc-time-re "[])]?" sep "\\(.*\\)\\'") text)
      (let ((seconds (readq--toc-seconds text))
            (title (string-trim (match-string 5 text))))
        (when seconds (cons (float seconds) title))))
     ;; "Title - 1:04", "Title (01:04)"
     ((string-match (concat "\\`\\(.*?\\)[ \t]*[-–—|]?[ \t]*[[(]?" readq--toc-time-re
                            "[])]?[ \t]*\\'")
                    text)
      (let ((seconds (readq--toc-seconds text 1))
            (title (string-trim (match-string 1 text))))
        (when (and seconds (not (string-empty-p title)))
          (cons (float seconds) title)))))))

(defun readq--parse-media-toc (text)
  "Parse the table of contents TEXT into plists (:title :depth :start).
Entries are in the order of TEXT; see `readq-media-toc-names' for the
format.  Untimed headings start with their first timed line."
  (let ((level 0) pending entries)
    (dolist (line (split-string text "\n"))
      (let* ((line (string-trim-right line))
             (heading (and (string-match "\\`\\(\\*+\\|#+\\)[ \t]+\\(.*\\)" line)
                           (cons (length (match-string 1 line))
                                 (string-trim (match-string 2 line)))))
             (timed (readq--toc-split (if heading (cdr heading) (string-trim line)))))
        (cond
         (heading
          (setq level (car heading)
                ;; Untimed headings at this level or deeper had no time.
                pending (cl-remove-if (lambda (p) (>= (car p) level)) pending))
          (if timed
              (progn
                (dolist (p pending)
                  (push (list :title (cdr p) :depth (car p) :start (car timed)) entries))
                (setq pending nil)
                (push (list :title (readq--toc-title timed) :depth level
                            :start (car timed))
                      entries))
            (setq pending (append pending (list heading)))))
         (timed
          (dolist (p pending)
            (push (list :title (cdr p) :depth (car p) :start (car timed)) entries))
          (setq pending nil)
          (push (list :title (readq--toc-title timed) :depth (1+ level) :start (car timed))
                entries)))))
    (nreverse entries)))

(defun readq--toc-title (timed)
  "Return the title of the TIMED entry (SECONDS . TITLE)."
  (if (string-empty-p (cdr timed))
      (format "Chapter at %s" (readq--format-time (car timed)))
    (cdr timed)))

(defun readq--media-toc-ends (entries duration)
  "Fill in :end for ENTRIES: the next start at their depth or above, or DURATION."
  (let ((tail entries))
    (while tail
      (let* ((e (car tail))
             (next (cl-find-if (lambda (n) (and (<= (plist-get n :depth) (plist-get e :depth))
                                                (> (plist-get n :start) (plist-get e :start))))
                               (cdr tail))))
        (plist-put e :end (cond (next (plist-get next :start))
                                (duration (max (plist-get e :start) (float duration))))))
      (setq tail (cdr tail)))
    (cl-remove-if (lambda (e) (and (plist-get e :end) (<= (plist-get e :end) (plist-get e :start))))
                  entries)))

(defun readq--media-toc-paths (entries)
  "Give the sub-sections in ENTRIES a :path naming their parents too.
Sub-sections are often called alike (\"Part 1\" in every chapter), so
the queue shows \"Section 1 › Part 1\"."
  (let (parents)
    (dolist (e entries entries)
      (let ((depth (plist-get e :depth)))
        (setq parents (cl-remove-if (lambda (p) (>= (car p) depth)) parents))
        (when parents
          (plist-put e :path (mapconcat #'identity
                                        (append (reverse (mapcar #'cdr parents))
                                                (list (plist-get e :title)))
                                        " › ")))
        (push (cons depth (plist-get e :title)) parents)))))

(defun readq--media-toc-file (book)
  "Return the table of contents file of the media BOOK, or nil.
That is the one chosen with `readq-set-media-toc', or else the first of
`readq-media-toc-names' next to it that has timestamps."
  (let ((chosen (readq--get book :toc-file))
        (file (readq--get book :file)))
    (cond
     (chosen (and (file-readable-p chosen) chosen))
     ((readq--url-p file) nil)
     (t (let ((base (file-name-sans-extension (expand-file-name file))))
          (cl-find-if (lambda (f)
                        (and (file-readable-p f)
                             (not (readq--same-file-p (readq--normalize-file f)
                                                      (readq--get book :file)))
                             (not (readq--own-file-p f))
                             (readq--parse-media-toc (readq--file-text f))))
                      (mapcar (lambda (pattern) (format pattern base))
                              readq-media-toc-names)))))))

(defun readq--file-text (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun readq--media-toc (book)
  "Return the table of contents of the media BOOK as (SOURCE . ENTRIES), or nil.
SOURCE describes where it comes from."
  (let ((text (readq--get book :toc-text))
        (file (unless (readq--get book :toc-text) (readq--media-toc-file book))))
    (when-let ((entries (cond (text (readq--parse-media-toc text))
                              (file (readq--parse-media-toc (readq--file-text file))))))
      (cons (if text "the text you gave" (abbreviate-file-name file)) entries))))

(defun readq-set-media-toc (book &optional file clear)
  "Give the audio or video BOOK a table of contents with timestamps.
FILE holds it; when the region is active, its text is used instead
\(paste the chapter list of a YouTube description in any buffer and
select it).  With a prefix argument (CLEAR), forget the chosen one, so
that a file next to BOOK or its embedded chapters are used again."
  (interactive
   (let ((b (readq--item-book (readq--target-book "Table of contents of: "))))
     (unless (eq (readq--get b :format) 'media)
       (user-error "Only audio and video take a table of contents with timestamps"))
     (list b
           (unless (or current-prefix-arg (use-region-p))
             (read-file-name "Table of contents file: " nil nil t
                             (let ((f (readq--media-toc-file b)))
                               (and f (file-name-nondirectory f)))))
           current-prefix-arg)))
  (cond
   (clear
    (readq--put book :toc-file nil :toc-text nil)
    (readq--changed book "\"%s\" uses %s" (readq--get book :title)
                    (if (readq--media-toc book) "the table of contents next to it"
                      "its own chapters")))
   (t
    (let* ((text (if (and (not file) (use-region-p))
                     (buffer-substring-no-properties (region-beginning) (region-end))
                   (readq--file-text file)))
           (entries (readq--parse-media-toc text)))
      (unless entries (user-error "No timestamps found (like 00:02:03 Section 1)"))
      (if file
          (readq--put book :toc-file (abbreviate-file-name (expand-file-name file))
                      :toc-text nil)
        (readq--put book :toc-text text :toc-file nil))
      (when (use-region-p) (deactivate-mark))
      (readq--changed book "\"%s\": table of contents with %d entr%s; choose sections with %s"
                      (readq--get book :title) (length entries)
                      (if (= (length entries) 1) "y" "ies")
                      (substitute-command-keys "\\[readq-add-sections]"))))))

;;;;; Playing

(defun readq--media-playing-p ()
  "Return non-nil when readq is playing something in mpv."
  (and readq--media-session t))

(defun readq--media-resume (item)
  "Return where to start playing ITEM, in seconds."
  (let* ((section (readq--section-p item))
         (start (if section (readq--get item :start) 0))
         (time (readq--get item :time)))
    (if (or (null time)
            (eq (readq--get item :status) 'finished)
            (readq--at-end-p item)
            (and section (or (< time start)
                              (and (readq--get item :end)
                                   (>= time (readq--get item :end))))))
        start
      time)))

(defun readq--open-media (item &optional start peek)
  "Play ITEM (audio, video, or a section of one) in mpv.
Start at START seconds, by default where you left it.  With PEEK, only
look something up: your place in ITEM is not changed.  Return t."
  (let* ((book (readq--item-book item))
         (section (and (readq--section-p item) (not peek)))
         (program (readq--mpv-program)))
    (when (readq--missing-p book)
      (user-error "Missing file: %s" (readq--get book :file)))
    (when (readq--media-playing-p) (readq--media-stop))
    (let* ((from (or start (readq--media-resume item)))
           (wl (make-temp-file "readq-mpv" t))
           (shots (make-temp-file "readq-shots" t))
           (args (append
                  (list "--quiet"         ; no status line on the output
                        (concat "--script=" (readq--mpv-script-file))
                        (format "--script-opts-append=readq-interval=%s" readq-mpv-interval)
                        (format "--script-opts-append=readq-markkey=%s" readq-mpv-mark-key)
                        (format "--script-opts-append=readq-figkey=%s" readq-mpv-figure-key)
                        ;; mpv takes forward slashes on Windows too.
                        (concat "--script-opts-append=readq-shotdir="
                                (replace-regexp-in-string "\\\\" "/" shots))
                        (format "--start=%.3f" from)
                        "--save-position-on-quit" "--resume-playback=no"
                        (concat "--watch-later-dir=" wl))
                  (and section (readq--get item :end)
                       (list (format "--end=%.3f" (readq--get item :end))))
                  (readq--mpv-ytdl-args)
                  readq-mpv-args
                  (list "--" (readq--media-target book))))
           (proc (make-process :name "readq-mpv"
                               :buffer (get-buffer-create " *readq-mpv*")
                               :command (cons program args)
                               :connection-type 'pipe
                               :noquery t
                               :filter #'readq--mpv-filter
                               :sentinel #'readq--mpv-sentinel)))
      (setq readq--mpv-last-command (cons program args)
            readq--media-session
            (list :id (readq--get item :id) :process proc :started (float-time)
                  :from from :time nil :duration nil :reason nil :marks nil
                  :peek peek :wl wl :shots shots :figures nil :partial ""))
      (message "Playing \"%s\" from %s in mpv.  %s marks a moment, %s takes a figure; close mpv when done."
               (readq--get item :title) (readq--format-time from) readq-mpv-mark-key
               readq-mpv-figure-key)
      t)))

(defun readq--mpv-filter (proc string)
  "Read the reports of readq's mpv script from PROC's output STRING."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)))
  (let ((session readq--media-session))
    (when (and session (eq (plist-get session :process) proc))
      (let ((text (concat (plist-get session :partial) string)))
        ;; mpv redraws its status line with carriage returns.
        (while (string-match "[\r\n]" text)
          (let ((ev (readq--mpv-parse (substring text 0 (match-beginning 0)))))
            (setq text (substring text (match-end 0)))
            (pcase (plist-get ev :event)
              ((or "loaded" "duration")
               (when (plist-get ev :duration)
                 (plist-put session :duration (plist-get ev :duration))))
              ("pos" (plist-put session :time (plist-get ev :pos)))
              ("mark" (plist-put session :marks
                                 (cons (plist-get ev :pos) (plist-get session :marks))))
              ("figure" (plist-put session :figures
                                   (cons (cons (plist-get ev :pos) (plist-get ev :file))
                                         (plist-get session :figures))))
              ("end" (plist-put session :reason (plist-get ev :reason))
               (when (plist-get ev :pos) (plist-put session :time (plist-get ev :pos)))))))
        (plist-put session :partial text)))))

(defun readq--mpv-sentinel (proc _event)
  "Save the session when the mpv PROC ends."
  (when (and (not (process-live-p proc))
             readq--media-session
             (eq (plist-get readq--media-session :process) proc))
    (readq--media-finish readq--media-session (process-exit-status proc))))

(defun readq--watch-later-time (dir)
  "Return the position mpv saved on quitting in DIR, or nil."
  (when (and dir (file-directory-p dir))
    (cl-some (lambda (f)
               (with-temp-buffer
                 (insert-file-contents f)
                 (goto-char (point-min))
                 (when (re-search-forward "^start=\\([0-9.]+\\)" nil t)
                   (string-to-number (match-string 1)))))
             (directory-files dir t "\\`[^.]"))))

(defun readq--media-progress (item time duration)
  "Return the progress of ITEM at TIME seconds, DURATION being the length."
  (if (readq--section-p item)
      (readq--section-progress item (list :time time))
    (and duration (> duration 0) (max 0.0 (min 1.0 (/ time (float duration)))))))

(defun readq--media-finish (session &optional exit)
  "Save the media SESSION that ended; EXIT is mpv's exit status.
Return the item that was played."
  (setq readq--media-session nil)
  (let* ((item (readq--book-by-id (plist-get session :id)))
         (book (and item (readq--item-book item)))
         (reason (plist-get session :reason))
         (saved (readq--watch-later-time (plist-get session :wl)))
         ;; Without the script's reports, mpv saved no position if it
         ;; played to the end.
         (eof (or (equal reason "eof")
                  (and (null reason) (null saved) (eql exit 0)
                       (null (plist-get session :time)))))
         (time (if reason (plist-get session :time) (or saved (plist-get session :time))))
         (peek (plist-get session :peek))
         (secs (min (round (- (float-time) (plist-get session :started)))
                    (* 60 readq-external-max-session-minutes))))
    (ignore-errors (delete-directory (plist-get session :wl) t))
    (when item
      ;; Streams may first underestimate their duration: keep the largest
      ;; known, and at least the position reached at the end.
      (let* ((duration (let ((known (delq nil (list (plist-get session :duration)
                                                    (readq--get book :total)
                                                    (and eof (plist-get session :time))))))
                         (and known (apply #'max known))))
             (end (if (readq--section-p item) (or (readq--get item :end) duration) duration)))
        (when duration (readq--put book :total (float duration)))
        ;; The last section of a table of contents ends with the file.
        (when (and end (readq--section-p item) (not (readq--get item :end)))
          (readq--put item :end (float end)))
        (unless peek
          (let ((from-time (readq--get item :time))
                (from (or (readq--get item :progress) 0))
                (time (if (and eof end) end time)))
            (when time
              (readq--put item :time time)
              (when-let ((progress (readq--media-progress item time duration)))
                (readq--put item :progress progress)))
            (readq--add-seconds item secs)
            (when (or eof (>= secs readq-min-session-seconds)
                      (and time (or (null from-time) (> (abs (- time from-time)) 1))))
              (readq--count-session item nil from secs))
            (when (and eof readq-media-finish-at-end)
              (readq--put item :status 'finished))))
        ;; Each marked moment becomes an extract.
        (let ((priority (min 100 (max 0 (+ (readq--get item :priority)
                                           readq-extract-priority-offset))))
              (tags (and (readq--section-p item) (readq--get item :tags))))
          (dolist (mark (reverse (plist-get session :marks)))
            (readq--create-extract book "" :page mark :point mark
                                   :priority priority :tags tags))
          ;; And each frame taken, a figure extract.
          (dolist (fig (reverse (plist-get session :figures)))
            (when (file-exists-p (cdr fig))
              (readq--create-figure book (list :file (cdr fig)) :page (car fig)
                                    :point (car fig) :priority priority :tags tags
                                    :time (file-attribute-modification-time
                                           (file-attributes (cdr fig)))))))
        (readq--save)
        (readq--refresh-dashboard)
        (message "%s \"%s\"%s%s"
                 (if peek "Played" "Saved")
                 (readq--get item :title)
                 (cond (peek "")
                       ((eq (readq--get item :status) 'finished) " — finished")
                       (t (format " at %s, comes back %s"
                                  (readq--format-time (readq--get item :time))
                                  (readq--get item :due))))
                 (concat
                  (let ((n (length (plist-get session :marks))))
                    (if (> n 0) (format "; %d mark%s became extracts" n (if (= n 1) "" "s"))
                      ""))
                  (let ((n (length (plist-get session :figures))))
                    (if (> n 0) (format "; %d figure extract%s" n (if (= n 1) "" "s"))
                      ""))))))
    (when-let ((shots (plist-get session :shots)))
      (ignore-errors (delete-directory shots t)))
    item))

(defun readq--media-stop ()
  "Close mpv and save the session.  Return the item that was playing."
  (let* ((session readq--media-session)
         (proc (plist-get session :process))
         (id (plist-get session :id)))
    (when (process-live-p proc)
      ;; mpv saves its state on SIGTERM; Windows has no signals.
      (if (memq system-type '(windows-nt ms-dos))
          (delete-process proc)
        (signal-process proc 'SIGTERM))
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (when (process-live-p proc) (delete-process proc)))
    (when (eq readq--media-session session)
      (readq--media-finish session (and proc (process-exit-status proc))))
    (readq--book-by-id id)))

(defun readq-media-mark ()
  "Mark the moment playing in mpv, as `readq-mpv-mark-key' does in mpv.
The moment is the last one mpv reported, at most `readq-mpv-interval'
seconds ago."
  (interactive)
  (let ((session readq--media-session))
    (unless session (user-error "Nothing is playing in mpv"))
    (let ((time (plist-get session :time)))
      (unless time (user-error "mpv has not reported a position yet"))
      (plist-put session :marks (cons time (plist-get session :marks)))
      (message "Marked %s" (readq--format-time time)))))

;;;###autoload
(defun readq-add-url (url priority &optional title tags)
  "Add the online video or audio at URL (YouTube...) with PRIORITY.
TITLE defaults to the one mpv finds; TAGS is a list of tags.  mpv
plays it through yt-dlp, which must be installed."
  (interactive
   (let* ((default (or (thing-at-point 'url t)
                       (let ((kill (ignore-errors (current-kill 0 t))))
                         (and kill (readq--url-p (string-trim kill)) (string-trim kill)))))
          (url (string-trim (read-string (format-prompt "URL" default) nil nil default))))
     (unless (readq--url-p url) (user-error "Not a URL: %s" url))
     (when (readq--book-by-file url) (user-error "Already in your queue: %s" url))
     (message "Asking mpv about %s..." url)
     (let ((probe (readq--mpv-probe url)))
       (setq readq--known-probe (cons url probe))
       (list url (readq--read-priority)
             (read-string "Title: " (or (plist-get probe :title) url))
             (and readq-ask-tags (readq--read-tags "Tags (optional): "))))))
  (unless (readq--url-p url) (user-error "Not a URL: %s" url))
  (prog1 (readq-add-book url priority (or title url) tags)
    (setq readq--known-probe nil)))

;;;; Daily workload

;; A budget for each day, in minutes and/or items.  Due items fill
;; today's budget most important first; the rest is either spread over
;; the next days (like SuperMemo's "Mercy") or held back until there
;; is room.  The time each item will take is estimated from its own
;; recent sessions.

(defgroup readq-workload nil
  "A daily limit on how much readq asks you to read."
  :group 'readq)

(defcustom readq-daily-minutes 90
  "Minutes of reading readq plans for each day, or nil for no limit.
Time already spent today counts, and each due item is assumed to take
as long as its recent sessions, see `readq--estimate-minutes'."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Minutes")))

(defcustom readq-daily-items nil
  "Number of items (books, sections, extracts) to read each day, or nil.
Can be used together with `readq-daily-minutes'; the stricter one wins."
  :type '(choice (const :tag "No limit" nil) (integer :tag "Items")))

(defcustom readq-workload-protected-priority 10
  "Items with a priority at or below this are always kept for today.
They are never moved by the budget, even when it is used up.  Set it to
-1 to protect nothing."
  :type 'integer)

(defcustom readq-workload-overflow 'spread
  "What happens to due items that do not fit in today's budget.
`spread': they are given new due dates over the next days, the least
important ones furthest away, filling each day up to its budget.  This
happens once a day, the first time readq looks at the queue.
`hold': their due dates stay; they wait until there is room, most
important first."
  :type '(choice (const :tag "Spread over the next days" spread)
                 (const :tag "Hold back until there is room" hold)))

(defcustom readq-workload-stop 'ask
  "What `readq-next' does once today's budget is used up.
`ask': say so and ask whether to keep reading.  nil: keep going (the
dashboard still shows the budget)."
  :type '(choice (const :tag "Ask whether to keep reading" ask)
                 (const :tag "Keep going" nil)))

(defcustom readq-default-book-minutes 15
  "Estimated minutes for a session of a book you have not read yet.
Also used for sections, audio and video."
  :type 'number)

(defcustom readq-default-extract-minutes 2
  "Estimated minutes to review an extract you have not reviewed yet."
  :type 'number)

(defcustom readq-workload-estimate-sessions 5
  "How many recent sessions of an item its time estimate is based on."
  :type 'integer)

(defcustom readq-workload-spread-days 30
  "How many days ahead items over the budget may be moved."
  :type 'integer)

(defcustom readq-workload-forecast-days 14
  "How many days `readq-workload' shows."
  :type 'integer)

(defface readq-over-budget-face '((t :inherit warning))
  "Face for days and items over the daily budget.")

(defvar readq-deadline-overrides-budget)

(defvar readq--budget-override nil
  "The date on which you chose to keep reading past the budget.")

(defun readq--budget-active-p ()
  "Return non-nil when a daily budget is set."
  (or readq-daily-minutes readq-daily-items))

(defun readq--log-reading (secs items &optional now)
  "Add SECS seconds and ITEMS items to the log of NOW's date."
  (when (or (> secs 0) (> items 0))
    (let* ((today (readq--today now))
           (entry (assoc today readq--log)))
      (unless entry
        (setq entry (list today :seconds 0 :items 0))
        ;; Keep two months of days.
        (setq readq--log (cons entry (seq-take readq--log 60))))
      (plist-put (cdr entry) :seconds (+ (plist-get (cdr entry) :seconds) secs))
      (plist-put (cdr entry) :items (+ (plist-get (cdr entry) :items) items))
      (setq readq--dirty t))))

(defun readq--done-today (&optional now)
  "Return (MINUTES . ITEMS) read on NOW's date."
  (readq--books)                        ; Load the log.
  (let ((entry (cdr (assoc (readq--today now) readq--log))))
    (cons (/ (or (plist-get entry :seconds) 0) 60.0)
          (or (plist-get entry :items) 0))))

(defun readq--estimate-minutes (item)
  "Return the minutes a session of ITEM is expected to take.
This is the median of its last `readq-workload-estimate-sessions'
timed sessions, or `readq-default-book-minutes' or
`readq-default-extract-minutes' when it has none."
  (let ((secs (seq-take
               (delq nil (mapcar (lambda (h) (let ((s (plist-get h :seconds)))
                                               (and s (> s 0) s)))
                                 (readq--get item :history)))
               readq-workload-estimate-sessions)))
    (if (null secs)
        (float (if (readq--extract-p item)
                   readq-default-extract-minutes
                 readq-default-book-minutes))
      (let* ((sorted (sort (copy-sequence secs) #'<))
             (n (length sorted))
             (median (if (cl-oddp n)
                         (nth (/ n 2) sorted)
                       (/ (+ (nth (1- (/ n 2)) sorted) (nth (/ n 2) sorted)) 2.0))))
        (/ median 60.0)))))

(defun readq--protected-p (item)
  "Return non-nil when ITEM is kept for today whatever the budget.
That is an important item (`readq-workload-protected-priority'), or
one with a deadline when `readq-deadline-overrides-budget' is set."
  (or (<= (readq--get item :priority) readq-workload-protected-priority)
      (and readq-deadline-overrides-budget
           (readq--deadline-needed-p item))))

(defun readq--fits-p (minutes items)
  "Return non-nil when a budget with MINUTES and ITEMS left has room."
  (and (or (null readq-daily-minutes) (> minutes 0))
       (or (null readq-daily-items) (> items 0))))

(defun readq--workload-plan (&optional now)
  "Split the items due on NOW's date by today's budget.
Return (KEEP . OVERFLOW), each in queue order: KEEP is what fits in
what is left of today's budget (and protected items), OVERFLOW the
rest.  The focus does not matter: the budget is for all your reading."
  (let* ((done (readq--done-today now))
         (minutes (- (or readq-daily-minutes 0) (car done)))
         (items (- (or readq-daily-items 0) (cdr done)))
         keep overflow)
    (dolist (it (let ((due (cl-remove-if-not (lambda (b) (readq--due-p b now))
                                             (readq--queue nil now))))
                  ;; Items with a deadline go first.
                  (append (cl-remove-if-not #'readq--deadline-needed-p due)
                          (cl-remove-if #'readq--deadline-needed-p due))))
      (if (or (not (readq--budget-active-p))
              (readq--protected-p it)
              (readq--fits-p minutes items))
          (progn (push it keep)
                 (setq minutes (- minutes (readq--estimate-minutes it))
                       items (1- items)))
        (push it overflow)))
    (cons (nreverse keep) (nreverse overflow))))

(defun readq--budget-left (&optional now)
  "Return (MINUTES . ITEMS) left in today's budget; nil parts have no limit."
  (let ((done (readq--done-today now)))
    (cons (and readq-daily-minutes (- readq-daily-minutes (car done)))
          (and readq-daily-items (- readq-daily-items (cdr done))))))

(defun readq--budget-used-up-p (&optional now)
  "Return non-nil when today's budget is used up."
  (and (readq--budget-active-p)
       (let ((left (readq--budget-left now)))
         (not (readq--fits-p (or (car left) 1) (or (cdr left) 1))))))

(defun readq--day-loads (days &optional now)
  "Return a vector of (MINUTES . ITEMS) due on each of the next DAYS days.
Index 0 is tomorrow.  Only active items count."
  (let ((loads (make-vector days nil)))
    (dotimes (i days) (aset loads i (cons 0.0 0)))
    (dolist (b (readq--books))
      (when (and (readq--active-p b) (readq--get b :due)
                 (or readq-queue-extracts (not (readq--extract-p b)))
                 (not (readq--missing-p b)))
        (let ((d (1- (readq--days-until (readq--get b :due) now))))
          (when (and (>= d 0) (< d days))
            (let ((cell (aref loads d)))
              (setcar cell (+ (car cell) (readq--estimate-minutes b)))
              (setcdr cell (1+ (cdr cell))))))))
    loads))

(defun readq-spread-overflow (&optional now)
  "Move due items that do not fit in today's budget to the next days.
The most important ones get the earliest days, each day filled up to its
budget (`readq-daily-minutes', `readq-daily-items').  Items with a
priority at or below `readq-workload-protected-priority' are never
moved.  Return the number of items moved.

This runs by itself once a day when `readq-workload-overflow' is
`spread'; call it to do it again."
  (interactive)
  (let* ((overflow (cdr (readq--workload-plan now)))
         (days readq-workload-spread-days)
         (loads (readq--day-loads days now))
         (moved 0))
    (dolist (it overflow)
      (let* ((est (readq--estimate-minutes it))
             (day (or (cl-position-if
                       (lambda (load)
                         (readq--fits-p (- (or readq-daily-minutes 0) (car load))
                                        (- (or readq-daily-items 0) (cdr load))))
                       loads)
                      ;; Every day is full: the least loaded one.
                      (let ((best 0))
                        (dotimes (i days)
                          (when (< (car (aref loads i)) (car (aref loads best)))
                            (setq best i)))
                        best)))
             (cell (aref loads day)))
        (setcar cell (+ (car cell) est))
        (setcdr cell (1+ (cdr cell)))
        (readq--put it :due (readq--date-in (1+ day) now))
        (cl-incf moved)))
    (setq readq--spread-date (readq--today now)
          readq--dirty t)
    (when (> moved 0)
      (readq--save)
      (readq--refresh-dashboard))
    (when (called-interactively-p 'any)
      (message "Moved %d item%s that did not fit in today's budget"
               moved (if (= moved 1) "" "s")))
    moved))

(defun readq--workload-auto-spread ()
  "Spread today's overflow once a day, when so configured."
  (when (and (eq readq-workload-overflow 'spread)
             (readq--budget-active-p)
             (not (equal readq--spread-date (readq--today))))
    (let ((moved (readq-spread-overflow)))
      (when (> moved 0)
        (message "readq: %d item%s over today's budget moved to later days (%s shows them)"
                 moved (if (= moved 1) "" "s")
                 (substitute-command-keys "\\[readq-workload]"))))))

(add-hook 'readq-before-suggest-hook #'readq--workload-auto-spread)

(defun readq--budget-string (&optional now)
  "Return a short description of today's budget, e.g. \"52/90 min\"."
  (let ((done (readq--done-today now)))
    (string-join
     (delq nil (list (and readq-daily-minutes
                          (format "%d/%d min" (round (car done)) readq-daily-minutes))
                     (and readq-daily-items
                          (format "%d/%d items" (cdr done) readq-daily-items))))
     ", ")))

(defun readq--budget-allows-p (item)
  "Return non-nil when `readq-next' may open ITEM without asking.
Ask when today's budget is used up, unless ITEM is protected or you
already chose to keep reading today."
  (or (not (eq readq-workload-stop 'ask))
      (not (readq--due-p item))
      (readq--protected-p item)
      (equal readq--budget-override (readq--today))
      (not (readq--budget-used-up-p))
      (when (y-or-n-p (format "Today's reading budget is used up (%s).  Keep reading? "
                              (readq--budget-string)))
        (setq readq--budget-override (readq--today))
        t)))

;;;;; The forecast

(defun readq--bar (fraction width)
  "Return a bar WIDTH characters wide, FRACTION full (may exceed 1)."
  (let ((n (min width (max 0 (round (* (min fraction 1.0) width))))))
    (concat (make-string n (car readq-progress-bar-chars))
            (make-string (- width n) (cdr readq-progress-bar-chars)))))

(defun readq--workload-lines (&optional now)
  "Return the lines of the workload forecast for NOW."
  (let* ((days readq-workload-forecast-days)
         (loads (readq--day-loads days now))
         (done (readq--done-today now))
         (plan (readq--workload-plan now))
         (left (apply #'+ 0.0 (mapcar #'readq--estimate-minutes (car plan))))
         (budget readq-daily-minutes)
         (fmt (lambda (date minutes items note)
                (let* ((over (or (and budget (> minutes (+ budget 0.5)))
                                 (and readq-daily-items (> items readq-daily-items))))
                       (line (format "%-14s %4d min %4d item%s  %s%s"
                                     date (round minutes) items (if (= items 1) " " "s")
                                     (if budget (readq--bar (/ minutes (float budget)) 20) "")
                                     note)))
                  (if over (propertize line 'face 'readq-over-budget-face) line)))))
    (append
     (list (format "Budget: %s per day.  Over budget: %s.\n"
                   (or (string-join
                        (delq nil (list (and readq-daily-minutes
                                             (format "%d min" readq-daily-minutes))
                                        (and readq-daily-items
                                             (format "%d items" readq-daily-items))))
                        ", ")
                       "")
                   (if (eq readq-workload-overflow 'spread)
                       "spread over the next days" "held back")))
     (readq--deadline-lines now)
     (list
      (funcall fmt (format-time-string "Today %a %d" now)
                    (+ (car done) left) (+ (cdr done) (length (car plan)))
                    (format "  %d min read%s" (round (car done))
                            (if (cdr plan)
                                (format ", %d more due but over budget" (length (cdr plan)))
                              ""))))
     (let (lines)
       (dotimes (i days)
         (let ((load (aref loads i)))
           (push (funcall fmt (format-time-string
                               "%a %d %b" (time-add (readq--today-noon now)
                                                    (* 86400 (1+ i))))
                          (car load) (cdr load) "")
                 lines)))
       (nreverse lines)))))

(defvar readq-workload-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map "g" #'readq-workload)
    (define-key map "S" #'readq-spread-overflow)
    map)
  "Keymap for `readq-workload-mode'.")

(define-derived-mode readq-workload-mode special-mode "readq workload"
  "Major mode showing how much reading is planned for the next days.
\\{readq-workload-mode-map}")

;;;###autoload
(defun readq-workload ()
  "Show today's budget and the reading due over the next days."
  (interactive)
  (let ((buf (get-buffer-create "*readq workload*")))
    (with-current-buffer buf
      (readq-workload-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'identity (readq--workload-lines) "\n") "\n")
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Deadlines

;; A deadline is a date by which a book, section or recording, or
;; everything with a tag, should be finished: "#cardio by 1 December".
;; The last day of reading is the day before the deadline.  readq works
;; out what is left (pages, minutes, or a percentage), the pace needed
;; per day, and whether you are behind; it brings the items back often
;; enough to finish, and keeps them over the daily budget.  Extracts
;; have no deadlines: you are never done with them.

(defgroup readq-deadlines nil
  "Finishing books and tags by a date."
  :group 'readq)

(defcustom readq-deadline-overrides-budget t
  "When non-nil, due items with a deadline are kept over the daily budget.
They are never spread to later days.  When nil, they go first within
the budget but can be spread like other items."
  :type 'boolean)

(defcustom readq-deadline-pace-sessions 5
  "How many recent sessions an item's pace (progress per session) is based on."
  :type 'integer)

(defcustom readq-deadline-width 18
  "Width of the dashboard's Deadline column."
  :type 'integer)

(defun readq--deadline-candidate-p (item)
  "Return non-nil when ITEM can have a deadline: not an extract."
  (not (readq--extract-p item)))

(defun readq--has-active-sections-p (book)
  "Return non-nil when BOOK's reading is done through its active sections."
  (and (readq--book-p book)
       (cl-some #'readq--active-p (readq--sections-of book))))

(defun readq--effective-deadline (item)
  "Return (DATE . SOURCE) of the deadline that applies to ITEM, or nil.
SOURCE is nil for ITEM's own deadline, or the tag.  The earliest wins."
  (when (readq--deadline-candidate-p item)
    (let ((best (and (readq--get item :deadline) (cons (readq--get item :deadline) nil)))
          (tags (readq--item-tags item)))
      (pcase-dolist (`(,tag . ,date) readq--tag-deadlines)
        (when (and (member tag tags)
                   (not (readq--has-active-sections-p item))
                   (or (null best) (string< date (car best))))
          (setq best (cons date tag))))
      best)))

(defun readq--item-size (item)
  "Return (SIZE . UNIT) for the whole of ITEM: pages, minutes or percent."
  (let ((book (readq--item-book item)))
    (pcase (readq--get book :format)
      ('pdf (if (readq--section-p item)
                (cons (float (1+ (- (readq--get item :end) (readq--get item :start)))) "p")
              (if-let ((total (readq--get item :total)))
                  (cons (float total) "p")
                (cons 100.0 "%"))))
      ('media (let ((secs (if (readq--section-p item)
                              (and (readq--get item :end)
                                   (- (readq--get item :end) (readq--get item :start)))
                            (readq--get item :total))))
                (if secs (cons (/ secs 60.0) "min") (cons 100.0 "%"))))
      (_ (cons 100.0 "%")))))

(defun readq--amount-string (amount unit)
  "Return AMOUNT of UNIT as a short string, e.g. \"14 p\" or \"8%\"."
  (let ((n (if (< amount 10) (/ (fround (* amount 10)) 10) (fround amount))))
    (format (if (equal unit "%") "%s%s" "%s %s")
            (if (= n (ftruncate n)) (format "%d" n) (format "%.1f" n))
            unit)))

(defun readq--session-pace (item)
  "Return ITEM's median progress per session, or nil if unknown."
  (let ((steps (seq-take
                (delq nil (mapcar (lambda (h)
                                    (let ((from (plist-get h :from)) (to (plist-get h :to)))
                                      (and from to (> to from) (- to from))))
                                  (readq--get item :history)))
                readq-deadline-pace-sessions)))
    (when steps
      (let* ((sorted (sort (copy-sequence steps) #'<))
             (n (length sorted)))
        (if (cl-oddp n)
            (nth (/ n 2) sorted)
          (/ (+ (nth (1- (/ n 2)) sorted) (nth (/ n 2) sorted)) 2.0))))))

(defun readq--deadline-info (item &optional now)
  "Return a plist describing ITEM's deadline on NOW's date, or nil.
Keys: :date, :tag (nil for ITEM's own), :days (reading days left, the
deadline day itself not counted), :left (fraction left), :size and
:unit (see `readq--item-size'), :remaining (in units), :per-day
\(units per day), :behind (units behind an even pace since the deadline
applied, or 0), :missed (non-nil when the deadline passed unfinished)
and :done (non-nil when finished)."
  (when-let ((dl (readq--effective-deadline item)))
    (let* ((date (car dl))
           (today (readq--today now))
           (progress (min 1.0 (or (readq--get item :progress) 0.0)))
           (done (or (eq (readq--get item :status) 'finished)
                     (readq--at-end-p item)))
           (left (if done 0.0 (- 1.0 progress)))
           (size (readq--item-size item))
           (days (max 0 (readq--days-until date now)))
           (start (readq--get item :deadline-start)))
      ;; Remember where the item stood when this deadline started to
      ;; apply, to tell an even pace from falling behind.
      (unless (equal (car start) date)
        (setq start (list date today progress))
        (readq--put item :deadline-start start))
      (pcase-let* ((`(,_ ,d0 ,p0) start)
                   (span (max 1 (readq--days-until date (readq--date-noon d0))))
                   (elapsed (min span (max 0 (readq--days-until today (readq--date-noon d0)))))
                   (expected (+ p0 (* (- 1.0 p0) (/ (float elapsed) span))))
                   (behind (if done 0.0 (max 0.0 (* (- expected progress) (car size))))))
        (list :date date :tag (cdr dl) :days days :left left
              :size (car size) :unit (cdr size)
              :remaining (* left (car size))
              :per-day (if (> days 0) (/ (* left (car size)) days) (* left (car size)))
              :behind (if (< behind 0.5) 0.0 behind)
              :missed (and (not done) (= days 0))
              :done done)))))

(defun readq--deadline-cap (item &optional now)
  "Return the most days ITEM may wait before its next session, or nil.
Based on its deadline, what is left and its pace per session; nil when
no deadline applies or nothing is left."
  (when-let ((info (readq--deadline-info item now)))
    (unless (plist-get info :done)
      (let ((days (plist-get info :days))
            (pace (readq--session-pace item)))
        (if (or (<= days 1) (null pace))
            1
          (let ((sessions (max 1 (ceiling (/ (plist-get info :left) pace)))))
            (max 1 (floor (/ (float days) sessions)))))))))

(defun readq--apply-deadline (item &optional now)
  "Bring ITEM's due date forward if its deadline needs an earlier session."
  (when-let ((cap (and (readq--active-p item) (readq--deadline-cap item now))))
    (let ((latest (readq--date-in cap now))
          (due (readq--get item :due)))
      (when (or (null due) (string< latest due))
        (readq--put item :due latest
                    :interval (float (min (or (readq--get item :interval) cap) cap)))))))

(defun readq--deadline-items (&optional tag)
  "Return the items with a deadline (only those under TAG's, if given)."
  (cl-remove-if-not
   (lambda (b)
     (and (memq (readq--get b :status) '(active finished))
          (when-let ((dl (readq--effective-deadline b)))
            (or (null tag) (equal (cdr dl) tag)))))
   (readq--books)))

(defun readq--deadline-needed-p (item &optional now)
  "Return non-nil when ITEM has an unfinished deadline."
  (when-let ((info (readq--deadline-info item now)))
    (not (plist-get info :done))))

(declare-function org-read-date "org")

(defun readq--read-deadline (prompt &optional current)
  "Read a deadline date with PROMPT; return YYYY-MM-DD, or nil to clear.
CURRENT is shown as the default.  Accepts what `org-read-date' does:
\"1 dec\", \"+3w\", \"2026-12-01\"..."
  (require 'org)
  (let ((s (string-trim (read-string (format "%s (e.g. 1 dec, +3w; empty to clear%s): "
                                             prompt
                                             (if current (format ", now %s" current) ""))))))
    (unless (string-empty-p s)
      (org-read-date nil nil s))))

;;;###autoload
(defun readq-set-deadline (item date)
  "Set the deadline of ITEM (a book, section or recording) to DATE.
DATE is a YYYY-MM-DD string, or nil to clear it.  With a prefix
argument, set the deadline of a tag instead (`readq-set-tag-deadline')."
  (interactive
   (if current-prefix-arg
       (list nil 'tag)
     (let ((item (readq--target-book "Deadline of: ")))
       (when (readq--extract-p item)
         (user-error "Extracts have no deadlines; set one on the book or a tag"))
       (list item (readq--read-deadline (format "Finish \"%s\" by" (readq--get item :title))
                                        (readq--get item :deadline))))))
  (if (eq date 'tag)
      (call-interactively #'readq-set-tag-deadline)
    (when (readq--extract-p item)
      (user-error "Extracts have no deadlines; set one on the book or a tag"))
    (readq--put item :deadline date)
    (readq--apply-deadline item)
    (readq--changed item "%s" (readq--deadline-message item))))

;;;###autoload
(defun readq-set-tag-deadline (tag date)
  "Finish everything tagged TAG by DATE (YYYY-MM-DD), or clear it if nil."
  (interactive
   (let ((tag (readq--normalize-tag
               (completing-read "Deadline for tag: "
                                (mapcar (lambda (tg) (concat "#" tg)) (readq--all-tags))
                                nil nil "#"))))
     (when (string-empty-p tag) (user-error "No tag given"))
     (list tag (readq--read-deadline (format "Finish #%s by" tag)
                                     (cdr (assoc tag readq--tag-deadlines))))))
  (readq--books)
  (setq tag (readq--normalize-tag tag))
  (setq readq--tag-deadlines (assoc-delete-all tag readq--tag-deadlines))
  (when date (push (cons tag date) readq--tag-deadlines))
  (setq readq--dirty t)
  (let ((items (readq--deadline-items tag)))
    (dolist (it items) (readq--apply-deadline it))
    (readq--save)
    (readq--refresh-dashboard)
    (message (if date
                 (format "#%s: finish by %s, %d item%s" tag date
                         (length items) (if (= (length items) 1) "" "s"))
               (format "#%s has no deadline now" tag)))))

(defun readq--deadline-message (item &optional now)
  "Return a sentence about ITEM's deadline, or \"no deadline\"."
  (let ((info (readq--deadline-info item now)))
    (cond
     ((null info) (format "\"%s\" has no deadline" (readq--get item :title)))
     ((plist-get info :done)
      (format "\"%s\" is finished, before its deadline %s" (readq--get item :title)
              (plist-get info :date)))
     ((plist-get info :missed)
      (format "\"%s\" missed its deadline %s with %s left" (readq--get item :title)
              (plist-get info :date)
              (readq--amount-string (plist-get info :remaining) (plist-get info :unit))))
     (t
      (format "%s left of \"%s\" by %s%s: %s a day%s"
              (readq--amount-string (plist-get info :remaining) (plist-get info :unit))
              (readq--get item :title) (plist-get info :date)
              (if (plist-get info :tag) (format " (#%s)" (plist-get info :tag)) "")
              (readq--amount-string (plist-get info :per-day) (plist-get info :unit))
              (if (> (plist-get info :behind) 0)
                  (format ", %s behind"
                          (readq--amount-string (plist-get info :behind) (plist-get info :unit)))
                ""))))))

(defun readq--deadline-column (item &optional now)
  "Return the dashboard's Deadline cell for ITEM."
  (let ((info (readq--deadline-info item now)))
    (if (null info) ""
      (let ((date (format-time-string "%d %b" (readq--date-noon (plist-get info :date))))
            (unit (plist-get info :unit)))
        (cond ((plist-get info :done) (propertize (concat date " done") 'face 'success))
              ((plist-get info :missed)
               (propertize (concat date " missed") 'face 'readq-overdue-face))
              ((> (plist-get info :behind) 0)
               (propertize (format "%s -%s" date
                                   (readq--amount-string (plist-get info :behind) unit))
                           'face 'readq-over-budget-face))
              (t (format "%s %s/d" date
                         (readq--amount-string (plist-get info :per-day) unit))))))))

(defun readq--deadline-lines (&optional now)
  "Return lines describing every deadline, for `readq-workload'."
  (let ((groups nil))
    (dolist (it (readq--deadline-items))
      (let* ((dl (readq--effective-deadline it))
             (key (cons (cdr dl) (car dl))))
        (if-let ((g (assoc key groups)))
            (setcdr g (append (cdr g) (list it)))
          (push (list key it) groups))))
    (setq groups (sort groups (lambda (a b) (string< (cdar a) (cdar b)))))
    (when groups
      (append
       (list "Deadlines:")
       (cl-loop
        for (key . items) in groups
        append
        (let* ((date (cdr key)) (tag (car key))
               (days (max 0 (readq--days-until date now))))
          (cons (format "  %s by %s (%d day%s left)"
                        (if tag (concat "#" tag) (readq--get (car items) :title))
                        (format-time-string "%a %d %b" (readq--date-noon date))
                        days (if (= days 1) "" "s"))
                (mapcar
                 (lambda (it)
                   (let* ((info (readq--deadline-info it now))
                          (unit (plist-get info :unit))
                          (line (format "    %-34s %10s left  %10s/day  %s"
                                        (truncate-string-to-width (readq--get it :title) 34 nil nil "…")
                                        (readq--amount-string (plist-get info :remaining) unit)
                                        (readq--amount-string (plist-get info :per-day) unit)
                                        (cond ((plist-get info :done) "done")
                                              ((plist-get info :missed) "missed")
                                              ((> (plist-get info :behind) 0)
                                               (format "behind by %s"
                                                       (readq--amount-string
                                                        (plist-get info :behind) unit)))
                                              (t "on track")))))
                     (if (or (plist-get info :missed) (> (plist-get info :behind) 0))
                         (propertize line 'face 'readq-over-budget-face)
                       line)))
                 items))))
       (list "")))))

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
  (cond ((readq--missing-p book) 'readq-missing-face)
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

(defun readq--id-index ()
  "Return a hash table of all items by id."
  (let ((h (make-hash-table :test 'equal :size (length (readq--books)))))
    (dolist (b (readq--books) h) (puthash (readq--get b :id) b h))))


(defun readq--dashboard-parent (item)
  "Return the item ITEM is listed under in the dashboard, or nil.
A section is listed under its book, an extract under the extract it was
made from, or else its book."
  (cond ((readq--extract-p item)
         (or (and (readq--get item :parent) (readq--book-by-id (readq--get item :parent)))
             (readq--book-by-id (readq--get item :book))))
        ((readq--section-p item) (readq--book-by-id (readq--get item :book)))))

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
Parents come in the order of their most urgent item, children likewise.
An item with children is open when you opened it, or by default when
something under it is due.  Fills `readq--dashboard-rows'."
  (unless readq--dashboard-folds
    (setq readq--dashboard-folds (make-hash-table :test 'equal)))
  (setq readq--dashboard-extract-counts (make-hash-table :test 'equal))
  (dolist (b (readq--books))
    (when (and (readq--extract-p b) (readq--active-p b))
      (cl-incf (gethash (readq--get b :book) readq--dashboard-extract-counts 0))))
  (let* ((readq--id-index (or readq--id-index (readq--id-index)))
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
                  (sort (delete-dups (copy-sequence items))
                        (lambda (a b) (< (gethash a rank) (gethash b rank)))))
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
      (let ((parent (readq--dashboard-parent (readq--book-by-id id))))
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
         (id (tabulated-list-get-id))
         (readq--id-index (readq--id-index)))
    (dolist (b (readq--books))
      (when-let ((parent (readq--dashboard-parent b)))
        (puthash (readq--get parent :id) (if open 'closed 'open) readq--dashboard-folds)))
    (readq--dashboard-print)
    (let ((item (and id (readq--book-by-id id))))
      ;; Stay on the line, or on its top item when it was hidden.
      (while (and item (readq--dashboard-parent item)
                  (not (gethash (readq--get item :id) readq--dashboard-rows)))
        (setq item (readq--dashboard-parent item)))
      (when item (readq--dashboard-goto (readq--get item :id))))
    (message (if open "Everything folded" "Everything unfolded"))))

(defun readq--extracts-of (book &optional all)
  "Return the extracts made from BOOK; only active ones unless ALL."
  (let ((id (readq--get book :id)))
    (cl-remove-if-not (lambda (x) (and (readq--extract-p x)
                                       (equal (readq--get x :book) id)
                                       (or all (readq--active-p x))))
                      (readq--books))))

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
        ((eq (readq--viewer book) 'sumatra) "sumatra")
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
      ("sumatra" (readq--icon "file-pdf-o" 'all-the-icons-orange "PDF, read in SumatraPDF"))
      ("audio" (readq--icon "headphones" 'all-the-icons-lpurple "audio"))
      ("video" (readq--icon "film" 'all-the-icons-blue "video"))
      ("online" (readq--icon "youtube-play" 'all-the-icons-red "online video"))
      ("epub" (readq--icon "book" 'all-the-icons-blue "EPUB"))
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
  "Return the tabulated-list entry for BOOK."
  (list (readq--get book :id)
        (vconcat (mapcar (lambda (spec) (or (funcall (nth 4 spec) book) ""))
                         (or readq--dashboard-shown-columns (readq--dashboard-columns))))))

(defun readq--dashboard-entries ()
  "Return all tabulated-list entries for the dashboard."
  ;; Items are looked up by id many times while drawing: index them.
  (let ((readq--id-index (readq--id-index)))
    (mapcar #'readq--dashboard-entry (readq--dashboard-tree))))

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
              (t (let ((va (funcall fn (car pa))) (vb (funcall fn (car pb))))
                   (cond ((funcall lessp va vb) t)
                         ((funcall lessp vb va) nil)
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
    (format " %d due (%d extracts), %d in queue%s%s" due due-x (length q)
            (if readq--focus (concat " — focus: " (readq--tags-string-of readq--focus)) "")
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
    (define-key map "f" #'readq-toggle-finished)
    (define-key map "x" #'readq-toggle-pause)
    (define-key map "t" #'readq-edit-title)
    (define-key map "R" #'readq-relocate)
    (define-key map "D" #'readq-remove-book)
    (define-key map "F" #'readq-dashboard-toggle-finished)
    (define-key map "E" #'readq-dashboard-toggle-extracts)
    (define-key map "e" #'readq-visit-extracts)
    (define-key map "i" #'readq-import-highlights)
    (define-key map "v" #'readq-set-viewer)
    (define-key map "s" #'readq-goto-source)
    (define-key map "T" #'readq-add-sections)
    (define-key map "U" #'readq-add-url)
    (define-key map "M" #'readq-set-media-toc)
    (define-key map "c" #'readq-mark-ready)
    (define-key map "C" #'readq-export-cards)
    (define-key map "#" #'readq-set-tags)
    (define-key map "/" #'readq-focus)
    (define-key map "L" #'readq-workload)
    (define-key map "!" #'readq-set-deadline)
    (define-key map "P" #'readq-extract-figure)
    (define-key map "y" #'readq-extract-figure-from-clipboard)
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
  (when-let ((buf (get-buffer "*readq*")))
    (with-current-buffer buf
      (when (derived-mode-p 'readq-dashboard-mode)
        (readq--dashboard-print)))))

(defun readq-dashboard-open ()
  "Open the book at point."
  (interactive)
  (if-let ((id (tabulated-list-get-id)))
      (readq-open (readq--book-by-id id))
    (user-error "No book on this line")))

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

;;;; Extracts

;; An extract is a passage of a book that becomes an item of its own in
;; the queue, with its own priority and schedule.  Its text lives in an
;; Org file, one per book, saved next to the book (see
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

(defun readq--extract-heading (item book text level comment)
  "Return the Org text of extract ITEM of BOOK at heading LEVEL.
TEXT is the extracted passage and COMMENT an optional note."
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
            (if (string-empty-p text) ""
              (concat "#+begin_quote\n" (readq--org-escape text) "\n#+end_quote\n"))
            (if (and comment (not (string-empty-p (string-trim comment))))
                (concat "Note: " (string-trim comment) "\n")
              "")
            "\n")))

(defun readq--insert-extract-heading (item book text comment parent)
  "Write extract ITEM of BOOK to its Org file, as a child of PARENT if any.
TEXT is the passage and COMMENT an optional note."
  (with-current-buffer (readq--extracts-buffer (readq--get item :file) book)
    (save-excursion
      (save-restriction
        (widen)
        (let ((level 1)
              (ppos (and parent (org-find-property "READQ_ID" (readq--get parent :id)))))
          (if (not ppos)
              (goto-char (point-max))
            (goto-char ppos)
            (setq level (1+ (or (org-current-level) 0)))
            (org-end-of-subtree t t))
          (unless (bolp) (insert "\n"))
          (insert (readq--extract-heading item book text level comment)))))
    (let ((save-silently t)) (save-buffer))))

(cl-defun readq--create-extract (source text &key page point edges comment color
                                        priority ask section parts tags figure title)
  "Create an extract of TEXT from SOURCE (a book or a parent extract).
PAGE is the page (PDF) or chapter index (EPUB); POINT the position in
an EPUB chapter or text; EDGES the PDF areas of the passage; SECTION
the heading of the passage in a text or web page.  PARTS describes the
passages of an extract made of several selections, as plists
\(:page :point :edges :key :snippet :length).  TAGS are the extract's
own tags (it also has its book's).  COMMENT is a note
and COLOR the highlight color.  FIGURE is the image file of a
figure extract, relative to the extracts file; TITLE overrides the
heading.  PRIORITY defaults to SOURCE's priority
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
    (readq--insert-extract-heading item book text comment parent)
    (setq readq--books (append (readq--books) (list item)))
    (readq--save)
    (readq--refresh-dashboard)
    item))

;;;###autoload
(defun readq-extract (&optional arg)
  "Turn the selected text into an extract.
Works in a PDF (pdf-tools), an EPUB (nov.el), a text book (Org,
Markdown, plain text), a web page in eww, and inside an extract being
reviewed (making a sub-extract).

Several passages can be selected at once with multi-region
\(`multi-region-mode') or, in a PDF, with pdf-tools' C-drag; they become
one extract, see `readq-extract-multiple'.

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
           ((derived-mode-p 'pdf-view-mode) (readq--extract-from-pdf ask mode))
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

(defcustom readq-figures-directory (locate-user-emacs-file "readq-figures/")
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

(defun readq--figure-file (item)
  "Return the absolute file name of figure extract ITEM's image, or nil.
The image is recorded by its full name, or relative to the extracts
file.  If it is not there, it is looked for by name in
`readq-figures-directory', in case that folder moved."
  (when-let ((rel (readq--get item :figure)))
    (let ((file (expand-file-name rel (file-name-directory
                                       (expand-file-name (readq--get item :file))))))
      (if (file-exists-p file)
          file
        (let ((moved (expand-file-name (file-name-nondirectory file) readq-figures-directory)))
          (if (file-exists-p moved) moved file))))))

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
         (ext (or (and (plist-get image :file)
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
    (when-let ((link (or (cl-find-if (lambda (l) (<= (car l) pos (cadr l))) links)
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
  "Return PNG data of the area EDGES (relative) of PAGE of the PDF FILE."
  (require 'pdf-info)
  (require 'pdf-util)
  (let* ((size (pdf-info-pagesize page file))
         (width (round (* (car size) (/ readq-figure-dpi 72.0))))
         ;; Exactly `readq-figure-dpi', whatever the screen's scaling.
         (pdf-view-use-scaling nil))
    (pdf-info-renderpage page width file :crop-to edges)))

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
         (region (and (pdf-view-active-region-p) (pdf-view-active-region)))
         (page (if (and region (numberp (car region))) (car region)
                 (image-mode-window-get 'page)))
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
      (when region (pdf-view-deactivate-region))
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
             ((and (derived-mode-p 'pdf-view-mode) (readq--buffer-book))
              (readq--figure-from-pdf))
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
      (org-display-inline-images nil t (point-min) (point-max)))))

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

(defun readq--images-for-drill (text dir)
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

(defun readq--restore-drill-images (text links)
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

(defun readq--copy-anki-media (cards)
  "Copy the images of CARDS to `readq-anki-media-directory'.
Return the images that could not be copied because it is not set."
  (let ((files (delete-dups (apply #'append (mapcar #'readq--card-images cards)))))
    (if (not readq-anki-media-directory)
        files
      (dolist (f files)
        (when (file-exists-p f)
          (copy-file f (expand-file-name (readq--anki-media-name f)
                                         readq-anki-media-directory)
                     t)))
      nil)))

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

(defun readq--text-parts (clean)
  "Return the passages selected in this buffer, in reading order.
They come from multi-region if it has selections, else from the
region.  Each is a plist (:text :page :point :section); CLEAN is
applied to the text."
  (let ((sels (or (and (readq--multi-region-p) (multi-region-selections t))
                  (and (use-region-p)
                       (list (list :beg (region-beginning) :end (region-end))))))
        (nov (derived-mode-p 'nov-mode))
        (point-book (and readq-book-mode
                         (readq--point-format-p
                          (readq--get (readq--buffer-book) :format)))))
    (unless sels (user-error "Select some text first"))
    (delq nil
          (mapcar
           (lambda (sel)
             (let* ((beg (plist-get sel :beg))
                    (text (funcall clean (or (plist-get sel :text)
                                             (buffer-substring-no-properties
                                              beg (plist-get sel :end))))))
               (unless (string-empty-p text)
                 (list :text text
                       :point beg
                       :page (cond (nov (or (plist-get sel :chapter) nov-documents-index))
                                   (point-book (readq--section-number beg)))
                       :section (and point-book (readq--section-at beg))))))
           sels))))

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
:edges)."
  (let ((sels (and (readq--multi-region-p) (multi-region-selections))))
    (cond
     (sels
      (mapcar (lambda (sel) (list :text (readq--clean-text (plist-get sel :text))
                                  :page (plist-get sel :page)
                                  :edges (list (plist-get sel :edges))))
              sels))
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
  (let* ((parts (cl-remove-if (lambda (p) (string-empty-p (plist-get p :text))) parts))
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
    (if (or (eq mode 'separate) (null (cdr parts)))
        (mapcar (lambda (p)
                  (readq--create-extract source (plist-get p :text)
                                         :page (plist-get p :page)
                                         :point (plist-get p :point)
                                         :edges (plist-get p :edges)
                                         :section (plist-get p :section)
                                         :priority priority
                                         :tags tags))
                parts)
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
                              parts)))))))

(defun readq--extract-from-pdf (ask mode)
  "Create extracts from the selections of a pdf-tools buffer.
ASK and MODE are as in `readq--extract-parts'."
  (let* ((book (readq--source-book-here))
         (region (and (pdf-view-active-region-p) (pdf-view-active-region)))
         (paged (readq--pdf-paged-p (or region (bound-and-true-p pdf-view-active-region))))
         (parts (readq--pdf-parts))
         highlighted skipped)
    (when readq-extract-add-highlight
      (dolist (p parts)
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
      (pdf-view-deactivate-region)
      (readq--done-selecting))))

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
  (unless readq-review-mode
    (setq readq--review-id nil)))

(defun readq--show-subtree ()
  "Unfold the Org subtree at point."
  (if (fboundp 'org-fold-show-subtree) (org-fold-show-subtree) (org-show-subtree)))

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

(defun readq--end-review ()
  "Save the Org buffer, sync the extract's title, and leave review mode."
  (let ((item (readq--book-by-id readq--review-id)))
    (when item
      (save-restriction
        (widen)
        (when-let ((pos (org-find-property "READQ_ID" (readq--get item :id))))
          (save-excursion
            (goto-char pos)
            (let ((title (org-get-heading t t t t)))
              (unless (string-empty-p title) (readq--put item :title title)))))))
    (when (buffer-modified-p) (let ((save-silently t)) (save-buffer)))
    (when readq-narrow-to-extract (widen))
    (readq-review-mode -1)
    item))

(defun readq--finish-review (&optional quiet)
  "Finish reviewing the extract in this buffer and reschedule it.
Return the extract.  With QUIET, do not report."
  (let* ((secs readq--session-seconds)
         (item (readq--end-review)))
    (when (and item (readq--active-p item))
      ;; Only the extract's own time: a book's time is its reading.
      (readq--put item :seconds (+ (or (readq--get item :seconds) 0) secs))
      (readq--log-reading secs 0)
      (readq--count-session item (readq--get item :page) nil secs)
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
  (when-let ((book (and (null (readq--get item :parent))
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

;;;;; Deleting an extract with its highlight

(declare-function pdf-annot-getannots "ext:pdf-annot" (&optional pages types buffer))
(declare-function pdf-annot-delete "ext:pdf-annot" (a))
(declare-function pdf-annot-get "ext:pdf-annot" (a property &optional default))
(declare-function pdf-info-delannot "ext:pdf-info" (id &optional file-or-buffer))
(declare-function pdf-info-save "ext:pdf-info" (&optional file-or-buffer))

(defun readq--extract-descendants (item)
  "Return the sub-extracts of extract ITEM, at any depth."
  (let ((kids (cl-remove-if-not (lambda (x) (and (readq--extract-p x)
                                                 (equal (readq--get x :parent)
                                                        (readq--get item :id))))
                                (readq--books))))
    (append kids (mapcan #'readq--extract-descendants kids))))

(defun readq--delete-org-entry (item)
  "Delete the Org entry of extract ITEM (with its sub-extracts' entries).
Return non-nil if it was found.  The text goes to the kill ring."
  (let ((file (readq--get item :file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (when-let ((pos (org-find-property "READQ_ID" (readq--get item :id))))
              (goto-char pos)
              (org-cut-subtree)
              (let ((save-silently t)) (save-buffer))
              t)))))))

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
With the PDF open in pdf-tools, they are deleted there and the PDF
saved; otherwise the file is changed directly (SumatraPDF highlights too).
Needs pdf-tools."
  (let* ((book (readq--item-book item))
         (pieces (cl-remove-if-not (lambda (p) (and (plist-get p :page) (plist-get p :edges)))
                                   (readq--extract-pieces item)))
         (deleted 0))
    (when (and book pieces (eq (readq--get book :format) 'pdf)
               (not (readq--missing-p book))
               (readq--pdf-info-available-p))
      (let ((buf (readq--pdf-buffer-visiting book))
            (file (expand-file-name (readq--get book :file))))
        (condition-case err
            (if buf
                (with-current-buffer buf
                  (require 'pdf-annot)
                  (dolist (p pieces)
                    (dolist (a (pdf-annot-getannots (plist-get p :page)))
                      (when (readq--highlight-match-p a (plist-get p :page)
                                                      (plist-get p :edges))
                        (pdf-annot-delete a)
                        (setq deleted (1+ deleted)))))
                  (when (> deleted 0) (save-buffer)))
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
                (ignore-errors (pdf-info-close file))))
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
      (when-let ((ov (cl-find-if (lambda (o) (overlay-get o 'readq-extract-id))
                                 (overlays-at (point)))))
        (readq--book-by-id (overlay-get ov 'readq-extract-id)))
      (when-let* (((derived-mode-p 'pdf-view-mode))
                  (book (readq--buffer-book))
                  (page (image-mode-window-get 'page))
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
          (when-let ((f (readq--figure-file x)))
            (delete-file f))
          (setq readq--books (delq x (readq--books))))
        (readq--save)
        (when book
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (and readq-book-mode (equal readq--book-id (readq--get book :id)))
                (readq--decorate-extracts)))))
        (readq--refresh-dashboard)
        (message "Deleted \"%s\"%s%s" (readq--get item :title)
                 (if in-org "" " (its Org entry was already gone)")
                 (if (> highlights 0)
                     (format "; %d highlight%s removed from the PDF" highlights
                             (if (= highlights 1) "" "s"))
                   ""))
        item))))

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
          (find-file-other-window (readq--get book :file)))))
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
       ((derived-mode-p 'pdf-view-mode) (pdf-view-goto-page page))
       ((derived-mode-p 'doc-view-mode) (doc-view-goto-page page))
       ((derived-mode-p 'nov-mode)
        (unless (eql page nov-documents-index) (nov-goto-document page))
        (readq--goto-text point snippet)
        (ignore-errors (recenter))))
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
          (when-let ((m (readq--find-text (plist-get piece :snippet)
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
  (when-let ((attrs (file-attributes file)))
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
  (when-let ((rgb (readq--color-rgb color)))
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

;;;;; Flashcards

;; Extracts you have boiled down become flashcards:
;;
;; - An extract whose text contains cloze deletions, written
;;   {{hidden text}} or {{hidden text::hint}} (`readq-cloze' adds them),
;;   becomes a cloze card.  Anki's {{c1::...}} form works too: clozes
;;   with the same number are hidden together.
;; - Any other extract becomes a question/answer card: its heading is
;;   the question and its text the answer.
;;
;; `readq-mark-ready' tags an extract as ready; `readq-export-cards'
;; sends every ready extract to org-drill or Anki.

(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-toggle-tag "org" (tag &optional onoff))
(declare-function org-get-tags "org" (&optional epom local))
(declare-function org-export-string-as "ox" (string backend &optional body-only ext-plist))
(defvar org-drill-left-cloze-delimiter)
(defvar org-drill-right-cloze-delimiter)
(defvar org-drill-hint-separator)
(defvar url-http-end-of-headers)
(defvar url-request-method)
(defvar url-request-data)
(defvar url-request-extra-headers)
(defvar url-proxy-services)
(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)
(declare-function json-encode "json" (object))
(declare-function json-read-from-string "json" (string))
(declare-function outline-next-heading "outline" ())
(declare-function url-do-setup "url" ())

(defun readq-cloze (beg end &optional hint)
  "Hide the text between BEG and END in a cloze deletion: {{text}}.
With a prefix argument, ask for a HINT shown in place of the text."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end)
             (and current-prefix-arg (read-string "Hint: ")))
     (user-error "Select the text to hide first")))
  (save-excursion
    (goto-char end)
    (insert (if (and hint (not (string-empty-p hint))) (concat "::" hint) "") "}}")
    (goto-char beg)
    (insert "{{"))
  (deactivate-mark))

(defconst readq--cloze-re "{{\\(\\(?:.\\|\n\\)+?\\)}}"
  "Regexp matching a cloze deletion; group 1 is its contents.")

(defun readq--number-clozes (text)
  "Number the clozes of TEXT the Anki way: {{x}} becomes {{cN::x}}.
Clozes already numbered keep their number; each other one gets the
next free number, so it becomes a card of its own."
  (let ((n 0) (start 0))
    (while (string-match "{{c\\([0-9]+\\)::" text start)
      (setq n (max n (string-to-number (match-string 1 text)))
            start (match-end 0)))
    (replace-regexp-in-string
     readq--cloze-re
     (lambda (m)
       (save-match-data
         (let ((inner (progn (string-match readq--cloze-re m) (match-string 1 m))))
           (if (string-match-p "\\`c[0-9]+::" inner)
               m
             (setq n (1+ n))
             (format "{{c%d::%s}}" n inner)))))
     text t t)))

(defun readq--cloze-count (text)
  "Return the number of distinct cloze numbers in TEXT (numbered already)."
  (let (nums (start 0))
    (while (string-match "{{c\\([0-9]+\\)::" text start)
      (cl-pushnew (match-string 1 text) nums :test #'equal)
      (setq start (match-end 0)))
    (length nums)))

(defun readq--extract-content (item)
  "Read extract ITEM from its Org file.
Return a plist (:heading :text :note), or nil if it cannot be found.
The text is the entry's body without the Source line, quote block
markers and \"Note:\" lines; notes are returned in :note."
  (require 'org)
  (let ((file (readq--get item :file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (when-let ((pos (org-find-property "READQ_ID" (readq--get item :id))))
              (goto-char pos)
              (let* ((heading (org-get-heading t t t t))
                     (beg (progn (org-end-of-meta-data t) (point)))
                     (end (progn (goto-char pos) (outline-next-heading) (point)))
                     (lines (split-string (buffer-substring-no-properties
                                           (min beg end) end)
                                          "\n"))
                     notes body)
                (dolist (line lines)
                  (cond ((string-match "\\`Source: \\[\\[readq:" line))
                        ((string-match "\\`Note: \\(.*\\)" line)
                         (push (match-string 1 line) notes))
                        (t (push line body))))
                (list :heading heading
                      :text (readq--org-unescape (mapconcat #'identity (nreverse body) "\n"))
                      :note (and notes (mapconcat #'identity (nreverse notes) "\n")))))))))))

(defun readq--make-card (item)
  "Return a flashcard plist for extract ITEM, or nil if it has no text."
  (when-let* ((content (readq--extract-content item))
              (book (readq--book-by-id (readq--get item :book))))
    (let* ((text (readq--number-clozes (plist-get content :text)))
           (clozes (readq--cloze-count text)))
      (unless (string-empty-p text)
        (list :item item
              :book book
              :type (if (> clozes 0) 'cloze 'basic)
              :clozes clozes
              :front (plist-get content :heading)
              :text text
              :note (plist-get content :note)
              :source (readq--source-description book (readq--get item :page)
                                                 (readq--get item :section)))))))

(defun readq--update-entry-tags (item add remove)
  "Add the tags ADD to the Org entry of ITEM and remove the tags REMOVE.
Also pick up the entry's heading as ITEM's title, in case you edited it."
  (require 'org)
  (let ((file (readq--get item :file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (when-let ((pos (org-find-property "READQ_ID" (readq--get item :id))))
              (goto-char pos)
              (let ((title (org-get-heading t t t t)))
                (unless (string-empty-p title) (readq--put item :title title)))
              (dolist (tag remove) (org-toggle-tag tag 'off))
              (dolist (tag add) (org-toggle-tag tag 'on))
              (let ((save-silently t)) (save-buffer)))))))))

(defun readq-mark-ready (item)
  "Mark extract ITEM as ready to become a flashcard, or unmark it.
A ready extract leaves the reading queue until `readq-export-cards'
turns it into a card.  When you are reviewing it, go on with
`readq-next'."
  (interactive (list (readq--target-book "Mark ready for a flashcard: ")))
  (unless (readq--extract-p item)
    (user-error "Only extracts can become flashcards"))
  (let ((reviewing (and readq-review-mode
                        (equal readq--review-id (readq--get item :id))))
        (ready (not (eq (readq--get item :status) 'ready))))
    (when reviewing (readq--end-review))
    (readq--put item :status (if ready 'ready 'active))
    (when ready (readq--put item :exported nil))
    (readq--update-entry-tags item
                              (and ready (list readq-card-ready-tag))
                              (if ready (list readq-card-exported-tag)
                                (list readq-card-ready-tag)))
    (readq--save)
    (readq--refresh-dashboard)
    (message (if ready "\"%s\" is ready to become a flashcard (%s exports)"
               "\"%s\" is back in the reading queue")
             (readq--get item :title)
             (substitute-command-keys "\\[readq-export-cards]"))
    (when (and reviewing ready) (readq-next))))

(defun readq--ready-extracts ()
  "Return the extracts to export: marked ready, or tagged ready in Org."
  (require 'org)
  (let* ((extracts (cl-remove-if-not
                    (lambda (x) (and (readq--extract-p x) (not (readq--missing-p x))))
                    (readq--books)))
         (files (delete-dups (mapcar (lambda (x) (readq--get x :file)) extracts)))
         (tagged nil))
    (dolist (file files)
      (with-current-buffer (find-file-noselect file)
        (save-restriction
          (widen)
          (setq tagged (append (delq nil (org-map-entries
                                          (lambda () (org-entry-get nil "READQ_ID"))
                                          readq-card-ready-tag 'file))
                               tagged)))))
    (cl-remove-if-not (lambda (x) (or (eq (readq--get x :status) 'ready)
                                      (member (readq--get x :id) tagged)))
                      extracts)))

(defun readq--mark-exported (item backend)
  "Record that extract ITEM was exported to BACKEND."
  (readq--put item
              :exported (list :date (readq--today) :backend backend)
              :status (if readq-dismiss-after-export 'finished 'active))
  (readq--update-entry-tags item (list readq-card-exported-tag)
                            (list readq-card-ready-tag)))

(defun readq--read-backend (ask)
  "Return the flashcard backend, asking when ASK or configured to."
  (if (and (not ask) (memq readq-flashcard-backend '(anki org-drill)))
      readq-flashcard-backend
    (intern (completing-read "Export flashcards to: " '("anki" "org-drill") nil t))))

;;;###autoload
(defun readq-export-cards (backend)
  "Turn the extracts marked ready into flashcards in BACKEND.
BACKEND is `anki' or `org-drill', see `readq-flashcard-backend'; with
a prefix argument, choose it.  Return the number of cards exported."
  (interactive (list (readq--read-backend current-prefix-arg)))
  (let* ((items (readq--ready-extracts))
         (cards (delq nil (mapcar #'readq--make-card items)))
         (empty (- (length items) (length cards)))
         (unedited (cl-count-if
                    (lambda (c) (and (eq (plist-get c :type) 'basic)
                                     (string-prefix-p
                                      (string-remove-suffix "…" (plist-get c :front))
                                      (plist-get c :text))))
                    cards)))
    (unless items
      (user-error "No extract is ready; mark extracts with `readq-mark-ready'"))
    (let ((done (pcase backend
                  ('org-drill (readq--export-org-drill cards))
                  ('anki (readq--export-anki cards))
                  (_ (user-error "Unknown flashcard backend: %s" backend)))))
      (dolist (card done)
        (readq--mark-exported (plist-get card :item) backend))
      (readq--save)
      (readq--refresh-dashboard)
      (message "Exported %d flashcard%s to %s%s%s"
               (length done) (if (= (length done) 1) "" "s")
               (if (eq backend 'anki) "Anki" "org-drill")
               (if (> empty 0) (format "; %d ready extract%s had no text" empty
                                       (if (= empty 1) "" "s"))
                 "")
               (if (> unedited 0)
                   (format "; %d question%s still the start of the answer (edit the heading)"
                           unedited (if (= unedited 1) " is" "s are"))
                 ""))
      (length done))))

;;;;;; org-drill

(defun readq--drill-file (book)
  "Return the org-drill file receiving the cards of BOOK."
  (if readq-drill-file
      (expand-file-name readq-drill-file)
    (concat (file-name-sans-extension (expand-file-name (readq--extracts-file book)))
            "-cards.org")))

(defun readq--cloze-to-drill (text)
  "Convert the {{cN::x::hint}} clozes of TEXT to org-drill's [x||hint].
Other square brackets become parentheses, so that org-drill does not
take them for clozes."
  (let ((left (if (boundp 'org-drill-left-cloze-delimiter) org-drill-left-cloze-delimiter "["))
        (right (if (boundp 'org-drill-right-cloze-delimiter) org-drill-right-cloze-delimiter "]"))
        (sep (if (boundp 'org-drill-hint-separator) org-drill-hint-separator "||")))
    (replace-regexp-in-string
     readq--cloze-re
     (lambda (m)
       (save-match-data
         (let* ((inner (progn (string-match readq--cloze-re m) (match-string 1 m)))
                (parts (split-string (replace-regexp-in-string "\\`c[0-9]+::" "" inner)
                                     "::")))
           (concat left (car parts) (if (cadr parts) (concat sep (cadr parts)) "") right))))
     (replace-regexp-in-string "\\]" ")" (replace-regexp-in-string "\\[" "(" text))
     t t)))

(defun readq--drill-body (text)
  "Return TEXT safe to use as an Org entry body."
  (replace-regexp-in-string "^\\*" " *" text))

(defun readq--drill-entry (card)
  "Return the org-drill entry for CARD."
  (let* ((item (plist-get card :item))
         (cloze (eq (plist-get card :type) 'cloze))
         (note (plist-get card :note))
         ;; Image links survive the cloze conversion and the move to
         ;; another folder.
         (images (readq--images-for-drill (plist-get card :text) (readq--card-directory card)))
         (text (car images)))
    (concat "* " (if cloze (plist-get card :source) (plist-get card :front))
            " :" (mapconcat #'identity (cons "drill" (readq--item-tags item)) ":") ":\n"
            ":PROPERTIES:\n:READQ_CARD_OF: " (readq--get item :id) "\n"
            (if (and cloze (> (plist-get card :clozes) 1))
                ":DRILL_CARD_TYPE: hide1cloze\n" "")
            ":END:\n"
            (readq--restore-drill-images
             (if cloze
                 (concat (readq--drill-body (readq--cloze-to-drill text)) "\n")
               (concat "** Answer\n" (readq--drill-body text) "\n"))
             (cdr images))
            (if note (concat (if cloze "** Note\n" "") (readq--drill-body note) "\n") "")
            "** Source\n[[readq:" (readq--get item :id) "][" (plist-get card :source) "]]\n\n")))

(defun readq--export-org-drill (cards)
  "Append CARDS to org-drill files.  Return the cards exported."
  (require 'org)
  (dolist (card cards)
    (let* ((book (plist-get card :book))
           (file (readq--drill-file book))
           (buf (progn (make-directory (file-name-directory file) t)
                       (find-file-noselect file))))
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (when (= (buffer-size) 0)
              (insert (if readq-drill-file
                          "#+TITLE: Flashcards from readq\n"
                        (format "#+TITLE: Flashcards from %s\n" (readq--get book :title)))
                      "#+STARTUP: overview\n\n"))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert (readq--drill-entry card)))))))
  (dolist (file (delete-dups (mapcar (lambda (c) (readq--drill-file (plist-get c :book))) cards)))
    (with-current-buffer (find-file-noselect file)
      (let ((save-silently t)) (save-buffer))))
  cards)

;;;;;; Anki

(defun readq--html-escape (text)
  "Escape TEXT for HTML."
  (replace-regexp-in-string
   ">" "&gt;" (replace-regexp-in-string
               "<" "&lt;" (replace-regexp-in-string "&" "&amp;" text))))

(defun readq--org-to-html (text)
  "Convert the Org TEXT to HTML for an Anki field."
  (if (string-empty-p (string-trim (or text "")))
      ""
    (condition-case nil
        (progn
          (require 'ox-html)
          (string-trim
           (org-export-string-as text 'html t
                                 '(:with-toc nil :section-numbers nil
                                   :with-sub-superscript nil :with-smart-quotes nil
                                   :with-latex verbatim))))
      (error (replace-regexp-in-string "\n" "<br>" (readq--html-escape text))))))

(defun readq--anki-deck (book)
  "Return the Anki deck for cards of BOOK."
  (if readq-anki-subdeck-per-book
      (concat readq-anki-deck "::" (replace-regexp-in-string "::" ":" (readq--get book :title)))
    readq-anki-deck))

(defun readq--anki-note (card)
  "Return (MODEL DECK FIELDS TAGS) for CARD, FIELDS an alist."
  (let* ((book (plist-get card :book))
         (note (plist-get card :note))
         (text (readq--images-for-anki (plist-get card :text) (readq--card-directory card)))
         (extra (concat (if note (concat (readq--org-to-html note) "\n") "")
                        "<div class=\"readq-source\">"
                        (readq--html-escape (plist-get card :source)) "</div>"))
         (tags (append readq-anki-tags
                       (list (concat "readq-" (readq--slug (readq--get book :title))))
                       (readq--item-tags (plist-get card :item)))))
    (if (eq (plist-get card :type) 'cloze)
        (pcase-let ((`(,model ,text-field ,extra-field) readq-anki-cloze-model))
          (list model (readq--anki-deck book)
                (list (cons text-field (readq--org-to-html text))
                      (cons extra-field extra))
                tags))
      (pcase-let ((`(,model ,front-field ,back-field) readq-anki-basic-model))
        (list model (readq--anki-deck book)
              (list (cons front-field (readq--html-escape (plist-get card :front)))
                    (cons back-field (concat (readq--org-to-html text)
                                             "\n" extra)))
              tags)))))

(defun readq--anki-connect (action &optional params)
  "Call the AnkiConnect ACTION with PARAMS (an alist) and return its result."
  (require 'url)
  (require 'json)
  ;; Read proxy settings now, so that the binding below (Anki runs on
  ;; this computer, never behind a proxy) is not overridden by them.
  (url-do-setup)
  (let* ((url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data
          (encode-coding-string
           (json-encode `((action . ,action) (version . 6)
                          ,@(and params `((params . ,params)))))
           'utf-8))
         (url-proxy-services nil)
         (buf (url-retrieve-synchronously readq-anki-connect-url t t 15)))
    (unless buf (error "No answer from AnkiConnect at %s" readq-anki-connect-url))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (or url-http-end-of-headers (point-min)))
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (response (json-read-from-string
                            (decode-coding-string
                             (buffer-substring-no-properties (point) (point-max))
                             'utf-8))))
            (when (cdr (assq 'error response))
              (error "AnkiConnect: %s" (cdr (assq 'error response))))
            (cdr (assq 'result response))))
      (kill-buffer buf))))

(defun readq--anki-reachable-p ()
  "Return non-nil when AnkiConnect answers."
  (condition-case nil (progn (readq--anki-connect "version") t) (error nil)))

(defun readq--export-anki-connect (cards)
  "Add CARDS to Anki through AnkiConnect.  Return the cards added.
Cards Anki already has (duplicates) count as added."
  (let (done failed)
    (dolist (deck (delete-dups (mapcar (lambda (c) (readq--anki-deck (plist-get c :book)))
                                       cards)))
      (readq--anki-connect "createDeck" `((deck . ,deck))))
    (dolist (card cards)
      (pcase-let ((`(,model ,deck ,fields ,tags) (readq--anki-note card)))
        (condition-case err
            (progn
              (dolist (f (readq--card-images card))
                (readq--anki-connect "storeMediaFile"
                                     `((filename . ,(readq--anki-media-name f))
                                       (path . ,(expand-file-name f)))))
              (readq--anki-connect
               "addNote"
               `((note . ((deckName . ,deck)
                          (modelName . ,model)
                          (fields . ,fields)
                          (tags . ,(vconcat tags))
                          (options . ((allowDuplicate . :json-false)))))))
              (push card done))
          (error
           (if (string-match-p "duplicate" (error-message-string err))
               (push card done)
             (push (cons card (error-message-string err)) failed))))))
    (when failed
      (display-warning
       'readq
       (concat "Some cards could not be added to Anki:\n"
               (mapconcat (lambda (f) (format "- %s: %s"
                                              (plist-get (car f) :front) (cdr f)))
                          (nreverse failed) "\n"))))
    (nreverse done)))

(defun readq--tsv-field (string)
  "Quote STRING as a field of Anki's import file."
  (concat "\"" (replace-regexp-in-string
                "\"" "\"\"" (replace-regexp-in-string "[\t\n\r]+" " " string))
          "\""))

(defun readq--export-anki-file (cards)
  "Append CARDS to `readq-anki-export-file'.  Return the cards written."
  (let* ((file (expand-file-name readq-anki-export-file))
         (new (not (and (file-exists-p file)
                        (> (or (file-attribute-size (file-attributes file)) 0) 0)))))
    (with-temp-buffer
      (when new
        (insert "#separator:Tab\n#html:true\n#notetype column:1\n#deck column:2\n"
                "#tags column:5\n"))
      (dolist (card cards)
        (pcase-let ((`(,model ,deck ,fields ,tags) (readq--anki-note card)))
          (insert (mapconcat #'readq--tsv-field
                             (list model deck (cdr (nth 0 fields)) (cdr (nth 1 fields))
                                   (mapconcat #'identity tags " "))
                             "\t")
                  "\n")))
      (make-directory (file-name-directory file) t)
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) file (not new) 'silent)))
    (when-let ((missing (readq--copy-anki-media cards)))
      (display-warning
       'readq
       (concat "These figures must go in Anki's media folder (collection.media)"
               " for the cards to show them; set `readq-anki-media-directory'"
               " to have readq copy them:\n"
               (mapconcat (lambda (f) (format "- %s as %s" f (readq--anki-media-name f)))
                          missing "\n"))))
    (message "Wrote %d card%s to %s; import it in Anki with File > Import"
             (length cards) (if (= (length cards) 1) "" "s") file)
    cards))

(defun readq--export-anki (cards)
  "Send CARDS to Anki, see `readq-anki-method'.  Return the cards exported."
  (cond
   ((eq readq-anki-method 'file) (readq--export-anki-file cards))
   ((readq--anki-reachable-p) (readq--export-anki-connect cards))
   ((y-or-n-p "Cannot reach Anki (is it running, with the AnkiConnect add-on?).  \
Write an import file instead? ")
    (readq--export-anki-file cards))
   (t (user-error "Nothing exported; start Anki and try again"))))

;;;; Keymap

;;;###autoload
(defvar readq-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "l" #'readq)
    (define-key map "n" #'readq-next)
    (define-key map "o" #'readq-open)
    (define-key map "s" #'readq-suggest)
    (define-key map "a" #'readq-add-book)
    (define-key map "A" #'readq-add-directory)
    (define-key map "f" #'readq-finish-session)
    (define-key map "p" #'readq-set-priority)
    (define-key map "+" #'readq-priority-up)
    (define-key map "-" #'readq-priority-down)
    (define-key map "r" #'readq-reschedule)
    (define-key map "z" #'readq-postpone)
    (define-key map "F" #'readq-toggle-finished)
    (define-key map "x" #'readq-toggle-pause)
    (define-key map "e" #'readq-extract)
    (define-key map "d" #'readq-dismiss)
    (define-key map "g" #'readq-goto-source)
    (define-key map "E" #'readq-visit-extracts)
    (define-key map "i" #'readq-import-highlights)
    (define-key map "I" #'readq-import-all-highlights)
    (define-key map "v" #'readq-set-viewer)
    (define-key map "c" #'readq-mark-ready)
    (define-key map "T" #'readq-add-sections)
    (define-key map "u" #'readq-add-url)
    (define-key map "m" #'readq-media-mark)
    (define-key map "D" #'readq-delete-extract)
    (define-key map "M" #'readq-set-media-toc)
    (define-key map "k" #'readq-cloze)
    (define-key map "C" #'readq-export-cards)
    (define-key map "#" #'readq-set-tags)
    (define-key map "/" #'readq-focus)
    (define-key map "L" #'readq-workload)
    (define-key map "!" #'readq-set-deadline)
    (define-key map "P" #'readq-extract-figure)
    (define-key map "y" #'readq-extract-figure-from-clipboard)
    map)
  "Prefix keymap for readq commands.
Bind it to a key, e.g. (global-set-key (kbd \"C-c r\") readq-command-map).")
;;;###autoload
(fset 'readq-command-map readq-command-map)

(provide 'readq)
;;; readq.el ends here
