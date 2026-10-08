;;; readq-stats-test.el --- Tests for readq reading stats -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-stats-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-statest-now (readq-test--now "2026-10-08"))

(defun readq-statest--session (item date from to minutes)
  "Add a session of MINUTES on DATE from page FROM to TO to ITEM."
  (readq--put item :history (cons (list :date date :from-page from :to-page to
                                        :seconds (* 60 minutes))
                                  (readq--get item :history))))

(defun readq-statest--log (date minutes items)
  "Log MINUTES and ITEMS on DATE."
  (push (list date :seconds (* 60 minutes) :items items) readq--log)
  (setq readq--log (sort readq--log (lambda (a b) (string< (car b) (car a))))))

(defmacro readq-statest--with-books (&rest body)
  "Run BODY with books `heart' (#cardio) and `kidney' (#renal)."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((heart (readq-add-book (readq-test--touch "heart.pdf") 20 "Heart" '("cardio")))
            (kidney (readq-add-book (readq-test--touch "kidney.pdf") 30 "Kidney" '("renal"))))
       (ignore heart kidney)
       ,@body)))

(ert-deftest readq-statest-day-minutes ()
  (readq-statest--with-books
    ;; A logged day uses the log; an older one adds up its sessions.
    (readq-statest--log "2026-10-08" 40 3)
    (readq-statest--session heart "2026-10-08" 1 5 25)
    (readq-statest--session heart "2026-10-06" 5 9 20)
    (readq-statest--session kidney "2026-10-06" 1 3 10)
    (should (equal (readq--stats-day-minutes readq-statest-now 3)
                   '(("2026-10-06" . 30.0) ("2026-10-07" . 0) ("2026-10-08" . 40.0))))))

(ert-deftest readq-statest-streaks ()
  (readq-statest--with-books
    (dolist (d '("2026-09-20" "2026-09-21" "2026-09-22" "2026-09-23"
                 "2026-10-05" "2026-10-06" "2026-10-07"))
      (readq-statest--log d 30 2))
    ;; Nothing read today yet: the streak runs to yesterday.
    (should (equal (readq--stats-streaks readq-statest-now) '(3 . 4)))
    (readq-statest--log "2026-10-08" 10 1)
    (should (equal (readq--stats-streaks readq-statest-now) '(4 . 4)))
    ;; Less than a minute doesn't count.
    (should (equal (readq--stats-streaks (readq-test--now "2026-10-10")) '(0 . 4)))))

(ert-deftest readq-statest-period ()
  (readq-statest--with-books
    (readq-statest--session heart "2026-10-08" 10 22 30)
    (readq-statest--session heart "2026-10-07" 1 10 20)
    (readq-statest--session kidney "2026-10-07" 5 5 15)
    ;; Outside the period.
    (readq-statest--session kidney "2026-09-01" 1 50 60)
    (let ((x (readq--create-extract heart "Systole." :page 12)))
      (readq--put x :added "2026-10-07")
      (let ((y (readq--create-extract heart "Diastole." :page 13)))
        (readq--put y :added "2026-10-08" :status 'finished
                    :exported (list :date "2026-10-08" :backend 'anki))))
    (readq--put kidney :status 'finished :finished-on "2026-10-06")
    (let ((p (readq--stats-period readq-statest-now 7)))
      (should (= (plist-get p :minutes) 65))
      (should (= (plist-get p :sessions) 3))
      (should (= (plist-get p :pages) 21))
      (should (= (plist-get p :days-read) 2))
      (should (= (plist-get p :extracts) 2))
      (should (= (plist-get p :cards) 1))
      (should (equal (plist-get p :finished) (list kidney)))
      (let ((books (plist-get p :books)))
        (should (eq (car (nth 0 books)) heart))
        (should (= (plist-get (cdr (nth 0 books)) :seconds) 3000))
        (should (= (plist-get (cdr (nth 0 books)) :pages) 21))
        (should (= (plist-get (cdr (nth 0 books)) :extracts) 2))
        (should (= (plist-get (cdr (nth 1 books)) :sessions) 1)))
      (should (equal (plist-get p :tags) '(("cardio" . 3000) ("renal" . 900)))))))

(ert-deftest readq-statest-report ()
  (readq-statest--with-books
    (readq-statest--log "2026-10-07" 45 2)
    (readq-statest--log "2026-10-08" 30 1)
    (readq-statest--session heart "2026-10-08" 10 22 30)
    (let ((text (mapconcat #'identity (readq--stats-lines 7 readq-statest-now) "\n")))
      (should (string-match-p "Reading, last 7 days" text))
      (should (string-match-p "Streak +2 days in a row" text))
      (should (string-match-p "Time +1h15m, on 2 of 7 days" text))
      (should (string-match-p "Thu 10-08 █+ 30m" text))
      (should (string-match-p "^  Heart " text))
      (should (string-match-p "#cardio" text)))
    ;; A year groups the bars by month.
    (let ((text (mapconcat #'identity (readq--stats-lines 365 readq-statest-now) "\n")))
      (should (string-match-p "^  2026-10 " text))
      (should (string-match-p "^  2025-10 " text)))))

(ert-deftest readq-statest-command ()
  (readq-statest--with-books
    (save-window-excursion
      (readq-stats 7)
      (should (derived-mode-p 'readq-stats-mode))
      (should (= readq--stats-days 7))
      (should (string-match-p "last 7 days" (buffer-string)))
      (readq-stats 365)
      (should (string-match-p "last 365 days" (buffer-string)))
      (revert-buffer)
      (should (string-match-p "last 365 days" (buffer-string))))
    (kill-buffer "*readq stats*")))

(ert-deftest readq-statest-finished-on ()
  (readq-statest--with-books
    (readq-toggle-finished heart)
    (should (equal (readq--get heart :finished-on) (readq--today)))
    (readq-toggle-finished heart)
    (should-not (readq--get heart :finished-on))))

(ert-deftest readq-statest-log-keeps-a-year ()
  (readq-statest--with-books
    (dotimes (i 450)
      (readq--log-reading 60 1 (time-add readq-statest-now (days-to-time i))))
    (should (= (length readq--log) 401))))

(provide 'readq-stats-test)
;;; readq-stats-test.el ends here
