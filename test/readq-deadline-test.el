;;; readq-deadline-test.el --- Tests for readq deadlines -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-deadline-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-tags-test)
(require 'readq-workload-test)

(defmacro readq-dltest--with-db (&rest body)
  "Run BODY with an empty database, a 60-minute budget and deadlines winning."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq-daily-minutes 60)
           (readq-daily-items nil)
           (readq-workload-overflow 'spread)
           (readq-workload-stop 'ask)
           (readq-workload-protected-priority 10)
           (readq-default-book-minutes 15)
           (readq-deadline-overrides-budget t))
       ,@body)))

(defun readq-dltest--pdf (name pages page &optional priority tags)
  "Add a PDF book NAME of PAGES pages, read up to PAGE; return it."
  (let ((b (readq-add-book (readq-test--touch (concat name ".pdf")) (or priority 50) name tags)))
    (readq--put b :total pages :page page :progress (/ (float page) pages))
    b))

(defun readq-dltest--paces (item &rest steps)
  "Give ITEM a history of sessions advancing by STEPS (fractions)."
  (readq--put item :history
              (mapcar (lambda (s) (list :date (readq--today) :from 0.0 :to s :seconds 600))
                      steps)))

;;;; An item's own deadline

(ert-deftest readq-dltest-item-deadline ()
  (readq-dltest--with-db
    (let ((b (readq-dltest--pdf "Guyton" 100 20)))
      (should-not (readq--deadline-info b))
      (should (equal (readq--deadline-column b) ""))
      (readq-set-deadline b (readq--date-in 10))
      (let ((info (readq--deadline-info b)))
        (should (= (plist-get info :days) 10))
        (should (= (plist-get info :remaining) 80))
        (should (= (plist-get info :per-day) 8))
        (should (equal (plist-get info :unit) "p"))
        (should (= (plist-get info :behind) 0))
        (should-not (plist-get info :tag)))
      (should (string-match-p "8 p/d$" (readq--deadline-column b)))
      (should (string-match-p "^80 p left of \"Guyton\" by .*: 8 p a day$"
                              (readq--deadline-message b)))
      ;; Clearing it.
      (readq-set-deadline b nil)
      (should-not (readq--deadline-info b)))))

(ert-deftest readq-dltest-behind ()
  (readq-dltest--with-db
    (let* ((b (readq-dltest--pdf "Robbins" 100 20))
           (start (readq--date-in -4))
           (date (readq--date-in 6)))
      (readq--put b :deadline date)
      ;; The deadline applied 4 days ago, with nothing read; 10 days in all.
      (readq--put b :deadline-start (list date start 0.0))
      (let ((info (readq--deadline-info b)))
        ;; Even pace: 40% by now.  20% read: 20 pages behind.
        (should (= (round (plist-get info :behind)) 20))
        (should (= (round (plist-get info :per-day)) 13)))
      (should (string-match-p "-20 p$" (readq--deadline-column b)))
      (should (eq (get-text-property 0 'face (readq--deadline-column b))
                  'readq-over-budget-face))
      (should (string-match-p ", 20 p behind$" (readq--deadline-message b)))
      ;; A new date starts a new even pace.
      (readq--put b :deadline (readq--date-in 8))
      (should (= (plist-get (readq--deadline-info b) :behind) 0)))))

(ert-deftest readq-dltest-missed-and-done ()
  (readq-dltest--with-db
    (let ((b (readq-dltest--pdf "Late" 100 50)))
      (readq--put b :deadline (readq--today))
      (should (plist-get (readq--deadline-info b) :missed))
      (should (string-match-p "missed$" (readq--deadline-column b)))
      (should (= (readq--deadline-cap b) 1))
      (readq--put b :page 100 :progress 1.0)
      (should (plist-get (readq--deadline-info b) :done))
      (should-not (readq--deadline-needed-p b))
      (should-not (readq--deadline-cap b))
      (should (string-match-p "done$" (readq--deadline-column b))))))

(ert-deftest readq-dltest-units ()
  (readq-dltest--with-db
    (let ((lecture (readq-add-book (readq-test--touch "lecture.mp3") 50 "Lecture"))
          (novel (readq-add-book (readq-test--touch "novel.epub") 50 "Novel")))
      (readq--put lecture :format 'media :total 3600.0 :progress 0.5)
      (readq--put novel :progress 0.25)
      (readq--put lecture :deadline (readq--date-in 3))
      (readq--put novel :deadline (readq--date-in 3))
      (should (equal (readq--item-size lecture) '(60.0 . "min")))
      (should (= (plist-get (readq--deadline-info lecture) :remaining) 30))
      (should (string-match-p "10 min/d$" (readq--deadline-column lecture)))
      (should (string-match-p "25%/d$" (readq--deadline-column novel))))
    (should (equal (readq--amount-string 2.26 "p") "2.3 p"))
    (should (equal (readq--amount-string 12.4 "%") "12%"))))

;;;; Scheduling

(ert-deftest readq-dltest-cap ()
  (readq-dltest--with-db
    (let ((b (readq-dltest--pdf "Harrison" 100 20)))
      (readq--put b :deadline (readq--date-in 10))
      ;; No pace known yet: every day.
      (should (= (readq--deadline-cap b) 1))
      ;; 10% a session: 8 sessions in 10 days.
      (readq-dltest--paces b 0.1 0.1 0.1)
      (should (= (readq--deadline-cap b) 1))
      ;; 40% a session: 2 sessions, every 5 days.
      (readq-dltest--paces b 0.4 0.4 0.3)
      (should (= (readq--deadline-cap b) 5))
      ;; Setting the deadline brings a far due date forward.
      (readq--put b :deadline nil :due (readq--date-in 40) :interval 40.0)
      (readq-set-deadline b (readq--date-in 10))
      (should (= (readq--days-until (readq--get b :due)) 5))
      (should (= (readq--get b :interval) 5))
      ;; A session reschedules within the cap, even at low priority.
      (readq-set-priority b 100)
      (readq--put b :interval 30.0)
      (readq--count-session b 20 0.2 600)
      (should (<= (readq--days-until (readq--get b :due)) 5)))))

;;;; Tags

(ert-deftest readq-dltest-tag-deadline ()
  (readq-dltest--with-db
    (let* ((a (readq-dltest--pdf "Cardio A" 100 0 50 '("cardio")))
           (b (readq-dltest--pdf "Cardio B" 200 100 50 '("cardio")))
           (other (readq-dltest--pdf "Novel" 100 0 50 '("leisure")))
           (c (readq-dltest--pdf "Big book" 1000 0 50 '("cardio")))
           (sec (readq--make-section c (list :title "Heart" :start 101 :end 200) 30))
           (x (readq-dltest--pdf "Extract" 10 0 50)))
      ;; An extract of a cardio book: no deadline for it.
      (readq--put x :format 'extract :book (readq--get a :id))
      (readq--put c :status 'paused)
      (readq-set-tag-deadline "#Cardio" (readq--date-in 20))
      (should (equal readq--tag-deadlines `(("cardio" . ,(readq--date-in 20)))))
      (should (equal (readq--effective-deadline a) (cons (readq--date-in 20) "cardio")))
      (should-not (readq--effective-deadline other))
      (should-not (readq--effective-deadline x))
      ;; The section inherits the tag; its paused book is skipped.
      (should (readq--effective-deadline sec))
      (should (equal (readq-wtest--titles (readq--deadline-items "cardio"))
                     '("Cardio A" "Cardio B" "Big book › Heart")))
      (should (= (plist-get (readq--deadline-info sec) :remaining) 100))
      ;; An active book with active sections is read through them.
      (readq--put c :status 'active)
      (should-not (readq--effective-deadline c))
      ;; The earliest deadline wins.
      (readq--put a :deadline (readq--date-in 5))
      (should (equal (readq--effective-deadline a) (cons (readq--date-in 5) nil)))
      (readq--put b :deadline (readq--date-in 30))
      (should (equal (cdr (readq--effective-deadline b)) "cardio"))
      ;; Saved with the database.
      (readq--save)
      (setq readq--books nil readq--loaded nil readq--tag-deadlines nil)
      (readq--books)
      (should (equal readq--tag-deadlines `(("cardio" . ,(readq--date-in 20)))))
      ;; Clearing it.
      (readq-set-tag-deadline "cardio" nil)
      (should-not readq--tag-deadlines))))

;;;; The daily budget

(ert-deftest readq-dltest-deadline-wins-budget ()
  (readq-dltest--with-db
    (let* ((books (cl-loop for i below 5
                           collect (readq-dltest--pdf (format "Book %d" i) 100 0 (+ 20 i))))
           (exam (readq-dltest--pdf "Exam book" 100 0 90)))
      (readq--put exam :deadline (readq--date-in 10))
      ;; The deadline item goes first and is kept; it uses the budget too.
      (pcase-let ((`(,keep . ,over) (readq--workload-plan)))
        (should (equal (readq-wtest--titles keep) '("Exam book" "Book 0" "Book 1" "Book 2")))
        (should (equal (readq-wtest--titles over) '("Book 3" "Book 4"))))
      ;; Never spread.
      (readq--log-reading (* 70 60) 3)
      (readq-spread-overflow)
      (should (readq--due-p exam))
      (should-not (cl-some #'readq--due-p books))
      ;; Opened over budget without asking.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (error "Asked"))))
        (should (equal (readq--get (readq-ttest--next) :title) "Exam book")))
      ;; When the budget wins, it goes first but can be moved.
      (let ((readq-deadline-overrides-budget nil))
        (readq--put exam :due (readq--today))
        (should-not (readq--protected-p exam))
        (readq-spread-overflow)
        (should-not (readq--due-p exam))))))

;;;; Showing deadlines

(ert-deftest readq-dltest-forecast-and-messages ()
  (readq-dltest--with-db
    (let ((a (readq-dltest--pdf "Cardio A" 100 0 50 '("cardio")))
          (b (readq-dltest--pdf "Own book" 50 10 50)))
      (readq-set-tag-deadline "cardio" (readq--date-in 20))
      (readq-set-deadline b (readq--date-in 4))
      (let ((lines (readq--deadline-lines)))
        (should (equal (car lines) "Deadlines:"))
        ;; Soonest first.
        (should (string-match-p "^  Own book by .* (4 days left)" (nth 1 lines)))
        (should (string-match-p "^    Own book +40 p left +10 p/day  on track" (nth 2 lines)))
        (should (string-match-p "^  #cardio by .* (20 days left)" (nth 3 lines)))
        (should (string-match-p "^    Cardio A +100 p left +5 p/day  on track" (nth 4 lines))))
      (should (member "Deadlines:" (readq--workload-lines)))
      ;; The message after a session says what is left.
      (let ((msg (readq--report-rescheduled a "Session saved")))
        (should (string-match-p "100 p left of \"Cardio A\" by .* (#cardio): 5 p a day" msg)))
      ;; Dashboard column.
      (readq)
      (should (string-match-p "Deadline" (format "%s" tabulated-list-format)))
      (goto-char (point-min))
      (should (re-search-forward "Own book .* 10 p/d" nil t)))))

(ert-deftest readq-dltest-read-deadline ()
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
    (should-not (readq--read-deadline "Finish by")))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "2026-12-01")))
    (should (equal (readq--read-deadline "Finish by") "2026-12-01")))
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "+3w")))
    (should (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}$"
                            (readq--read-deadline "Finish by")))))

(provide 'readq-deadline-test)
;;; readq-deadline-test.el ends here
