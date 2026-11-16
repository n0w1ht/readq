;;; readq-relearn-test.el --- Tests for failed cards coming back -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-relearn-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defvar org-srs-review-rating)
(defvar org-srs-review-item)

(defmacro readq-rltest--with-card (&rest body)
  "Run BODY with an extract `x' of `book', exported and out of the queue."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
            (x (readq--create-extract book "The {{mitral}} valve has two cusps." :page 12))
            (readq-card-lapse-threshold 3)
            (readq--failed-cards-checked nil))
       (ignore book)
       (readq--put x :status 'finished :due "2026-01-01" :interval 40
                   :exported (list :date "2026-01-01" :backend 'anki :anki-id 77))
       ,@body)))

(ert-deftest readq-rltest-org-srs ()
  (readq-rltest--with-card
    (with-temp-buffer
      (org-mode)
      (insert "* Guyton, p. 12\n:PROPERTIES:\n:READQ_CARD_OF: " (readq--get x :id)
              "\n:END:\nThe {{1}{mitral}} valve.\n** Source\n")
      (cl-letf (((symbol-function 'org-srs-item-marker)
                 (lambda (&rest _) (copy-marker (point-min)))))
        (let ((org-srs-review-item '((cloze 1) "id"))
              (org-srs-review-rating :good))
          ;; Only \"again\" counts.
          (readq--srs-rated)
          (should-not (readq--get x :lapses))
          (setq org-srs-review-rating :again)
          (readq--srs-rated)
          (readq--srs-rated)
          (should (= (readq--get x :lapses) 2))
          (should (eq (readq--get x :status) 'finished))
          ;; The third failure brings the extract back, due today.
          (readq--srs-rated)
          (should (eq (readq--get x :status) 'active))
          (should (equal (readq--get x :due) (readq--today)))
          (should (readq--get x :relearn))
          (should (readq--due-p x))
          ;; More failures before you reread it change nothing.
          (readq--srs-rated)
          (should (= (readq--get x :lapses) 4))
          ;; Turned off, nothing is counted.
          (let ((readq-card-lapse-threshold nil))
            (readq--srs-rated)
            (should (= (readq--get x :lapses) 4))))))))

(ert-deftest readq-rltest-anki ()
  (readq-rltest--with-card
    (let ((lapses 2) asked)
      (cl-letf (((symbol-function 'card-export-anki-reachable-p) (lambda () t))
                ((symbol-function 'card-export-anki)
                 (lambda (action &optional params)
                   (push (cons action params) asked)
                   (pcase action
                     ("notesInfo" '(((noteId . 77) (cards . (501 502)))))
                     ("cardsInfo" `(((cardId . 501) (note . 77) (lapses . ,lapses))
                                    ((cardId . 502) (note . 77) (lapses . 0))))))))
        (should-not (readq-check-failed-cards))
        (should (equal (cdr (assoc "notesInfo" asked)) '((notes . [77]))))
        (should (= (readq--get x :lapses) 2))
        (should (eq (readq--get x :status) 'finished))
        (setq lapses 3)
        (should (equal (readq-check-failed-cards) (list x)))
        (should (readq--due-p x))
        ;; Reviewing it ends that; the count starts anew from here.
        (readq--reschedule x)
        (should-not (readq--get x :relearn))
        (setq lapses 5)
        (should-not (readq-check-failed-cards))
        (setq lapses 6)
        (should (equal (readq-check-failed-cards) (list x)))
        ;; Once a day by itself, quietly.
        (setq asked nil readq--failed-cards-checked nil)
        (readq--check-failed-cards-daily)
        (should asked)
        (setq asked nil)
        (readq--check-failed-cards-daily)
        (should-not asked)))
    ;; Anki not running: no error from the daily check, one from the command.
    (cl-letf (((symbol-function 'card-export-anki-reachable-p) (lambda () nil)))
      (setq readq--failed-cards-checked nil)
      (readq--check-failed-cards-daily)
      (should-error (readq-check-failed-cards) :type 'user-error))))

(ert-deftest readq-rltest-opens-with-source ()
  (readq-rltest--with-card
    (let (shown)
      (cl-letf (((symbol-function 'readq-goto-source)
                 (lambda (item) (setq shown item))))
        (save-window-excursion
          ;; An ordinary extract opens alone.
          (readq--put x :status 'active)
          (readq-open x)
          (should-not shown)
          (readq--finish-other-session)
          ;; One that came back opens with its source.
          (readq--put x :lapses 3)
          (readq--relearn x)
          (should (readq-open x))
          (should (eq shown x))
          (should readq-review-mode)
          (should (equal readq--review-id (readq--get x :id)))
          (let ((readq-relearn-show-source nil))
            (setq shown nil)
            (readq--finish-other-session)
            (readq--put x :relearn (readq--today))
            (readq-open x)
            (should-not shown)))))))

(provide 'readq-relearn-test)

;;; readq-relearn-test.el ends here
