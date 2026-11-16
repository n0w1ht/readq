;;; readq-exam-test.el --- Tests for planning back from an exam -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-exam-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-deadline-test)

(defmacro readq-extest--with-exam (&rest body)
  "Run BODY with a #cardio book and extract, another book, and an exam.
The exam `exam' is in 30 days; `guyton', `x' and `novel' are the items.
\(readq-extest--in N) is the time N days from now."
  (declare (indent 0))
  `(readq-dltest--with-db
     (let* ((readq-exam-extract-days 7)
            (readq-exam-card-days 3)
            (readq-exam-budget-factor 1.5)
            (readq-exam-ramp-days 14)
            (guyton (readq-dltest--pdf "Guyton" 100 20 30 '("cardio")))
            (novel (readq-dltest--pdf "Novel" 100 20 60))
            (x (readq--create-extract guyton "The mitral valve has two cusps." :page 12))
            (exam (readq-exam "Block 2" (readq--date-in 30) '("#Cardio"))))
       (ignore novel x exam)
       ,@body)))

(defun readq-extest--in (days)
  "Return the time DAYS days from now."
  (time-add (readq--today-noon) (* 86400 days)))

(ert-deftest readq-extest-phases ()
  (readq-extest--with-exam
    (should (equal (plist-get exam :tags) '("cardio")))
    (should (eq (readq--exam-phase exam) 'reading))
    (should (eq (readq--exam-phase exam (readq-extest--in 19)) 'reading))
    (should (eq (readq--exam-phase exam (readq-extest--in 20)) 'extracts))
    (should (eq (readq--exam-phase exam (readq-extest--in 26)) 'extracts))
    (should (eq (readq--exam-phase exam (readq-extest--in 27)) 'cards))
    (should (eq (readq--exam-phase exam (readq-extest--in 30)) 'cards))
    (should (eq (readq--exam-phase exam (readq-extest--in 31)) 'over))))

(ert-deftest readq-extest-reading-is-a-deadline ()
  (readq-extest--with-exam
    ;; Reading must be done before the extracts phase: 20 days from now.
    (should (equal (cdr (assoc "cardio" readq--tag-deadlines)) (readq--date-in 20)))
    (let ((info (readq--deadline-info guyton)))
      (should (= (plist-get info :days) 20))
      (should (= (plist-get info :per-day) 4)))
    (should-not (readq--deadline-info novel))
    ;; The exam is saved with the queue.
    (readq--save)
    (readq--load)
    (should (equal (plist-get (car readq--exams) :name) "Block 2"))
    ;; Removing the exam removes the deadline it made.
    (readq-exam "Block 2" nil nil)
    (should-not readq--exams)
    (should-not readq--tag-deadlines)))

(ert-deftest readq-extest-queue-by-phase ()
  (readq-extest--with-exam
    (let* ((guyton (readq--book-by-id (readq--get guyton :id)))
           (in-queue (lambda (item days)
                       (memq item (readq--queue-items (readq-extest--in days))))))
      ;; Reading: everything comes up.
      (should (funcall in-queue guyton 5))
      (should (funcall in-queue x 5))
      ;; Extracts: the exam's books are closed, other books are not.
      (should-not (funcall in-queue guyton 22))
      (should (funcall in-queue x 22))
      (should (funcall in-queue novel 22))
      ;; Cards: nothing of the exam, except an extract whose card keeps failing.
      (should-not (funcall in-queue guyton 28))
      (should-not (funcall in-queue x 28))
      (should (funcall in-queue novel 28))
      (readq--put x :relearn (readq--today))
      (should (funcall in-queue x 28))
      ;; Afterwards everything is back.
      (should (funcall in-queue guyton 31)))))

(ert-deftest readq-extest-extracts-brought-forward ()
  (readq-extest--with-exam
    (let ((y (readq--create-extract guyton "Systole is contraction." :page 13 :priority 5))
          (z (readq--create-extract novel "Not for the exam." :page 2))
          (start (readq-extest--in 20)))
      (dolist (e (list x y z))
        (readq--put e :due (readq--date-in 90)))
      (readq--exams-roll (readq-extest--in 10))
      (should (equal (readq--get x :due) (readq--date-in 90)))
      ;; On the first day of the phase, the exam's extracts come within it,
      ;; the most important first.
      (readq--exams-roll start)
      (should (equal (readq--get y :due) (readq--date-in 20)))
      (should (string< (readq--get x :due) (readq--date-in 27)))
      (should-not (string< (readq--get x :due) (readq--date-in 20)))
      (should (equal (readq--get z :due) (readq--date-in 90)))
      ;; Only once.
      (readq--put x :due (readq--date-in 90))
      (readq--exams-roll (readq-extest--in 21))
      (should (equal (readq--get x :due) (readq--date-in 90)))
      ;; Once it is over, the exam is forgotten.
      (readq--exams-roll (readq-extest--in 31))
      (should-not readq--exams))))

(ert-deftest readq-extest-budget-grows ()
  (readq-extest--with-exam
    (should (= (readq--daily-minutes) 60))
    (should (= (readq--daily-minutes (readq-extest--in 16)) 60))
    (should (= (readq--daily-minutes (readq-extest--in 23)) 75))
    (should (= (readq--daily-minutes (readq-extest--in 30)) 90))
    (should (= (readq--daily-minutes (readq-extest--in 31)) 60))
    (should (string-match-p "/90 min" (readq--budget-string (readq-extest--in 30))))
    (let ((readq-daily-minutes nil))
      (should-not (readq--daily-minutes (readq-extest--in 30))))))

(ert-deftest readq-extest-says-what-is-going-on ()
  (readq-extest--with-exam
    (let ((lines (mapconcat #'identity (readq--workload-lines) "\n")))
      (should (string-match-p "Exams:\n  Block 2 on .* (in 30 days): finish reading #cardio before"
                              lines)))
    (should (string-match-p "extracts only now"
                            (readq--exam-plan-string exam (readq-extest--in 22))))
    (should (string-match-p "cards only now"
                            (readq--exam-plan-string exam (readq-extest--in 29))))
    (should-not (readq--exam-empty-queue nil))
    (should-error (readq-exam "Old" "2020-01-01" '("cardio")) :type 'user-error)
    (should-error (readq-exam "No tags" (readq--date-in 9) nil) :type 'user-error)
    ;; An exam set when its cards phase has begun says so when nothing is left.
    (readq-exam "Soon" (readq--date-in 2) '("cardio"))
    (should (string-match-p "review your cards" (readq--exam-empty-queue nil)))
    (should-not (readq--exam-empty-queue '("leisure")))))

(provide 'readq-exam-test)

;;; readq-exam-test.el ends here
