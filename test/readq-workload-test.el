;;; readq-workload-test.el --- Tests for readq's daily budget -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-workload-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-tags-test)

(defmacro readq-wtest--with-books (n &rest body)
  "Run BODY with N due PDF books of priority 20, 21, ...; bound to `books'.
The budget is 60 minutes, no item limit, spread mode, priority 10 and
below protected."
  (declare (indent 1))
  `(readq-xtest--with-db
     (let* ((readq-daily-minutes 60)
            (readq-daily-items nil)
            (readq-workload-overflow 'spread)
            (readq-workload-stop 'ask)
            (readq-workload-protected-priority 10)
            (readq-default-book-minutes 15)
            (readq-default-extract-minutes 2)
            (books (cl-loop for i below ,n
                            collect (readq-add-book
                                     (readq-test--touch (format "b%02d.pdf" i))
                                     (+ 20 i) (format "Book %02d" i)))))
       (ignore books)
       ,@body)))

(defun readq-wtest--titles (items)
  "Return the titles of ITEMS."
  (mapcar (lambda (b) (readq--get b :title)) items))

(defun readq-wtest--session (book secs &optional date)
  "Record a session of SECS seconds in BOOK's history on DATE."
  (readq--put book :history (cons (list :date (or date (readq--today)) :seconds secs)
                                  (readq--get book :history))))

;;;; Estimates and the log

(ert-deftest readq-wtest-estimate ()
  (readq-wtest--with-books 1
    (let ((b (car books)))
      (should (= (readq--estimate-minutes b) 15))
      ;; The median of the last sessions, ignoring untimed ones.
      (readq-wtest--session b 600)
      (readq-wtest--session b 0)
      (readq-wtest--session b 1200)
      (readq-wtest--session b 300)
      (should (= (readq--estimate-minutes b) 10))
      (readq-wtest--session b 1500)
      (should (= (readq--estimate-minutes b) 15))
      ;; Only the last `readq-workload-estimate-sessions' count.
      (let ((readq-workload-estimate-sessions 1))
        (should (= (readq--estimate-minutes b) 25))))
    (let ((x (list :format 'extract :history nil)))
      (should (= (readq--estimate-minutes x) 2)))))

(ert-deftest readq-wtest-log-saved ()
  (readq-wtest--with-books 1
    (readq--log-reading 300 0)
    (readq--log-reading 120 1)
    (should (equal (readq--done-today) '(7.0 . 1)))
    (should (equal (readq--budget-string) "7/60 min"))
    (readq--save)
    (setq readq--books nil readq--loaded nil readq--log nil)
    (should (equal (readq--done-today) '(7.0 . 1)))
    ;; Other days don't count for today.
    (readq--log-reading 600 2 (time-add nil (* -86400 1)))
    (should (equal (readq--done-today) '(7.0 . 1)))))

(ert-deftest readq-wtest-sessions-are-logged ()
  ;; A book session logs its time and counts one item.
  (readq-ftest--with-db
    (let ((book (readq-add-book (readq-ftest--write "notes.org" readq-ftest--org) 20)))
      (readq-open book)
      (setq readq--session-seconds 240)
      (goto-char (point-max))
      (readq-finish-session)
      (should (equal (readq--done-today) '(4.0 . 1))))))

(ert-deftest readq-wtest-extract-review-is-timed ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "notes.org" readq-ftest--org) 20))
           (x (readq--create-extract book "The heart pumps blood." :point 40)))
      (should (readq--open-extract x))
      (should (= readq--session-seconds 0))
      ;; The timer counts time spent in the review buffer.
      (cl-letf (((symbol-function 'window-buffer) (lambda (&rest _) (current-buffer)))
                ((symbol-function 'current-idle-time) (lambda () nil)))
        (readq--tick) (readq--tick))
      (should (= readq--session-seconds (* 2 readq-tick-interval)))
      (readq--finish-review t)
      (should (= (plist-get (car (readq--get x :history)) :seconds)
                 (* 2 readq-tick-interval)))
      (should (= (readq--get x :seconds) (* 2 readq-tick-interval)))
      ;; The book's own reading time is untouched.
      (should (= (or (readq--get book :seconds) 0) 0))
      (should (equal (readq--done-today) (cons (/ (* 2 readq-tick-interval) 60.0) 1))))))

;;;; Today's plan

(ert-deftest readq-wtest-plan ()
  (readq-wtest--with-books 6
    ;; 60 minutes, 15 each: four fit.
    (pcase-let ((`(,keep . ,over) (readq--workload-plan)))
      (should (equal (readq-wtest--titles keep) '("Book 00" "Book 01" "Book 02" "Book 03")))
      (should (equal (readq-wtest--titles over) '("Book 04" "Book 05"))))
    ;; Time read today counts.
    (readq--log-reading (* 40 60) 2)
    (should (= (length (car (readq--workload-plan))) 2))
    ;; A protected item is kept even over budget.
    (readq--log-reading (* 30 60) 0)
    (readq-set-priority (nth 5 books) 5)
    (should (equal (readq-wtest--titles (car (readq--workload-plan))) '("Book 05")))
    (should (readq--budget-used-up-p))
    ;; Without a budget everything is kept.
    (let ((readq-daily-minutes nil))
      (should (= (length (car (readq--workload-plan))) 6))
      (should-not (readq--budget-used-up-p)))))

(ert-deftest readq-wtest-item-limit ()
  (readq-wtest--with-books 5
    (let ((readq-daily-minutes nil) (readq-daily-items 2))
      (should (= (length (car (readq--workload-plan))) 2))
      (should (equal (readq--budget-string) "0/2 items"))
      ;; Both limits: the stricter one wins.
      (let ((readq-daily-minutes 20))
        (should (= (length (car (readq--workload-plan))) 2))
        (should (equal (readq--budget-string) "0/20 min, 0/2 items")))
      (let ((readq-daily-minutes 10))
        (should (= (length (car (readq--workload-plan))) 1))))))

;;;; Spreading the overflow

(ert-deftest readq-wtest-spread ()
  (readq-wtest--with-books 11
    (readq-set-priority (nth 10 books) 0)
    (should (= (readq-spread-overflow) 7))
    ;; Today: the protected book (which uses the budget too) and the
    ;; three most important others.
    (should (equal (readq-wtest--titles (cl-remove-if-not #'readq--due-p books))
                   '("Book 00" "Book 01" "Book 02" "Book 10")))
    ;; Then four a day, most important first.
    (should (equal (mapcar (lambda (b) (readq--days-until (readq--get b :due)))
                           (cl-subseq books 3 10))
                   '(1 1 1 1 2 2 2)))
    ;; Intervals are unchanged.
    (should (cl-every (lambda (b) (= (readq--get b :interval) readq-initial-interval)) books))
    (should (equal readq--spread-date (readq--today)))
    ;; Items already due tomorrow take room there.
    (should (= (readq-spread-overflow) 0))))

(ert-deftest readq-wtest-spread-around-existing-load ()
  (readq-wtest--with-books 6
    (let ((later (readq-add-book (readq-test--touch "later.pdf") 50 "Later")))
      (readq--put later :due (readq--date-in 1))
      (readq--put (readq-add-book (readq-test--touch "later2.pdf") 50) :due (readq--date-in 1))
      (readq--put (readq-add-book (readq-test--touch "later3.pdf") 50) :due (readq--date-in 1))
      (readq-spread-overflow)
      ;; Tomorrow had 45 minutes: room for one more.
      (should (= (readq--days-until (readq--get (nth 4 books) :due)) 1))
      (should (= (readq--days-until (readq--get (nth 5 books) :due)) 2)))))

(ert-deftest readq-wtest-spread-once-a-day ()
  (readq-wtest--with-books 6
    (should (equal (readq-wtest--titles (list (readq-ttest--next))) '("Book 00")))
    (should (= (cl-count-if #'readq--due-p books) 4))
    ;; Moving a book back to today: not spread again the same day.
    (readq--put (nth 5 books) :due (readq--today))
    (readq-ttest--next)
    (should (readq--due-p (nth 5 books)))
    ;; Hold mode never changes due dates.
    (let ((readq-workload-overflow 'hold))
      (setq readq--spread-date nil)
      (readq-ttest--next)
      (should (readq--due-p (nth 5 books))))))

;;;; Stopping when the budget is used up

(ert-deftest readq-wtest-next-stops ()
  (readq-wtest--with-books 3
    (let ((readq-workload-overflow 'hold))
      (readq--log-reading (* 61 60) 4)
      (let (question)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (setq question q) nil)))
          (should-not (readq-ttest--next)))
        (should (string-match-p "budget is used up (61/60 min)" question)))
      ;; Yes: keep reading, and don't ask again today.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (should (equal (readq--get (readq-ttest--next) :title) "Book 00")))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (error "Asked again"))))
        (should (readq-ttest--next)))
      ;; Protected items open without asking.
      (setq readq--budget-override nil)
      (readq-set-priority (nth 2 books) 3)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (error "Asked"))))
        (should (equal (readq--get (readq-ttest--next) :title) "Book 02")))
      ;; With `readq-workload-stop' nil it never asks.
      (let ((readq-workload-stop nil))
        (readq-set-priority (nth 2 books) 50)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (error "Asked"))))
          (should (readq-ttest--next)))))))

;;;; Dashboard and forecast

(ert-deftest readq-wtest-dashboard-and-forecast ()
  (readq-wtest--with-books 6
    (readq--log-reading (* 20 60) 1)
    (should (string-match-p "today 20/60 min" (readq--dashboard-summary)))
    (readq--put (nth 5 books) :due (readq--date-in 2))
    (readq--put (nth 4 books) :due (readq--date-in 2))
    (let ((readq-workload-overflow 'hold))
      (readq-workload))
    (with-current-buffer "*readq workload*"
      (should (derived-mode-p 'readq-workload-mode))
      (let ((text (buffer-string)))
        (should (string-match-p "Budget: 60 min per day.  Over budget: held back" text))
        ;; Today: 20 read plus 3 of the 4 due books.  The last one that
        ;; starts within the budget may run over it.
        (should (string-match-p "^Today .* 65 min    4 items .*20 min read, 1 more due but over budget"
                                text))
        (should (string-match-p (concat "^" (regexp-quote (format-time-string
                                                           "%a %d %b" (readq--date-noon (readq--date-in 2)))))
                                text))
        (should (= (length (split-string text "\n" t)) (+ 2 readq-workload-forecast-days)))))
    (kill-buffer "*readq workload*")
    ;; Over-budget days are highlighted.
    (dotimes (i 5) (readq--put (nth i books) :due (readq--date-in 1)))
    (let ((line (nth 2 (readq--workload-lines))))
      (should (eq (get-text-property 0 'face line) 'readq-over-budget-face)))))

(ert-deftest readq-wtest-mpv-script-creates-directory ()
  (readq-test--with-db
    (let ((user-emacs-directory (expand-file-name "fresh-emacs-d/" readq-test--dir)))
      (should (file-exists-p (readq--mpv-script-file))))))

(provide 'readq-workload-test)
;;; readq-workload-test.el ends here
