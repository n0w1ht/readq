;;; readq-core.el --- Options, database, scheduling and progress -*- lexical-binding: t; -*-

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

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'card-export)
(require 'readq-comic)

(declare-function image-mode-window-get "image-mode" (prop &optional winprops))
(declare-function pdf-view-goto-page "ext:pdf-view" (page &optional window))
(declare-function pdf-cache-number-of-pages "ext:pdf-cache" (&optional file-or-buffer))
(declare-function pdf-info-number-of-pages "ext:pdf-info" (&optional file-or-buffer))
(declare-function doc-view-goto-page "doc-view" (page))
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
(declare-function doc-view-last-page-number "doc-view" ())
(declare-function nov-goto-document "ext:nov" (index))

(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-file-name)

(defvar multi-region-mode)
(declare-function readq--section-location "readq-sections")
(declare-function readq--format-time "readq-media")
(declare-function readq--page-format-p "readq-book")
(declare-function readq--point-format-p "readq-book")
(declare-function readq--tags-match-p "readq-sections")
(declare-function readq--apply-deadline "readq-plan")
(declare-function readq--estimate-minutes "readq-plan" (item))
(declare-function readq--refresh-dashboard "readq-dashboard")
(declare-function readq--save-all "readq-book")

;;;; Customization

(defgroup readq nil
  "Incremental reading queue for PDF and EPUB books."
  :group 'applications
  :prefix "readq-")

(custom-add-to-group 'readq 'readq-comic 'custom-group)

(defcustom readq-db-file "~/notes/readq.eld"
  "File where readq stores your books and reading progress.
It is in ~/notes/ by default, with its backups (see
`readq-backup-directory'), your extracts (`readq-extracts-directory')
and figures (`readq-figures-directory').  A database left in
~/.emacs.d/ by an older readq is copied here the first time; see
`readq--copy-old-files'."
  :type 'file)

(defcustom readq-backup-directory nil
  "Directory for daily backups of `readq-db-file', or nil.
When nil, backups go to a \"readq-backups\" directory next to the
database.  See `readq-backup-count' and `readq-restore-backup'."
  :type '(choice (const :tag "Next to the database" nil) directory))

(defcustom readq-backup-count 14
  "How many daily backups of the database to keep.
On the first save of each day, readq copies the database as it was
into `readq-backup-directory'; the oldest backups beyond this number
are deleted.  0 or nil turns backups off."
  :type '(choice (const :tag "No backups" nil) natnum))

(defcustom readq-file-extensions
  '(("pdf" . pdf) ("epub" . epub) ("cbz" . comic) ("cbr" . comic) ("cb7" . comic)
    ("org" . text) ("md" . text) ("markdown" . text) ("txt" . text)
    ("html" . html) ("htm" . html)
    ("mp3" . media) ("m4a" . media) ("m4b" . media) ("aac" . media) ("ogg" . media)
    ("opus" . media) ("flac" . media) ("wav" . media)
    ("mp4" . media) ("m4v" . media) ("mkv" . media) ("webm" . media) ("mov" . media)
    ("avi" . media))
  "Alist mapping file extensions to book formats.
The format `pdf' means a page-based document (pdf-tools, pdf-canvas or
doc-view);
`epub' a chapter-based document read with nov.el; `comic' a comic book
archive (CBZ, CBR) of page images, see `readq-open-comic'; `text' a
text file read in its usual mode (Org, Markdown, plain text); `html' a
web page read in eww; `media' audio or video, played in mpv."
  :type '(alist :key-type string
                :value-type (choice (const :tag "Page based (PDF)" pdf)
                                    (const :tag "Chapter based (EPUB)" epub)
                                    (const :tag "Comic book archive (CBZ, CBR)" comic)
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

(defcustom readq-book-schedule 'steady
  "How books, sections and recordings come back.
`steady': at a fixed rhythm set by priority, every
`readq-book-min-interval' days at priority 0 and every
`readq-book-max-interval' days at priority 100, until the book is
finished.  `growing': like extracts, the interval is multiplied after
each session (see `readq-min-afactor').  Extracts always grow."
  :type '(choice (const :tag "A steady rhythm set by priority" steady)
                 (const :tag "Growing intervals, like extracts" growing)))

(defcustom readq-book-min-interval 1
  "Days between sessions of a book of priority 0, see `readq-book-schedule'."
  :type 'number)

(defcustom readq-book-max-interval 7
  "Days between sessions of a book of priority 100, see `readq-book-schedule'."
  :type 'number)

(defcustom readq-late-credit 1.0
  "How much of the days an item waited past its due date count.
An extract due after 4 days and read after 10 has its next interval
built from 10 days with 1.0, from 4 days with 0 (lateness ignored), and
from 7 with 0.5.  Unless this is 0, an extract reviewed before it is due
grows by less, in proportion to the days that did pass."
  :type 'number)

(defcustom readq-session-weight-floor 0.5
  "Smallest weight of a short session, or nil to weigh all sessions alike.
A session counts in full when it lasted at least half the item's usual
time, or advanced at least half its usual progress.  A shorter one
counts for less, down to this: an extract's interval grows by less, and
a book on a steady rhythm comes back sooner."
  :type '(choice (const :tag "All sessions count the same" nil) number))

(defcustom readq-schedule-fuzz 0.1
  "How far a due date may move to even out the load of the days.
0.1 lets an item due in 20 days be due 2 days sooner or later, on the
day with the least reading planned.  Intervals of 3 days or more may
move by at least a day.  0 schedules exactly."
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

(defcustom readq-count-listening t
  "Non-nil means time spent listening counts as reading time.
While Kokoro (kokoro.el) reads a book or an extract aloud, its reading
time keeps counting even when Emacs is idle or another window is
selected, so it shows in the daily limit, the stats and the session.
Pausing Kokoro stops the count."
  :type 'boolean)

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

(defcustom readq-chapter-depth 1
  "How many levels of a book's table of contents group its extracts.
A book's extracts are listed under the chapter they were made in, in
the dashboard, taken from the book's
own table of contents (PDF outline, EPUB table of contents, headings of
Org, Markdown and web pages).  With 1, extracts go under the top
level of the table of contents: an extract in section 4.3 of chapter 4
of part II goes under part II.  With 2, it goes under part II, then
chapter 4.  nil uses
every level; 0 lists extracts right under their book, as books without
a table of contents always are."
  :type '(choice (const :tag "Every level" nil)
                 (const :tag "None: extracts right under their book" 0)
                 (integer :tag "Levels")))

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

(defcustom readq-extracts-directory "~/notes/"
  "The folder where your extracts go, each a note of its own.
Extracts are Org files named and laid out as Denote names notes,
IDENTIFIER==SIGNATURE--TITLE__KEYWORDS.org, all in this one folder:
the identifier is the time the extract was made, the signature its
book and page, the keywords its tags.  The folder is made when the
first extract is.  Set it to your `denote-directory' to keep extracts
with your other notes; when nil, `denote-directory' is used if Denote
is loaded, and ~/notes/ otherwise."
  :type '(choice (const :tag "Denote's folder" nil) directory))

(defcustom readq-extract-initial-interval 1
  "Days until a new extract is first due for review."
  :type 'number)

(defcustom readq-extract-priority-offset 0
  "Added to the source's priority to get a new extract's priority.
A negative value makes extracts more important than their book."
  :type 'number)

(defcustom readq-extract-add-highlight t
  "When non-nil, `readq-extract' in a PDF also highlights the passage.
That works in pdf-tools and pdf-canvas.  The highlight is saved into
the PDF, so you see it in SumatraPDF too."
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
  "Number of characters of an extract used as its title."
  :type 'integer)

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

(defcustom readq-default-comic-viewer 'emacs
  "Viewer used for comics, unless chosen per book with `readq-set-viewer'.
SumatraPDF reads CBZ and CBR too, and readq tracks the page there as
for PDFs."
  :type '(choice (const :tag "Emacs (readq-comic-mode)" emacs)
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
  "Turning extracts into flashcards (org-srs or Anki)."
  :group 'readq
  :prefix "readq-")

(defcustom readq-flashcard-backend 'ask
  "Where `readq-export-cards' sends flashcards.
`anki' for Anki, `org-srs' for org-srs files, or `ask' to choose
at each export."
  :type '(choice (const :tag "Ask each time" ask)
                 (const :tag "Anki" anki)
                 (const :tag "org-srs" org-srs)))

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

(define-obsolete-variable-alias 'readq-drill-file 'readq-srs-file "0.1.0")

(defcustom readq-srs-file nil
  "Org file that receives org-srs cards.
When nil, each book gets its own cards file in the folder of your
extracts, e.g. \"gray-s-anatomy-cards.org\".  Run `org-srs-review-start' in that
file (with a prefix argument, it offers a wider scope, such as the
whole folder)."
  :type '(choice (const :tag "One file per book, next to its extracts" nil) file))

(defcustom readq-anki-method 'ankiconnect
  "How cards reach Anki.
`ankiconnect' adds them directly to the running Anki through the
AnkiConnect add-on; if Anki cannot be reached, readq offers to write
the import file instead.  `file' always writes `readq-anki-export-file',
which you import with File > Import in Anki."
  :type '(choice (const :tag "AnkiConnect add-on" ankiconnect)
                 (const :tag "Import file" file)))

(define-obsolete-variable-alias 'readq-anki-connect-url
  'card-export-anki-connect-url "0.1.0")

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

(defvar readq--subset nil
  "The subset being reviewed, or nil.  See `readq-review-subset'.
A plist (:name NAME :ids IDS :total N): IDS are the ids of the items
not opened yet, in the order they come.  Saved with the database.")

(defvar readq--log nil
  "Reading done per day: a list of (DATE :seconds SECS :items N), newest first.
Saved with the database.  See `readq-daily-minutes'.")

(defvar readq--tag-deadlines nil
  "Deadlines of tags: a list of (TAG . DATE).  Saved with the database.
See `readq-set-tag-deadline'.")

(defvar readq--spread-date nil
  "The date on which items over the daily budget were last spread out.
Saved with the database.")

(defvar readq-figures-directory)

(defun readq--default-p (symbol)
  "Return non-nil when the option SYMBOL has its default value."
  (equal (symbol-value symbol) (eval (car (get symbol 'standard-value)) t)))

(defun readq--copy-old-files ()
  "Copy the files an older readq kept in `user-emacs-directory'.
readq used to keep its database, backups and figures in ~/.emacs.d/;
they are now in ~/notes/.  When `readq-db-file' has its default
value and does not exist yet, but the old database does, the old
database is copied to it, the backups to `readq--backup-directory' and
the figures to `readq-figures-directory' (each only if not customized
and not there yet).  The old files are left where they are.  Return
non-nil when the database was copied."
  (let ((old-db (expand-file-name (locate-user-emacs-file "readq.eld")))
        (new-db (expand-file-name readq-db-file)))
    (when (and (readq--default-p 'readq-db-file)
               (not (file-exists-p new-db))
               (not (readq--same-file-p old-db new-db))
               (file-readable-p old-db))
      (make-directory (file-name-directory new-db) t)
      (copy-file old-db new-db nil t)
      (let ((old-backups (expand-file-name (locate-user-emacs-file "readq-backups/")))
            (new-backups (readq--backup-directory)))
        (when (and (null readq-backup-directory)
                   (file-directory-p old-backups)
                   (not (file-exists-p new-backups)))
          (copy-directory old-backups new-backups t t t)))
      (let ((old-figures (expand-file-name (locate-user-emacs-file "readq-figures/")))
            (new-figures (expand-file-name readq-figures-directory)))
        (when (and (readq--default-p 'readq-figures-directory)
                   (file-directory-p old-figures)
                   (not (file-exists-p new-figures)))
          (copy-directory old-figures new-figures t t t)))
      (display-warning
       'readq (format "readq now keeps its files in %s.  Your queue was copied there \
from %s; the old files are left in place, and can be deleted once all is well."
                      (abbreviate-file-name (file-name-directory new-db))
                      (abbreviate-file-name (file-name-directory old-db)))
       :warning)
      t)))

(defun readq--load ()
  "Read the database from `readq-db-file'."
  (readq--copy-old-files)
  (setq readq--books nil
        readq--focus nil
        readq--subset nil
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
                     (error "readq: cannot read %s: %S%s" readq-db-file err
                            (if (readq--backups)
                                "; restore a backup with M-x readq-restore-backup"
                              ""))))))
        (setq readq--books (copy-tree (plist-get data :books))
              readq--focus (plist-get data :focus)
              readq--subset (copy-tree (plist-get data :subset))
              readq--log (copy-tree (plist-get data :log))
              readq--spread-date (plist-get data :spread-date)
              readq--tag-deadlines (copy-tree (plist-get data :tag-deadlines))))))
  (when (and (not (file-exists-p readq-db-file)) (readq--backups))
    (display-warning
     'readq (format "There is no database at %s, but there are backups in %s.  \
To get your queue back, run M-x readq-restore-backup before adding anything."
                    readq-db-file (readq--backup-directory))))
  (setq readq--loaded t
        readq--dirty nil))

(defun readq--books ()
  "Return the list of all books, loading the database if needed."
  (unless readq--loaded (readq--load))
  readq--books)

;; The database is written to a temporary file next to it, read back,
;; and only then renamed over the old one, so a crash, a full disk or a
;; sync program in the middle of a save never leaves half a database.
;; Before the first save of each day, the database as it was is copied
;; to the backup directory.

(defun readq--save ()
  "Write the database to `readq-db-file', safely, backing it up first."
  (when readq--loaded
    (let* ((file (expand-file-name readq-db-file))
           (tmp (concat file ".tmp"))
           (print-length nil)
           (print-level nil)
           (print-escape-newlines t)
           (coding-system-for-write 'utf-8-unix))
      (make-directory (file-name-directory file) t)
      (readq--backup-db)
      (with-temp-buffer
        (insert ";;; readq database  -*- mode: lisp-data; coding: utf-8 -*-\n"
                (format "(:version 1\n :focus %S\n :subset %S\n :tag-deadlines %S\n :spread-date %S\n :log %S\n :books\n ("
                        readq--focus readq--subset readq--tag-deadlines readq--spread-date
                        readq--log))
        (dolist (book readq--books)
          (prin1 book (current-buffer))
          (insert "\n  "))
        (insert "))\n")
        (write-region (point-min) (point-max) tmp nil 'silent))
      (unless (readq--db-file-ok-p tmp (length readq--books))
        (ignore-errors (delete-file tmp))
        (error "readq: the database could not be written to %s; it was not changed"
               tmp))
      (condition-case nil
          (rename-file tmp file t)
        ;; Windows refuses to replace a file another program holds open
        ;; (a sync client, say); copying over it usually still works.
        (file-error
         (copy-file tmp file t)
         (delete-file tmp))))
    (setq readq--dirty nil)))

(defun readq--read-db-file (file)
  "Return the data read from the database FILE, or nil if it can't be read."
  (ignore-errors
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (goto-char (point-min))
      (let ((data (read (current-buffer))))
        (and (consp data) (plist-member data :books) data)))))

(defun readq--db-file-ok-p (file count)
  "Return non-nil when FILE reads back as a database with COUNT items."
  (when-let* ((data (readq--read-db-file file)))
    (= (length (plist-get data :books)) count)))

(defun readq--backup-directory ()
  "Return the directory of database backups."
  (file-name-as-directory
   (expand-file-name (or readq-backup-directory
                         (expand-file-name "readq-backups"
                                           (file-name-directory
                                            (expand-file-name readq-db-file)))))))

(defun readq--backups ()
  "Return the daily backup files of the database, newest first."
  (let ((dir (readq--backup-directory)))
    (and (file-directory-p dir)
         (nreverse (directory-files
                    dir t "\\`readq-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.eld\\'")))))

(defun readq--backup-db (&optional now)
  "Copy the database to today's backup, if there is none yet.
Delete the oldest backups beyond `readq-backup-count'.  NOW is the time."
  (let ((file (expand-file-name readq-db-file)))
    (when (and readq-backup-count (> readq-backup-count 0)
               (file-exists-p file))
      (let* ((dir (readq--backup-directory))
             (backup (expand-file-name (format "readq-%s.eld" (readq--today now)) dir)))
        (unless (file-exists-p backup)
          (condition-case err
              (progn
                (make-directory dir t)
                (copy-file file backup nil t)
                (dolist (old (nthcdr readq-backup-count (readq--backups)))
                  (delete-file old)))
            (file-error
             (display-warning 'readq (format "Could not back up the database to %s: %s"
                                             dir (error-message-string err))))))))))

(defun readq--count-books-extracts (items)
  "Return \"N books, M extracts\" for ITEMS."
  (let ((books (cl-count-if #'readq--book-p items))
        (extracts (cl-count-if #'readq--extract-p items)))
    (format "%d book%s, %d extract%s"
            books (if (= books 1) "" "s") extracts (if (= extracts 1) "" "s"))))

(defun readq--backup-description (file)
  "Return a short description of the backup FILE, for completion."
  (let ((data (readq--read-db-file file)))
    (if data
        (let ((items (plist-get data :books)))
          (readq--count-books-extracts items))
      "unreadable")))

;;;###autoload
(defun readq-restore-backup (backup)
  "Replace the database with BACKUP, one of the daily backups.
The database you had before is kept in the backup directory, as
readq-before-restore-DATE_TIME.eld, and offered here too, so a
restore can be undone."
  (interactive
   (let* ((dir (readq--backup-directory))
          (backups (or (append (readq--backups)
                               (and (file-directory-p dir)
                                    (nreverse (directory-files
                                               dir t "\\`readq-before-restore-.*\\.eld\\'"))))
                       (user-error "No backups in %s" dir)))
          (names (mapcar (lambda (f)
                           (cons (format "%s  (%s)"
                                         (replace-regexp-in-string
                                          "-restore-" " restore "
                                          (substring (file-name-base f) 6))
                                         (readq--backup-description f))
                                 f))
                         backups))
          (choice (completing-read "Restore the database from: "
                                   (lambda (str pred action)
                                     (if (eq action 'metadata)
                                         '(metadata (display-sort-function . identity))
                                       (complete-with-action action names str pred)))
                                   nil t)))
     (list (cdr (assoc choice names)))))
  (unless (readq--read-db-file backup)
    (user-error "%s is not a readable readq database" backup))
  (when (or (not (called-interactively-p 'any))
            (yes-or-no-p (format "Replace your readq database with %s? "
                                 (file-name-nondirectory backup))))
    (let ((file (expand-file-name readq-db-file)))
      ;; Save open sessions first, so the copy below is complete.
      (when readq--loaded
        (ignore-errors (readq--save-all)))
      (when (file-exists-p file)
        (let ((dir (readq--backup-directory)))
          (make-directory dir t)
          (let* ((base (format-time-string "readq-before-restore-%Y-%m-%d_%H%M%S"))
                 (keep (expand-file-name (concat base ".eld") dir))
                 (n 1))
            (while (file-exists-p keep)
              (setq n (1+ n)
                    keep (expand-file-name (format "%s-%d.eld" base n) dir)))
            (copy-file file keep nil t))))
      (copy-file backup file t t)
      (setq readq--loaded nil)
      (readq--load)
      (readq--refresh-dashboard)
      (message "readq: restored the database from %s (%s)"
               (file-name-nondirectory backup) (readq--backup-description file)))))

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
  "Return non-nil when ITEM is a book (not an extract, a section or a chapter)."
  (not (memq (readq--get item :format) '(extract section chapter))))

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
    (when-let* ((ext (file-name-extension file)))
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

(defun readq--next-interval (interval priority &optional elapsed weight)
  "Return the interval following INTERVAL for an item of PRIORITY.
ELAPSED is the number of days since its last session, when known: late,
those days count instead of INTERVAL (see `readq-late-credit'); early,
the interval grows by less.  WEIGHT, from 0 to 1, is how much the
session counts (see `readq-session-weight-floor')."
  (let* ((interval (float (or interval readq-initial-interval)))
         (factor (1+ (* (or weight 1.0) (1- (readq--afactor priority)))))
         (credit (max 0.0 (min 1.0 (float (or readq-late-credit 0)))))
         (next (cond ((or (null elapsed) (= credit 0.0)) (* interval factor))
                     ((>= elapsed interval)
                      (* (+ interval (* credit (- elapsed interval))) factor))
                     (t (* interval (1+ (* (1- factor) (/ (max 0.0 (float elapsed))
                                                         interval))))))))
    (min (float readq-max-interval) (max (float readq-min-interval) next))))

(defun readq--steady-p (item)
  "Return non-nil when ITEM comes back at a steady rhythm.
See `readq-book-schedule'."
  (and (eq readq-book-schedule 'steady) (not (readq--extract-p item))))

(defun readq--steady-interval (priority &optional weight)
  "Return the days between sessions of a book of PRIORITY.
WEIGHT, from 0 to 1, shortens it after a session that hardly counted."
  (let ((p (/ (min 100.0 (max 0.0 (float priority))) 100.0)))
    (max (float readq-min-interval)
         (* (or weight 1.0)
            (+ readq-book-min-interval
               (* p (- readq-book-max-interval readq-book-min-interval)))))))

(defun readq--balanced-days (item days &optional now)
  "Return DAYS, or a number of days near it with less reading planned.
ITEM is the item being scheduled DAYS days after NOW; the day may move
by `readq-schedule-fuzz' of DAYS either way, to the day with the fewest
minutes of reading due.  Among equal days, the one nearest DAYS wins."
  (let ((range (if (or (< days 3) (<= (or readq-schedule-fuzz 0) 0))
                   0
                 (max 1 (round (* days readq-schedule-fuzz))))))
    (if (= range 0)
        days
      (let* ((lo (max 1 (- days range)))
             (hi (+ days range))
             (loads (make-vector (1+ (- hi lo)) 0.0))
             (best days))
        (dolist (b (readq--books))
          (when (and (not (eq b item)) (readq--active-p b) (readq--get b :due)
                     (or readq-queue-extracts (not (readq--extract-p b))))
            (let ((d (readq--days-until (readq--get b :due) now)))
              (when (<= lo d hi)
                (aset loads (- d lo)
                      (+ (aref loads (- d lo)) (readq--estimate-minutes b)))))))
        (cl-loop for d from lo to hi
                 for load = (aref loads (- d lo))
                 for best-load = (aref loads (- best lo))
                 when (or (< load best-load)
                          (and (= load best-load)
                               (< (abs (- d days)) (abs (- best days)))))
                 do (setq best d))
        best))))

(defun readq--reschedule (book &optional now elapsed weight)
  "Compute a new interval for BOOK and set its due date relative to NOW.
ELAPSED is the number of days since its last session and WEIGHT how
much this one counts, see `readq--next-interval'."
  (let ((interval (if (readq--steady-p book)
                      (readq--steady-interval (readq--get book :priority) weight)
                    (readq--next-interval (readq--get book :interval)
                                          (readq--get book :priority)
                                          elapsed weight))))
    (readq--put book
                :interval interval
                :due (readq--date-in (readq--balanced-days
                                      book (max 1 (round interval)) now)
                                     now))
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
    (and (not (readq--url-p file))
         (not (and file (file-exists-p file)))
         ;; A note renamed in Denote is found again by its identifier.
         (not (and (eq (readq--get book :format) 'extract)
                   (fboundp 'readq--extract-file)
                   (readq--extract-file book))))))

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
    (if (and (readq--page-format-p format) page total)
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
               ((or 'pdf 'comic) (format "p %d (%d–%d)" (or page start) start end))
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

(provide 'readq-core)
;;; readq-core.el ends here
