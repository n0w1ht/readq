;;; readq-exam.el --- A plan counted back from an exam -*- lexical-binding: t; -*-

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
;;
;; `readq-exam' takes a name, a date and tags, and plans back from the
;; date in three phases:
;;
;;   reading   until `readq-exam-extract-days' + `readq-exam-card-days'
;;             days before the exam.  Everything with the tags gets
;;             that day as its deadline, so readq sets the pace.
;;   extracts  the next `readq-exam-extract-days' days: the books stay
;;             closed, and every extract with the tags comes up at
;;             least once, to be made into a card.
;;   cards     the last `readq-exam-card-days' days and the exam day:
;;             nothing with the tags comes up; you review your cards.
;;
;; Over the last `readq-exam-ramp-days' days the daily budget grows, up
;; to `readq-exam-budget-factor' times `readq-daily-minutes'.

;;; Code:

(require 'readq-plan)
(require 'readq-sections)

(defgroup readq-exams nil
  "Planning back from an exam."
  :group 'readq)

(defcustom readq-exam-extract-days 7
  "Days before an exam's last days kept for extracts only."
  :type 'natnum)

(defcustom readq-exam-card-days 3
  "Days before an exam kept for flashcards only."
  :type 'natnum)

(defcustom readq-exam-budget-factor 1.5
  "How much larger the daily budget is on the day of an exam.
It grows evenly to that over the last `readq-exam-ramp-days' days.
1.0 leaves the budget alone."
  :type 'number)

(defcustom readq-exam-ramp-days 14
  "Over how many days before an exam the daily budget grows."
  :type 'natnum)

(defun readq--exam-days (exam &optional now)
  "Return the days from NOW until EXAM; negative when it is over."
  (readq--days-until (plist-get exam :date) now))

(defun readq--exam-reading-end (exam)
  "Return the date by which the reading for EXAM must be finished.
That is the first day kept for extracts; the last day of reading is
the day before, as for any deadline."
  (readq--date-in (- (+ readq-exam-extract-days readq-exam-card-days))
                  (readq--date-noon (plist-get exam :date))))

(defun readq--exam-cards-start (exam)
  "Return the first day of EXAM kept for flashcards."
  (readq--date-in (- readq-exam-card-days) (readq--date-noon (plist-get exam :date))))

(defun readq--exam-phase (exam &optional now)
  "Return the phase of EXAM on NOW's date.
One of `reading', `extracts', `cards' and `over'."
  (let ((days (readq--exam-days exam now)))
    (cond ((< days 0) 'over)
          ((<= days readq-exam-card-days) 'cards)
          ((<= days (+ readq-exam-card-days readq-exam-extract-days)) 'extracts)
          (t 'reading))))

(defun readq--exam-items (exam)
  "Return the items EXAM covers: those with one of its tags."
  (cl-remove-if-not (lambda (b) (readq--tags-match-p b (plist-get exam :tags)))
                    (readq--books)))

(defun readq--exam-excludes-p (item &optional now)
  "Return non-nil when an exam keeps ITEM out of the queue on NOW's date.
Books are closed while an exam they belong to is in its extracts or
cards phase, extracts in its cards phase.  An extract that came back
because its card keeps failing comes up all the same."
  (and readq--exams
       (cl-some (lambda (exam)
                  (and (readq--tags-match-p item (plist-get exam :tags))
                       (pcase (readq--exam-phase exam now)
                         ('extracts (not (readq--extract-p item)))
                         ('cards (not (and (readq--extract-p item)
                                           (readq--get item :relearn)))))))
                readq--exams)))

(add-hook 'readq-queue-exclude-functions #'readq--exam-excludes-p)

(defun readq--exam-budget-factor (&optional now)
  "Return what the nearest exam multiplies the daily budget by on NOW's date."
  (let ((factor nil))
    (dolist (exam readq--exams)
      (let ((days (readq--exam-days exam now)))
        (when (and (>= days 0) (> readq-exam-ramp-days 0) (<= days readq-exam-ramp-days))
          (setq factor (max (or factor 1.0)
                            (+ 1.0 (* (- readq-exam-budget-factor 1.0)
                                      (/ (float (- readq-exam-ramp-days days))
                                         readq-exam-ramp-days))))))))
    factor))

(add-hook 'readq-budget-factor-functions #'readq--exam-budget-factor)

(defun readq--exam-spread-extracts (exam &optional now)
  "Bring every extract of EXAM up within its extracts phase.
Those due later are given the days from NOW to the last day of the
phase, the most important first.  Return how many were moved."
  (let* ((last (1- (- (readq--exam-days exam now) readq-exam-card-days)))
         (days (max 1 (1+ last)))
         (end (readq--date-in (max 0 last) now))
         (late (sort (cl-remove-if-not
                      (lambda (x) (and (readq--extract-p x) (readq--active-p x)
                                       (string< end (or (readq--get x :due) ""))))
                      (readq--exam-items exam))
                     (lambda (a b) (< (readq--get a :priority) (readq--get b :priority)))))
         (per-day (max 1 (ceiling (/ (float (length late)) days))))
         (n 0))
    (dolist (x late)
      (readq--put x :due (readq--date-in (min (max 0 last) (/ n per-day)) now))
      (cl-incf n))
    n))

(defun readq--exam-remove (exam)
  "Forget EXAM and the deadline it gave its tags."
  (let ((end (readq--exam-reading-end exam)))
    (setq readq--tag-deadlines
          (cl-remove-if (lambda (d) (and (member (car d) (plist-get exam :tags))
                                         (equal (cdr d) end)))
                        readq--tag-deadlines)))
  (setq readq--exams (delq exam readq--exams)
        readq--dirty t))

(defun readq--exams-roll (&optional now)
  "Do what the exams need on NOW's date.
Start the extracts phase of those that reached it, and forget those
that are over.  Runs in `readq-before-suggest-hook'."
  (when readq--exams
    (let (changed)
      (dolist (exam (copy-sequence readq--exams))
        (pcase (readq--exam-phase exam now)
          ('over
           (readq--exam-remove exam)
           (setq changed t)
           (message "readq: the exam \"%s\" is over; its plan is gone" (plist-get exam :name)))
          ((and 'extracts (guard (not (plist-get exam :spread))))
           (let ((n (readq--exam-spread-extracts exam now)))
             (setcdr (last exam) (list :spread t))
             (setq changed t)
             (message "readq: \"%s\" is %d days away: extracts only now, %d brought forward"
                      (plist-get exam :name) (readq--exam-days exam now) n)))))
      (when changed
        (setq readq--dirty t)
        (readq--save)
        (readq--queue-changed)))))

(add-hook 'readq-before-suggest-hook #'readq--exams-roll)

(defun readq--exam-plan-string (exam &optional now)
  "Return a sentence with the three phases of EXAM, as seen on NOW's date."
  (let ((short (lambda (date) (format-time-string "%a %d %b" (readq--date-noon date))))
        (days (readq--exam-days exam now)))
    (format "%s on %s (%s): %s"
            (plist-get exam :name)
            (funcall short (plist-get exam :date))
            (cond ((= days 0) "today") ((= days 1) "tomorrow") (t (format "in %d days" days)))
            (pcase (readq--exam-phase exam now)
              ('reading (format "finish reading %s before %s, then extracts, cards from %s"
                                (readq--tags-string-of (plist-get exam :tags))
                                (funcall short (readq--exam-reading-end exam))
                                (funcall short (readq--exam-cards-start exam))))
              ('extracts (format "extracts only now, cards from %s"
                                 (funcall short (readq--exam-cards-start exam))))
              ('cards "cards only now")
              (_ "over")))))

(defun readq--exam-lines (&optional now)
  "Return lines describing every exam, for `readq-workload'."
  (when readq--exams
    (append (list "Exams:")
            (mapcar (lambda (exam) (concat "  " (readq--exam-plan-string exam now)))
                    (sort (copy-sequence readq--exams)
                          (lambda (a b) (string< (plist-get a :date) (plist-get b :date)))))
            (list ""))))

(add-hook 'readq-workload-lines-functions #'readq--exam-lines)

(defun readq--exam-empty-queue (tags)
  "Say that an exam is why nothing with TAGS is left to read, if it is."
  (when-let* ((exam (cl-find-if
                     (lambda (e) (and (memq (readq--exam-phase e) '(extracts cards))
                                      (or (null tags)
                                          (cl-intersection tags (plist-get e :tags)
                                                           :test #'equal))))
                     readq--exams)))
    (if (eq (readq--exam-phase exam) 'cards)
        (format "\"%s\" is near: review your cards." (plist-get exam :name))
      (format "\"%s\" is near: the books are closed, and no extract is left today."
              (plist-get exam :name)))))

(add-hook 'readq-empty-queue-functions #'readq--exam-empty-queue)

;;;###autoload
(defun readq-exam (name date tags)
  "Plan the reading tagged TAGS back from an exam NAME on DATE.
DATE is a YYYY-MM-DD string.  Until `readq-exam-extract-days' plus
`readq-exam-card-days' days before it, you read: everything with one
of TAGS must be finished by then, and readq sets the pace as for any
deadline.  Then come the days for extracts only, each coming up at
least once, and last the days for cards only, when nothing with TAGS
comes up.  The daily budget grows over the last `readq-exam-ramp-days'
days.  `readq-workload' shows the plan.

A nil DATE (an empty answer) removes the exam NAME and its plan."
  (interactive
   (progn
     (readq--books)
     (let* ((name (completing-read "Exam: "
                                   (mapcar (lambda (e) (plist-get e :name)) readq--exams)))
            (old (cl-find name readq--exams
                          :key (lambda (e) (plist-get e :name)) :test #'equal))
            (date (readq--read-deadline (format "Date of \"%s\"" name)
                                        (plist-get old :date))))
       (list name date
             (and date (readq--read-tags "Tags it covers: " (plist-get old :tags) t))))))
  (readq--books)
  (when (string-empty-p (string-trim (or name ""))) (user-error "The exam needs a name"))
  (when-let* ((old (cl-find name readq--exams
                            :key (lambda (e) (plist-get e :name)) :test #'equal)))
    (readq--exam-remove old))
  (if (null date)
      (progn (readq--save)
             (readq--queue-changed)
             (message "No plan for \"%s\" anymore" name))
    (let* ((tags (or (readq--normalize-tags tags) (user-error "The exam needs tags")))
           (exam (list :name name :date date :tags tags))
           (end (readq--exam-reading-end exam)))
      (when (< (readq--exam-days exam) 0) (user-error "%s is in the past" date))
      (push exam readq--exams)
      ;; The reading phase is a deadline for the tags.
      (when (eq (readq--exam-phase exam) 'reading)
        (dolist (tag tags)
          (setq readq--tag-deadlines (assoc-delete-all tag readq--tag-deadlines))
          (push (cons tag end) readq--tag-deadlines))
        (dolist (it (readq--exam-items exam))
          (unless (readq--extract-p it) (readq--apply-deadline it))))
      (setq readq--dirty t)
      (readq--exams-roll)
      (readq--save)
      (readq--queue-changed)
      (message "%s" (readq--exam-plan-string exam))
      exam)))

(provide 'readq-exam)

;;; readq-exam.el ends here
