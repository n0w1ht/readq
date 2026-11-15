;;; readq-plan.el --- Daily workload, reading stats and deadlines -*- lexical-binding: t; -*-

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

(require 'readq-media)

(declare-function readq--refresh-dashboard "readq-dashboard")

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

(defcustom readq-overflow-stretch 0.5
  "How far items that keep not fitting in the budget are pushed back.
An item moved to a later day for the `readq-overflow-stretch-after'th
day running, without a session in between, waits this share of its
interval, times its priority over 100, and an extract's interval grows
by as much.  With 0.5, an extract of priority 80 and an interval of 10
days waits 4 more days, and one of priority 20 a single day: when there
is too much to read, what matters least gives way first.  0 or nil
moves everything to the next day with room."
  :type '(choice (const :tag "Never" nil) number))

(defcustom readq-overflow-stretch-after 2
  "Days running an item must be over the budget to be pushed back further.
See `readq-overflow-stretch'."
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
        ;; Keep a year of days, for `readq-stats'.
        (setq readq--log (cons entry (seq-take readq--log 400))))
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

(defun readq--overflow-wait (item times)
  "Return the least days ITEM waits when moved off today for the TIMESth day.
One day, or more for an item that keeps being over the budget, see
`readq-overflow-stretch'."
  (if (and readq-overflow-stretch (> readq-overflow-stretch 0)
           (>= times readq-overflow-stretch-after))
      (max 1 (round (* readq-overflow-stretch
                       (/ (readq--get item :priority) 100.0)
                       (or (readq--get item :interval) 1.0))))
    1))

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
             (times (1+ (or (readq--get it :overflows) 0)))
             (wait (readq--overflow-wait it times))
             (first (min (1- wait) (1- days)))
             (day (or (cl-position-if
                       (lambda (load)
                         (readq--fits-p (- (or readq-daily-minutes 0) (car load))
                                        (- (or readq-daily-items 0) (cdr load))))
                       loads :start first)
                      ;; Every day is full: the least loaded one.
                      (let ((best first))
                        (cl-loop for i from first below days
                                 when (< (car (aref loads i)) (car (aref loads best)))
                                 do (setq best i))
                        best)))
             (cell (aref loads day)))
        (setcar cell (+ (car cell) est))
        (setcdr cell (1+ (cdr cell)))
        (readq--put it :due (readq--date-in (1+ day) now) :overflows times)
        ;; An extract pushed back also comes back less often from now on.
        (when (and (> wait 1) (not (readq--steady-p it)))
          (readq--put it :interval
                      (min (float readq-max-interval)
                           (* (or (readq--get it :interval) 1.0)
                              (1+ (* readq-overflow-stretch
                                     (/ (readq--get it :priority) 100.0)))))))
        (readq--apply-deadline it now)
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

;;;; Reading stats

;; `readq-stats' sums up what you did over the last week, month or
;; year: time read per day, streaks, pages, extracts made, cards
;; exported and books finished, by book and by tag.  It uses the daily
;; log (`readq--log') and the history of sessions kept for every item.

(defcustom readq-stats-days 30
  "Days `readq-stats' looks back over, unless you choose otherwise."
  :type 'natnum
  :group 'readq-workload)

(defcustom readq-stats-bar-width 30
  "Width of the longest bar in `readq-stats'."
  :type 'natnum
  :group 'readq-workload)

(defvar-local readq--stats-days nil
  "Days the stats buffer shows.")

(defun readq--stats-sessions (from to)
  "Return the sessions from date FROM to date TO, as (ITEM . ENTRY) pairs.
ENTRY is a plist from the item's :history."
  (let (sessions)
    (dolist (item (readq--books))
      (dolist (h (readq--get item :history))
        (let ((date (plist-get h :date)))
          (when (and date (not (string< date from)) (not (string< to date)))
            (push (cons item h) sessions)))))
    sessions))

(defun readq--stats-pages (item entry)
  "Return the pages read in session ENTRY of ITEM, or 0."
  (let ((from (plist-get entry :from-page))
        (to (plist-get entry :to-page)))
    (if (and (numberp from) (numberp to) (> to from)
             (readq--page-format-p (readq--get (readq--item-book item) :format))
             (not (readq--extract-p item)))
        (- to from)
      0)))

(defun readq--stats-day-minutes (now days)
  "Return an alist of (DATE . MINUTES) for the DAYS days up to NOW, oldest first.
Days in the daily log use it; older days add up their sessions."
  (let ((from (readq--date-in (- (1- days)) now))
        (by-day (make-hash-table :test #'equal)))
    (dolist (s (readq--stats-sessions from (readq--today now)))
      (let ((date (plist-get (cdr s) :date)))
        (puthash date (+ (gethash date by-day 0)
                         (/ (or (plist-get (cdr s) :seconds) 0) 60.0))
                 by-day)))
    (cl-loop for i from (1- days) downto 0
             for date = (readq--date-in (- i) now)
             for logged = (assoc date readq--log)
             collect (cons date (if logged
                                    (/ (or (plist-get (cdr logged) :seconds) 0) 60.0)
                                  (gethash date by-day 0))))))

(defun readq--stats-streaks (now)
  "Return (CURRENT . LONGEST): days in a row with at least a minute of reading.
Today counts once you have read; until then the streak runs to yesterday."
  (let* ((days (cl-loop for d in (readq--stats-day-minutes now 400)
                        collect (>= (cdr d) 1)))
         (rev (reverse days))
         (current 0) (longest 0) (run 0))
    (dolist (read days)
      (setq run (if read (1+ run) 0)
            longest (max longest run)))
    ;; Today not read yet doesn't break the streak.
    (when (and rev (not (car rev))) (setq rev (cdr rev)))
    (while (and rev (car rev)) (cl-incf current) (setq rev (cdr rev)))
    (cons current longest)))

(defun readq--stats-period (now days)
  "Return a plist summing up the DAYS days up to NOW."
  (let* ((from (readq--date-in (- (1- days)) now))
         (to (readq--today now))
         (in (lambda (date) (and date (not (string< date from)) (not (string< to date)))))
         (sessions (readq--stats-sessions from to))
         (minutes (cl-reduce #'+ (mapcar #'cdr (readq--stats-day-minutes now days))))
         (books (make-hash-table :test #'eq))
         (tags (make-hash-table :test #'equal)))
    (dolist (s sessions)
      (let* ((item (car s))
             (book (or (readq--item-book item) item))
             (secs (or (plist-get (cdr s) :seconds) 0))
             (row (or (gethash book books) (list :seconds 0 :sessions 0 :pages 0 :extracts 0))))
        (puthash book (list :seconds (+ (plist-get row :seconds) secs)
                            :sessions (1+ (plist-get row :sessions))
                            :pages (+ (plist-get row :pages) (readq--stats-pages item (cdr s)))
                            :extracts (plist-get row :extracts))
                 books)
        (dolist (tag (readq--item-tags item))
          (puthash tag (+ (gethash tag tags 0) secs) tags))))
    (let ((extracts (cl-remove-if-not (lambda (x) (and (readq--extract-p x)
                                                       (funcall in (readq--get x :added))))
                                      (readq--books))))
      (dolist (x extracts)
        (when-let* ((book (readq--item-book x)))
          (let ((row (or (gethash book books) (list :seconds 0 :sessions 0 :pages 0 :extracts 0))))
            (puthash book (plist-put (copy-sequence row) :extracts (1+ (plist-get row :extracts)))
                     books))))
      (list :minutes minutes
            :sessions (length sessions)
            :pages (cl-reduce #'+ (mapcar (lambda (s) (readq--stats-pages (car s) (cdr s)))
                                          sessions))
            :days-read (cl-count-if (lambda (d) (>= (cdr d) 1))
                                    (readq--stats-day-minutes now days))
            :extracts (length extracts)
            :figures (cl-count-if (lambda (x) (readq--get x :figure)) extracts)
            :cards (cl-count-if (lambda (x)
                                  (and (readq--extract-p x)
                                       (funcall in (plist-get (readq--get x :exported) :date))))
                                (readq--books))
            :finished (cl-remove-if-not (lambda (b) (and (readq--book-p b)
                                                         (funcall in (readq--get b :finished-on))))
                                        (readq--books))
            :books (let (rows)
                     (maphash (lambda (b row) (push (cons b row) rows)) books)
                     (sort rows (lambda (a b) (> (plist-get (cdr a) :seconds)
                                                 (plist-get (cdr b) :seconds)))))
            :tags (let (rows)
                    (maphash (lambda (tag secs) (push (cons tag secs) rows)) tags)
                    (sort rows (lambda (a b) (> (cdr a) (cdr b)))))))))

(defun readq--stats-bar (value max)
  "Return a bar for VALUE out of MAX, `readq-stats-bar-width' wide at most."
  (let* ((eighths (if (> max 0) (round (* 8 readq-stats-bar-width (/ value (float max)))) 0))
         (full (/ eighths 8))
         (rest (% eighths 8)))
    (propertize (concat (make-string full ?█)
                        (if (> rest 0) (string (aref "▏▎▍▌▋▊▉" (1- rest))) ""))
                'face 'readq-progress-face)))

(defun readq--stats-chart (now days)
  "Return the lines of a bar chart of minutes read over DAYS days up to NOW.
Up to 31 days have a bar each; longer periods a bar per month."
  (let* ((per-day (readq--stats-day-minutes now days))
         (rows (if (<= days 31)
                   (mapcar (lambda (d)
                             (cons (format-time-string
                                    "%a %m-%d" (date-to-time (concat (car d) " 12:00")))
                                   (cdr d)))
                           per-day)
                 (let (months)
                   (dolist (d per-day)
                     (let* ((month (substring (car d) 0 7))
                            (cell (assoc month months)))
                       (if cell (setcdr cell (+ (cdr cell) (cdr d)))
                         (push (cons month (cdr d)) months))))
                   (nreverse months))))
         (max (apply #'max 1 (mapcar #'cdr rows))))
    (mapcar (lambda (r)
              (format "  %-9s %s %s" (car r)
                      (readq--stats-bar (cdr r) max)
                      (if (>= (cdr r) 0.5) (readq--duration-string (* 60 (cdr r))) "")))
            rows)))

(defun readq--stats-lines (&optional days now)
  "Return the lines of the stats report over DAYS days up to NOW."
  (let* ((days (or days readq-stats-days))
         (p (readq--stats-period now days))
         (prev (readq--stats-period (time-subtract (or now (current-time))
                                                   (days-to-time days))
                                    days))
         (streaks (readq--stats-streaks now))
         (done (readq--done-today now))
         (all (readq--books))
         (count (lambda (pred) (cl-count-if pred all)))
         (h (lambda (s) (propertize s 'face 'bold)))
         (change (lambda (key)
                   (let ((a (plist-get p key)) (b (plist-get prev key)))
                     (cond ((or (null b) (zerop b)) "")
                           (t (let ((pct (round (* 100 (/ (- a b) (float b))))))
                                (propertize (format " (%+d%% on the %d days before)" pct days)
                                            'face (if (>= pct 0) 'success 'shadow)))))))))
    (append
     (list (funcall h (format "Reading, last %d days" days))
           ""
           (format "  Today        %s, %d session%s"
                   (readq--duration-string (* 60 (car done)))
                   (cdr done) (if (= (cdr done) 1) "" "s"))
           (format "  Streak       %d day%s in a row (longest %d)"
                   (car streaks) (if (= (car streaks) 1) "" "s") (cdr streaks))
           (format "  Time         %s, on %d of %d days%s"
                   (readq--duration-string (* 60 (plist-get p :minutes)))
                   (plist-get p :days-read) days (funcall change :minutes))
           (format "  Average      %s a day"
                   (readq--duration-string (* 60 (/ (plist-get p :minutes) days))))
           (format "  Sessions     %d%s" (plist-get p :sessions) (funcall change :sessions))
           (format "  PDF pages    %d" (plist-get p :pages))
           (format "  Extracts     %d made%s%s"
                   (plist-get p :extracts)
                   (if (> (plist-get p :figures) 0)
                       (format " (%d figures)" (plist-get p :figures)) "")
                   (funcall change :extracts))
           (format "  Cards        %d exported" (plist-get p :cards))
           (format "  Finished     %s"
                   (if (plist-get p :finished)
                       (mapconcat (lambda (b) (format "\"%s\"" (readq--get b :title)))
                                  (plist-get p :finished) ", ")
                     "none"))
           ""
           (funcall h "Minutes read")
           "")
     (readq--stats-chart now days)
     (when-let* ((books (plist-get p :books)))
       (append
        (list "" (funcall h "By book")
              (propertize (format "  %-36s %8s %8s %6s %8s  %s"
                                  "" "Time" "Sessions" "Pages" "Extracts" "Progress")
                          'face 'shadow))
        (mapcar (lambda (row)
                  (let ((b (car row)) (r (cdr row)))
                    (format "  %-36s %8s %8d %6s %8d  %s"
                            (truncate-string-to-width (readq--get b :title) 36 nil nil "…")
                            (readq--duration-string (plist-get r :seconds))
                            (plist-get r :sessions)
                            (if (> (plist-get r :pages) 0) (plist-get r :pages) "")
                            (plist-get r :extracts)
                            (if (readq--book-p b)
                                (format "%d%%" (floor (* 100 (or (readq--get b :progress) 0))))
                              ""))))
                (seq-take books 15))))
     (when-let* ((tags (plist-get p :tags)))
       (let ((max (cdar tags)))
         (append
          (list "" (funcall h "By tag"))
          (mapcar (lambda (row)
                    (format "  %-16s %s %s"
                            (truncate-string-to-width (concat "#" (car row)) 16 nil nil "…")
                            (readq--stats-bar (cdr row) max)
                            (readq--duration-string (cdr row))))
                  (seq-take tags 10)))))
     (list ""
           (funcall h "Your queue")
           (format "  Books        %d reading, %d paused, %d finished"
                   (funcall count (lambda (b) (and (readq--book-p b) (readq--active-p b))))
                   (funcall count (lambda (b) (and (readq--book-p b)
                                                   (eq (readq--get b :status) 'paused))))
                   (funcall count (lambda (b) (and (readq--book-p b)
                                                   (eq (readq--get b :status) 'finished)))))
           (format "  Extracts     %d in the queue, %d ready for cards, %d exported, %d dismissed"
                   (funcall count (lambda (x) (and (readq--extract-p x) (readq--active-p x))))
                   (funcall count (lambda (x) (and (readq--extract-p x)
                                                   (eq (readq--get x :status) 'ready))))
                   (funcall count (lambda (x) (and (readq--extract-p x) (readq--get x :exported))))
                   (funcall count (lambda (x) (and (readq--extract-p x)
                                                   (eq (readq--get x :status) 'finished)
                                                   (not (readq--get x :exported))))))
           (format "  All time     %s read"
                   (readq--duration-string
                    (cl-reduce #'+ (mapcar (lambda (b) (if (readq--extract-p b) 0
                                                         (or (readq--get b :seconds) 0)))
                                           all))))
           ""
           (propertize "w week, m month, y year, g refresh, q quit" 'face 'shadow)))))

(defvar readq-stats-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "w" (lambda () (interactive) (readq-stats 7)))
    (define-key map "m" (lambda () (interactive) (readq-stats 30)))
    (define-key map "y" (lambda () (interactive) (readq-stats 365)))
    map)
  "Keymap for `readq-stats-mode'.")

(define-derived-mode readq-stats-mode special-mode "readq stats"
  "Major mode showing your reading stats.
\\{readq-stats-mode-map}"
  (setq-local revert-buffer-function (lambda (&rest _) (readq-stats readq--stats-days))))

;;;###autoload
(defun readq-stats (&optional days)
  "Show your reading stats over the last DAYS days.
DAYS defaults to `readq-stats-days'; a numeric prefix argument sets it.
In the stats buffer, w, m and y show the last week, month and year."
  (interactive (list (and current-prefix-arg (prefix-numeric-value current-prefix-arg))))
  (let ((days (max 1 (or days readq-stats-days)))
        (buf (get-buffer-create "*readq stats*")))
    (with-current-buffer buf
      (readq-stats-mode)
      (setq readq--stats-days days)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (mapconcat #'identity (readq--stats-lines days) "\n") "\n")
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
      ((or 'pdf 'comic)
       (if (readq--section-p item)
           (cons (float (1+ (- (readq--get item :end) (readq--get item :start)))) "p")
         (if-let* ((total (readq--get item :total)))
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
  (when-let* ((dl (readq--effective-deadline item)))
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
  (when-let* ((info (readq--deadline-info item now)))
    (unless (plist-get info :done)
      (let ((days (plist-get info :days))
            (pace (readq--session-pace item)))
        (if (or (<= days 1) (null pace))
            1
          (let ((sessions (max 1 (ceiling (/ (plist-get info :left) pace)))))
            (max 1 (floor (/ (float days) sessions)))))))))

(defun readq--apply-deadline (item &optional now)
  "Bring ITEM's due date forward if its deadline needs an earlier session."
  (when-let* ((cap (and (readq--active-p item) (readq--deadline-cap item now))))
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
          (when-let* ((dl (readq--effective-deadline b)))
            (or (null tag) (equal (cdr dl) tag)))))
   (readq--books)))

(defun readq--deadline-needed-p (item &optional now)
  "Return non-nil when ITEM has an unfinished deadline."
  (when-let* ((info (readq--deadline-info item now)))
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
        (if-let* ((g (assoc key groups)))
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

(provide 'readq-plan)
;;; readq-plan.el ends here
