;;; readq-test.el --- Tests for readq -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -l test/readq-test.el -f ert-run-tests-batch-and-exit
;; nov.el integration tests run when nov is on the load path.

;;; Code:

(require 'ert)
(require 'readq)

(defvar readq-test--dir nil)

(defmacro readq-test--with-db (&rest body)
  "Run BODY with a fresh, empty readq database in a temp directory."
  (declare (indent 0))
  `(let* ((readq-test--dir (make-temp-file "readq-test" t))
          (readq-db-file (expand-file-name "readq.eld" readq-test--dir))
          (readq-figures-directory (expand-file-name "figures/" readq-test--dir))
          (readq--books nil)
          (readq--loaded nil)
          (readq--dirty nil)
          (readq--db-stamp nil)
          (readq--db-change-warned nil)
          (readq--overwrite-ok nil)
          (readq--log nil)
          (readq--spread-date nil)
          (readq--subset nil)
          (readq-extracts-directory (expand-file-name "extracts" readq-test--dir))
          (readq--tag-deadlines nil)
          (readq--budget-override nil))
     (unwind-protect (progn ,@body)
       (when readq-mode (readq-mode -1))
       (dolist (b (buffer-list))
         (when (buffer-local-value 'readq-book-mode b)
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory readq-test--dir t))))

;; Helpers for the notes of extracts.

(defun readq-test--note (item)
  "Return the contents of the note file of extract ITEM."
  (with-temp-buffer
    (insert-file-contents (readq--extract-file item))
    (buffer-string)))

(defun readq-test--edit-note (item fn)
  "Call FN at the start of the text of extract ITEM's note, then save."
  (with-current-buffer (find-file-noselect (readq--extract-file item))
    (widen)
    (goto-char (readq--note-body-start))
    (funcall fn)
    (let ((save-silently t)) (save-buffer))))

(defun readq-test--retitle (item title)
  "Change the title line of extract ITEM's note to TITLE, as you would by hand."
  (readq-test--edit-note item (lambda () (readq--note-set "title" title))))

(defun readq-test--touch (name)
  "Create an empty file NAME in the test directory and return its path."
  (let ((f (expand-file-name name readq-test--dir)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert "x"))
    f))

(defun readq-test--now (date)
  "Return a time value for 10:00 on DATE (YYYY-MM-DD)."
  (pcase-let ((`(,y ,m ,d) (mapcar #'string-to-number (split-string date "-"))))
    (encode-time (list 0 0 10 d m y nil -1 nil))))

;;;; Scheduling

(ert-deftest readq-test-afactor ()
  (let ((readq-min-afactor 1.2) (readq-max-afactor 2.5))
    (should (= (readq--afactor 0) 1.2))
    (should (= (readq--afactor 100) 2.5))
    (should (< (abs (- (readq--afactor 50) 1.85)) 1e-9))
    (should (= (readq--afactor -10) 1.2))
    (should (= (readq--afactor 500) 2.5))))

(ert-deftest readq-test-next-interval-bounds ()
  (let ((readq-min-interval 1) (readq-max-interval 60))
    (should (= (readq--next-interval 50 100) 60.0))
    (should (= (readq--next-interval 0.1 0) 1.0))
    (should (> (readq--next-interval 10 100) (readq--next-interval 10 0)))))

(ert-deftest readq-test-dates ()
  (let ((now (readq-test--now "2026-02-27")))
    (should (equal (readq--today now) "2026-02-27"))
    (should (equal (readq--date-in 2 now) "2026-03-01"))
    (should (equal (readq--date-in 0 now) "2026-02-27"))
    (should (= (readq--days-until "2026-03-01" now) 2))
    (should (= (readq--days-until "2026-02-20" now) -7))))

(ert-deftest readq-test-reschedule ()
  ;; Extracts: the interval is multiplied by a factor set by priority.
  (readq-test--with-db
    (let ((now (readq-test--now "2026-10-04"))
          (readq-min-afactor 1.2) (readq-max-afactor 2.5)
          (readq-min-interval 1) (readq-max-interval 60)
          (readq-schedule-fuzz 0))
      (let ((hi (list :format 'extract :priority 0 :interval 10.0 :due "2026-10-04"))
            (lo (list :format 'extract :priority 100 :interval 10.0 :due "2026-10-04")))
        (readq--reschedule hi now)
        (readq--reschedule lo now)
        (should (= (plist-get hi :interval) 12.0))
        (should (equal (plist-get hi :due) "2026-10-16"))
        (should (= (plist-get lo :interval) 25.0))
        (should (equal (plist-get lo :due) "2026-10-29"))))))

(ert-deftest readq-test-books-keep-a-steady-rhythm ()
  (readq-test--with-db
    (let ((now (readq-test--now "2026-10-04"))
          (readq-book-min-interval 1) (readq-book-max-interval 7)
          (readq-schedule-fuzz 0)
          (book (list :format 'pdf :priority 50 :interval 1.0 :due "2026-10-04")))
      (should (eq readq-book-schedule 'steady))
      ;; Session after session, a priority-50 book comes back every 4 days.
      (dotimes (_ 5)
        (readq--reschedule book now)
        (should (= (plist-get book :interval) 4.0))
        (should (equal (plist-get book :due) "2026-10-08")))
      (should (= (readq--steady-interval 0) 1.0))
      (should (= (readq--steady-interval 100) 7.0))
      ;; A session that hardly counted: sooner.
      (readq--reschedule book now nil 0.5)
      (should (equal (plist-get book :due) "2026-10-06"))
      ;; The old way: growing like an extract.
      (let ((readq-book-schedule 'growing)
            (readq-min-afactor 1.2) (readq-max-afactor 2.5))
        (plist-put book :interval 4.0)
        (readq--reschedule book now)
        (should (= (plist-get book :interval) 7.4))))))

(ert-deftest readq-test-late-and-early-reviews ()
  (let ((readq-min-afactor 1.2) (readq-max-afactor 2.5)
        (readq-min-interval 1) (readq-max-interval 60)
        (readq-late-credit 1.0))
    ;; Priority 50: a factor of 1.85.  On time, as before.
    (should (= (readq--next-interval 4.0 50 4) 7.4))
    (should (= (readq--next-interval 4.0 50) 7.4))
    ;; Read after 10 days and not 4: built from the 10 days.
    (should (= (readq--next-interval 4.0 50 10) 18.5))
    ;; Half the lateness, or none of it.
    (let ((readq-late-credit 0.5))
      (should (< (abs (- (readq--next-interval 4.0 50 10) 12.95)) 1e-9)))
    (let ((readq-late-credit 0)) (should (= (readq--next-interval 4.0 50 10) 7.4)))
    ;; Reviewed early: it grows by less; twice on one day, not at all.
    (should (< 20.0 (readq--next-interval 20.0 50 10) (* 20 1.85)))
    (should (= (readq--next-interval 20.0 50 10) (* 20 1.425)))
    (should (= (readq--next-interval 20.0 50 0) 20.0))
    ;; A session of half weight grows the interval half as much.
    (should (= (readq--next-interval 4.0 50 4 0.5) (* 4 1.425)))
    ;; Never past the longest interval.
    (should (= (readq--next-interval 30.0 100 200) 60.0))))

(ert-deftest readq-test-session-weight ()
  (readq-test--with-db
    (let* ((readq-session-weight-floor 0.5)
           (readq-default-book-minutes 20)
           (readq-default-extract-minutes 2)
           (book (readq-add-book (readq-test--touch "a.txt") 50)))
      ;; A new book's usual session is 20 minutes: 10 count in full.
      (should (= (readq--session-weight book 0.0 600) 1.0))
      (should (= (readq--session-weight book 0.0 2400) 1.0))
      (should (= (readq--session-weight book 0.0 450) 0.75))
      (should (= (readq--session-weight book 0.0 30) 0.5))
      ;; Unknown length, or weighing turned off: in full.
      (should (= (readq--session-weight book 0.0 nil) 1.0))
      (let ((readq-session-weight-floor nil))
        (should (= (readq--session-weight book 0.0 30) 1.0)))
      ;; A quick session that advanced as much as usual counts in full.
      (readq--put book :progress 0.3
                  :history (list (list :from 0.1 :to 0.2 :seconds 1200)
                                 (list :from 0.0 :to 0.1 :seconds 1200)))
      (should (= (readq--session-weight book 0.2 30) 1.0))
      (should (= (readq--session-weight book 0.29 30) 0.5)))))

(ert-deftest readq-test-count-session-uses-elapsed-days ()
  (readq-test--with-db
    (let* ((readq-schedule-fuzz 0)
           (readq-min-afactor 1.2) (readq-max-afactor 2.5)
           (book (readq-add-book (readq-test--touch "a.pdf") 50))
           (x (readq--create-extract book "Systole." :page 1 :priority 50)))
      (readq--put x :interval 4.0 :added (readq--date-in -30)
                  :last-read (readq--date-in -10) :due (readq--date-in -6)
                  :overflows 3)
      (should (= (readq--elapsed-days x) 10))
      (readq--count-session x 1 nil 120)
      (should (= (readq--get x :interval) 18.5))
      (should (equal (readq--get x :due) (readq--date-in 18)))
      (should-not (readq--get x :overflows))
      ;; Again the same day: nothing more to gain.
      (readq--count-session x 1 nil 120)
      (should (= (readq--get x :interval) 18.5)))))

(ert-deftest readq-test-balanced-days ()
  (readq-test--with-db
    (let* ((now (readq-test--now "2026-10-04"))
           (readq-schedule-fuzz 0.1)
           (readq-default-book-minutes 15)
           (mk (lambda (name days)
                 (let ((b (readq-add-book (readq-test--touch name) 50)))
                   (readq--put b :due (readq--date-in days now))
                   b)))
           (item (funcall mk "item.txt" 0)))
      ;; Nothing planned: the day asked for.
      (should (= (readq--balanced-days item 20 now) 20))
      ;; Days 18 to 22 are open; 20 and 21 are busy, 19 is the nearest free.
      (funcall mk "b.txt" 20)
      (funcall mk "c.txt" 21)
      (should (= (readq--balanced-days item 20 now) 19))
      (funcall mk "d.txt" 19)
      (should (= (readq--balanced-days item 20 now) 18))
      (funcall mk "e.txt" 18)
      (should (= (readq--balanced-days item 20 now) 22))
      ;; All equally busy: the day asked for.
      (funcall mk "f.txt" 22)
      (should (= (readq--balanced-days item 20 now) 20))
      ;; Short intervals: a day at most from 3 days on, none below.
      (funcall mk "g.txt" 4)
      (should (= (readq--balanced-days item 4 now) 3))
      (funcall mk "h.txt" 2)
      (should (= (readq--balanced-days item 2 now) 2))
      ;; The item's own due date is no load, and 0 turns it off.
      (readq--put item :due (readq--date-in 3 now))
      (funcall mk "i.txt" 5)
      (should (= (readq--balanced-days item 4 now) 3))
      (let ((readq-schedule-fuzz 0))
        (should (= (readq--balanced-days item 20 now) 20))))))

;;;; The store, saving and the dashboard

(ert-deftest readq-test-store-index ()
  (readq-test--with-db
    (let* ((a (readq-add-book (readq-test--touch "a.pdf") 20 "A"))
           (b (readq-add-book (readq-test--touch "b.pdf") 20 "B"))
           (x1 (readq--create-extract a "One." :page 1))
           (x2 (readq--create-extract a "Two." :page 2))
           (sub (readq--create-extract x1 "On")))
      (should (eq (readq--book-by-id (readq--get x2 :id)) x2))
      (should-not (readq--book-by-id "nope"))
      (should-not (readq--book-by-id nil))
      (should (equal (readq--items-of a) (list x1 x2 sub)))
      (should-not (readq--items-of b))
      (should (equal (readq--children-of x1) (list sub)))
      (should (equal (readq--extracts-of a) (list x1 x2 sub)))
      ;; Lookups use the index already built; it is not built again.
      (let ((index (readq--index)))
        (readq--book-by-id (readq--get x1 :id))
        (readq--items-of a)
        (should (eq (readq--index) index)))
      ;; The index follows the queue: items removed, moved or renamed.
      (readq--remove-items (list x2))
      (should-not (readq--book-by-id (readq--get x2 :id)))
      (should (equal (readq--items-of a) (list x1 sub)))
      (readq--put sub :book (readq--get b :id) :parent nil)
      (should (equal (readq--items-of b) (list sub)))
      (should-not (readq--children-of x1))
      (readq--put x1 :id "20200101T000000")
      (should (eq (readq--book-by-id "20200101T000000") x1))
      ;; A queue set from outside, as when the database is read again.
      (setq readq--books (list a))
      (should-not (readq--book-by-id (readq--get b :id)))
      (should (eq (readq--book-by-id (readq--get a :id)) a)))))

(ert-deftest readq-test-save-waits ()
  (readq-test--with-db
    (let ((noninteractive nil)
          (readq-save-delay 30)
          (writes 0))
      (readq-add-book (readq-test--touch "a.pdf") 20 "A")
      (readq--save-now)
      (unwind-protect
          (cl-letf (((symbol-function 'readq--save-now)
                     (let ((orig (symbol-function 'readq--save-now)))
                       (lambda () (setq writes (1+ writes)) (funcall orig)))))
            ;; Several changes close together: one write, later.
            (dotimes (_ 5) (readq--save))
            (should (= writes 0))
            (should readq--dirty)
            (should (timerp readq--save-timer))
            (readq--save-pending)
            (should (= writes 1))
            (should-not readq--dirty)
            (should-not readq--save-timer)
            ;; Nothing waiting: nothing written.
            (readq--save-pending)
            (should (= writes 1))
            ;; No delay: at once.
            (let ((readq-save-delay nil))
              (readq--save)
              (should (= writes 2))))
        (when (timerp readq--save-timer) (cancel-timer readq--save-timer))
        (setq readq--save-timer nil)))))

(ert-deftest readq-test-file-checks-are-remembered ()
  (readq-test--with-db
    (let* ((readq-file-check-seconds 30)
           (book (readq-add-book (readq-test--touch "a.pdf") 20 "A"))
           (file (readq--get book :file))
           (looks 0))
      (clrhash readq--file-checks)
      (cl-letf (((symbol-function 'file-exists-p)
                 (let ((orig (symbol-function 'file-exists-p)))
                   (lambda (f) (when (equal f file) (setq looks (1+ looks)))
                     (funcall orig f)))))
        (dotimes (_ 5) (should-not (readq--missing-p book)))
        (should (= looks 1))
        ;; Relocating a book forgets what was seen.
        (readq--put book :file (readq-test--touch "moved.pdf"))
        (readq--put book :file file)
        (should-not (readq--missing-p book))
        (should (= looks 2))
        ;; 0: always look.
        (let ((readq-file-check-seconds 0))
          (delete-file file)
          (should (readq--missing-p book)))))))

(ert-deftest readq-test-history-is-trimmed ()
  (let* ((now (readq-test--now "2026-10-04"))
         (readq-history-days 400) (readq-history-length 3)
         (entry (lambda (date) (list :date date :from-page nil :to-page nil
                                     :from nil :to nil :seconds 60)))
         (history (mapcar entry '("2026-10-01" "2026-09-01" "2025-12-01"
                                  "2025-08-01" "2024-01-01" "2023-01-01"))))
    ;; Within 400 days, and the newest 3 whatever their age.
    (should (equal (mapcar (lambda (h) (plist-get h :date))
                           (readq--trimmed-history history now))
                   '("2026-10-01" "2026-09-01" "2025-12-01")))
    (let ((readq-history-length 5))
      (should (= (length (readq--trimmed-history history now)) 5)))
    ;; Empty fields are not kept.
    (should (equal (car (readq--trimmed-history history now))
                   '(:date "2026-10-01" :seconds 60)))))

(ert-deftest readq-test-old-database-is-upgraded ()
  (readq-test--with-db
    (let ((readq-history-length 2) (readq-history-days 400)
          (old (lambda (date) (list :date date :from nil :to nil :seconds 60))))
      (with-temp-file readq-db-file
        (prin1 (list :version 1 :focus nil :log nil
                     :books (list (list :id "a" :title "A" :file "/tmp/a.pdf" :format 'pdf
                                        :priority 20 :status 'active :due "2026-01-01"
                                        :history (mapcar old '("2020-03-01" "2020-02-01"
                                                               "2020-01-01")))))
               (current-buffer)))
      (setq readq--books nil readq--loaded nil)
      (let ((book (car (readq--books))))
        (should (equal (readq--get book :history)
                       '((:date "2020-03-01" :seconds 60) (:date "2020-02-01" :seconds 60))))
        ;; The upgrade is written the next time the database is.
        (should readq--dirty)
        (readq--save-now)
        (should (= (plist-get (readq--read-db-file readq-db-file) :version)
                   readq--db-version))
        (setq readq--books nil readq--loaded nil)
        (readq--books)
        (should-not readq--dirty)))))

(ert-deftest readq-test-dashboard-is-redrawn-once ()
  (readq-test--with-db
    (let ((book (readq-add-book (readq-test--touch "a.txt") 20 "Alpha"))
          (prints 0))
      (save-window-excursion
        (readq)
        (unwind-protect
            (let ((readq-dashboard-lazy t))
              (cl-letf (((symbol-function 'readq--dashboard-print)
                         (let ((orig (symbol-function 'readq--dashboard-print)))
                           (lambda () (setq prints (1+ prints)) (funcall orig)))))
                ;; On screen: several changes, one redraw after the command.
                (dotimes (_ 4) (readq--refresh-dashboard))
                (should (= prints 0))
                (should (timerp readq--dashboard-timer))
                (readq--dashboard-flush)
                (should (= prints 1))
                (should-not readq--dashboard-timer)
                ;; Not on screen: nothing until it is shown again.
                (switch-to-buffer (get-buffer-create "*elsewhere*"))
                (readq--put book :title "Beta")
                (readq--refresh-dashboard)
                (should-not readq--dashboard-timer)
                (should (= prints 1))
                (with-current-buffer "*readq*"
                  (should-not (string-match-p "Beta" (buffer-string))))
                (switch-to-buffer "*readq*")
                (readq--dashboard-shown)
                (should (= prints 2))
                (should (string-match-p "Beta" (buffer-string)))))
          (when (timerp readq--dashboard-timer) (cancel-timer readq--dashboard-timer))
          (setq readq--dashboard-timer nil)
          (kill-buffer "*readq*")
          (when (get-buffer "*elsewhere*") (kill-buffer "*elsewhere*")))))))

;;;; Queue

(ert-deftest readq-test-queue-order ()
  (readq-test--with-db
    (let* ((now (readq-test--now "2026-10-04"))
           (mk (lambda (name pri due &optional status)
                 (let ((b (readq--make-book (readq-test--touch name) pri name)))
                   (readq--put b :due due :status (or status 'active))
                   (setq readq--books (append readq--books (list b)))
                   b)))
           (due-low (funcall mk "a.pdf" 80 "2026-10-01"))
           (due-high (funcall mk "b.pdf" 10 "2026-10-04"))
           (due-high-older (funcall mk "c.epub" 10 "2026-09-30"))
           (later-soon (funcall mk "d.pdf" 5 "2026-10-05"))
           (later-far (funcall mk "e.pdf" 1 "2026-11-01"))
           (_paused (funcall mk "f.pdf" 0 "2026-10-01" 'paused))
           (_finished (funcall mk "g.pdf" 0 "2026-10-01" 'finished))
           (missing (funcall mk "h.pdf" 0 "2026-10-01")))
      (setq readq--loaded t)
      (delete-file (readq--get missing :file))
      (should (equal (readq--queue nil now)
                     (list due-high-older due-high due-low later-soon later-far)))
      (should (readq--due-p due-low now))
      (should-not (readq--due-p later-soon now)))))

(ert-deftest readq-test-randomization-keeps-due-first ()
  (readq-test--with-db
    (let ((now (readq-test--now "2026-10-04"))
          (readq-randomization 1.0))
      (dotimes (i 6)
        (let ((b (readq--make-book (readq-test--touch (format "b%d.pdf" i))
                                   (* i 20) "x")))
          (readq--put b :due (if (cl-evenp i) "2026-10-04" "2026-10-09"))
          (setq readq--books (append readq--books (list b)))))
      (setq readq--loaded t)
      (dotimes (_ 20)
        (let ((q (readq--queue t now)))
          (should (cl-every (lambda (b) (readq--due-p b now)) (cl-subseq q 0 3)))
          (should (cl-notany (lambda (b) (readq--due-p b now)) (cl-subseq q 3))))))))

;;;; Database

(ert-deftest readq-test-add-save-load ()
  (readq-test--with-db
    (let* ((f (readq-test--touch "My_Great-Book.epub"))
           (book (readq-add-book f 30)))
      (should (equal (readq--get book :title) "My Great Book"))
      (should (eq (readq--get book :format) 'epub))
      (should (equal (readq--get book :due) (readq--today)))
      (should-error (readq-add-book f 10) :type 'user-error)
      (should-error (readq-add-book (readq-test--touch "notes.docx") 10) :type 'user-error)
      (readq--put book :page 3 :progress 0.25)
      (readq--save)
      (setq readq--books nil readq--loaded nil)
      (let ((loaded (readq--book-by-file f)))
        (should loaded)
        (should (equal (readq--get loaded :page) 3))
        (should (equal (readq--get loaded :title) "My Great Book"))
        (should (eq (readq--get loaded :status) 'active))))))

(ert-deftest readq-test-add-directory ()
  (readq-test--with-db
    (readq-test--touch "lib/a.pdf")
    (readq-test--touch "lib/sub/b.EPUB")
    (readq-test--touch "lib/sub/c.docx")
    (readq-add-book (expand-file-name "lib/a.pdf" readq-test--dir) 5)
    (should (= (readq-add-directory (expand-file-name "lib" readq-test--dir) 40) 1))
    (should (= (length (readq--books)) 2))))

(ert-deftest readq-test-pdf-page-count ()
  (skip-unless (and (executable-find "gs") (executable-find "pdfinfo")))
  (readq-test--with-db
    (let ((f (expand-file-name "five.pdf" readq-test--dir)))
      (call-process "gs" nil nil nil "-q" "-sDEVICE=pdfwrite" "-o" f
                    "-c" "1 1 5 {pop showpage} for")
      (should (= (readq--get (readq-add-book f 50) :total) 5)))))

;;;; Progress

(ert-deftest readq-test-progress ()
  (should (= (readq--progress-from 'pdf 50 nil nil 200) 0.25))
  (should (= (readq--progress-from 'pdf 200 nil nil 200) 1.0))
  (should (null (readq--progress-from 'pdf 5 nil nil nil)))
  ;; chapter index 1 of 4, halfway through it
  (should (= (readq--progress-from 'epub 1 51 101 4) 0.375))
  (should (= (readq--progress-from 'epub 0 1 1 4) 0.0)))

;;;; Page-based buffers (pdf-view-mode is mocked)

(defvar-local readq-test--page 1)
(unless (fboundp 'pdf-view-mode)
  (define-derived-mode pdf-view-mode special-mode "PDFView"))

(defmacro readq-test--with-fake-pdf-tools (&rest body)
  "Run BODY with pdf-tools' page functions mocked."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'image-mode-window-get)
              (lambda (prop &optional _w) (and (eq prop 'page) readq-test--page)))
             ((symbol-function 'pdf-cache-number-of-pages) (lambda (&rest _) 100))
             ((symbol-function 'pdf-view-goto-page)
              (lambda (p &optional _w) (setq readq-test--page p))))
     (unwind-protect (progn ,@body)
       ;; Kill fake PDF buffers while the mocks still exist.
       (dolist (b (buffer-list))
         (when (buffer-local-value 'readq-book-mode b)
           (kill-buffer b))))))

(defun readq-test--run-timers ()
  "Let pending timers run."
  (accept-process-output nil 0.05))

(ert-deftest readq-test-pdf-session ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((f (readq-test--touch "book.pdf"))
             (book (readq-add-book f 20))
             (auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist)))
        (readq-mode 1)
        ;; First session: read from page 1 to page 30.
        (readq-open book)
        (should (eq major-mode 'pdf-view-mode))
        (should readq-book-mode)
        (setq readq-test--page 30)
        (readq--record-position)
        (should (= (readq--get book :page) 30))
        (should (= (readq--get book :total) 100))
        (should (= (readq--get book :progress) 0.3))
        (readq-finish-session)
        (should (= (readq--get book :sessions) 1))
        (should (string< (readq--today) (readq--get book :due)))
        (kill-buffer (current-buffer))
        ;; Killing right after finishing must not count a second session.
        (should (= (readq--get book :sessions) 1))
        ;; Reopen: position is restored, and the jump is not a reading session.
        (readq-open book)
        (readq-test--run-timers)
        (should (= readq-test--page 30))
        (should-not readq--restoring)
        (kill-buffer (current-buffer))
        (should (= (readq--get book :sessions) 1))
        ;; Moving and then killing the buffer counts as a session.
        (readq-open book)
        (readq-test--run-timers)
        (setq readq-test--page 42)
        (kill-buffer (current-buffer))
        (should (= (readq--get book :sessions) 2))
        (should (= (readq--get book :page) 42))
        (should (equal (plist-get (car (readq--get book :history)) :from-page) 30))
        ;; The database on disk has the update.
        (setq readq--books nil readq--loaded nil)
        (should (= (readq--get (readq--book-by-file f) :page) 42))))))

(ert-deftest readq-test-next-picks-highest-priority-due ()
  (readq-test--with-db
    (readq-test--with-fake-pdf-tools
      (let* ((auto-mode-alist (cons '("\\.pdf\\'" . pdf-view-mode) auto-mode-alist))
             (a (readq-add-book (readq-test--touch "a.pdf") 50))
             (b (readq-add-book (readq-test--touch "b.pdf") 10))
             (c (readq-add-book (readq-test--touch "c.pdf") 30)))
        (readq-mode 1)
        (readq-next)
        (should (eq (readq--buffer-book) b))
        (setq readq-test--page 5)
        (readq-next)                    ; finishes b, opens c
        (should (eq (readq--buffer-book) c))
        (should-not (readq--due-p b))
        (readq-next)                    ; finishes c, opens a
        (should (eq (readq--buffer-book) a))
        ;; nothing due after a: decline reading ahead
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
          (readq-next))
        (should (eq (readq--buffer-book) a))
        (should (= 0 (cl-count-if #'readq--due-p (readq--books))))))))

(ert-deftest readq-test-dashboard ()
  (readq-test--with-db
    (readq-add-book (readq-test--touch "a.pdf") 50 "Alpha")
    (readq-toggle-finished (readq-add-book (readq-test--touch "b.pdf") 10 "Beta"))
    (readq)
    (should (eq major-mode 'readq-dashboard-mode))
    (should (string-match-p "Alpha" (buffer-string)))
    (should-not (string-match-p "Beta" (buffer-string)))
    (readq-dashboard-toggle-finished)
    (should (string-match-p "Beta" (buffer-string)))
    (goto-char (point-min))
    (search-forward "Alpha")
    (readq-priority-up (readq--target-book))
    (should (= (readq--get (readq--book-by-file (expand-file-name "a.pdf" readq-test--dir))
                           :priority)
               45))
    (kill-buffer "*readq*")))

;;;; EPUB with the real nov.el

(defun readq-test--make-epub (file chapters)
  "Write a minimal EPUB to FILE with CHAPTERS (a list of strings)."
  (let ((dir (make-temp-file "epub" t)))
    (unwind-protect
        (let ((write (lambda (name content)
                       (let ((p (expand-file-name name dir)))
                         (make-directory (file-name-directory p) t)
                         (with-temp-file p (insert content))))))
          (funcall write "mimetype" "application/epub+zip")
          (funcall write "META-INF/container.xml"
                   "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>")
          (let ((n 0) manifest spine)
            (dolist (text chapters)
              (cl-incf n)
              (funcall write (format "OEBPS/ch%d.xhtml" n)
                       (format "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>C%d</title></head><body><h1>Chapter %d</h1><p>%s</p></body></html>" n n text))
              (push (format "<item id=\"ch%d\" href=\"ch%d.xhtml\" media-type=\"application/xhtml+xml\"/>" n n) manifest)
              (push (format "<itemref idref=\"ch%d\"/>" n) spine))
            (funcall write "OEBPS/toc.ncx"
                     "<?xml version=\"1.0\"?><ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head/><docTitle><text>T</text></docTitle><navMap><navPoint id=\"n1\" playOrder=\"1\"><navLabel><text>Chapter 1</text></navLabel><content src=\"ch1.xhtml\"/></navPoint></navMap></ncx>")
            (funcall write "OEBPS/content.opf"
                     (format "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Test Book</dc:title><dc:identifier id=\"id\">readq-test-book</dc:identifier><dc:language>en</dc:language></metadata><manifest><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>%s</manifest><spine toc=\"ncx\">%s</spine></package>"
                             (apply #'concat (nreverse manifest))
                             (apply #'concat (nreverse spine)))))
          (let ((default-directory dir))
            (call-process "zip" nil nil nil "-X0q" (expand-file-name file) "mimetype")
            (call-process "zip" nil nil nil "-Xrq" (expand-file-name file) "META-INF" "OEBPS")))
      (delete-directory dir t))))

(ert-deftest readq-test-nov-session ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-test--with-db
    (let* ((nov-save-place-file nil)
           (f (expand-file-name "test.epub" readq-test--dir))
           (para (mapconcat #'identity (make-list 200 "lorem ipsum dolor") " ")))
      (readq-test--make-epub f (list para para para para))
      (let ((book (readq-add-book f 10))
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist)))
        (readq-mode 1)
        (readq-open book)
        (should (eq major-mode 'nov-mode))
        (should readq-book-mode)
        (should (eq (readq--book-buffer book) (current-buffer)))
        ;; Opening again must reuse the buffer even though nov clears
        ;; `buffer-file-name'.
        (let ((buf (current-buffer)))
          (readq-open book)
          (should (eq (current-buffer) buf)))
        (nov-goto-document 2)
        (goto-char (/ (point-max) 2))
        (let ((pt (point))
              ;; nov.el adds the table of contents for EPUB 2 books
              (total (length nov-documents)))
          (kill-buffer (current-buffer))
          (should (= (readq--get book :total) total))
          (should (= (readq--get book :page) 2))
          (should (= (readq--get book :point) pt))
          (should (< (/ 2.4 total) (readq--get book :progress) (/ 2.6 total)))
          (should (= (readq--get book :sessions) 1))
          (readq-open book)
          (readq-test--run-timers)
          (should (= nov-documents-index 2))
          (should (= (point) pt)))))))

;;;; The manual

(ert-deftest readq-test-manual-opens ()
  "C-c r h opens the Info manual, which Info finds on its own."
  (skip-unless (file-exists-p (expand-file-name "readq.info" readq--doc-directory)))
  (require 'info)
  (should (eq (lookup-key readq-command-map "h") #'readq-manual))
  (should (member "readq" (info--manual-names nil)))
  (save-window-excursion
    (readq-manual)
    (with-current-buffer "*info*"
      (should (string-match-p "readq" Info-current-file))
      (should (equal Info-current-node "Top"))
      (Info-index "readq-next")
      (should (equal Info-current-node "Your first ten minutes")))
    (kill-buffer "*info*")))

(provide 'readq-test)
;;; readq-test.el ends here
