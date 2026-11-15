;;; readq-edit-test.el --- Tests for editing an extract beside its source -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-edit-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defmacro readq-edtest--with-extracts (&rest body)
  "Run BODY with a PDF book `book' and extracts `x57', `x58a', `x58b', `x90'."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
            (x57 (readq--create-extract book "Systole is the phase of contraction." :page 57))
            (x58a (readq--create-extract book "Diastole is the phase of relaxation." :page 58))
            (x58b (readq--create-extract book "The heart has four chambers." :page 58))
            (x90 (readq--create-extract book "Cardiac output is stroke volume times rate." :page 90)))
       (ignore book x57 x58a x58b x90)
       (unwind-protect (save-window-excursion ,@body)
         (dolist (b (buffer-list))
           (when (buffer-local-value 'readq--edit-extract-id b)
             (kill-buffer b)))))))

(defmacro readq-edtest--on-page (page &rest body)
  "Run BODY as if reading `book' at PAGE."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'readq--buffer-book) (lambda (&rest _) book))
             ((symbol-function 'readq--buffer-position) (lambda () (list :page ,page))))
     (with-temp-buffer ,@body)))

(ert-deftest readq-edtest-extract-here ()
  (readq-edtest--with-extracts
    ;; One extract on the page: no question.
    (readq-edtest--on-page 57
      (should (eq (readq--extract-here "Edit") x57)))
    ;; Several: choose among them only.
    (let (offered)
      (cl-letf (((symbol-function 'readq--completing-read-book)
                 (lambda (prompt books) (setq offered (cons prompt books)) (cadr books))))
        (readq-edtest--on-page 58
          (should (eq (readq--extract-here "Edit") x58b)))
        (should (string-match-p "on this page" (car offered)))
        (should (equal (cdr offered) (list x58a x58b)))
        ;; None: all of the book's, nearest first.
        (readq-edtest--on-page 85
          (readq--extract-here "Edit"))
        (should (eq (cadr offered) x90))
        (should (eq (car (last (cdr offered))) x57))))
    ;; In a note, its extract.
    (with-current-buffer (find-file-noselect (readq--get x90 :file))
      (should (eq (readq--extract-here "Edit") x90)))))

(ert-deftest readq-edtest-edit-and-save ()
  (readq-edtest--with-extracts
    (let* ((file (readq--get x58a :file))
           (win (readq-edit-extract x58a))
           (buf (window-buffer win)))
      (should (eq (selected-window) win))
      (should (window-parameter win 'window-side))
      (with-current-buffer buf
        (should readq-edit-extract-mode)
        (should (eq (buffer-base-buffer buf) (find-buffer-visiting file)))
        (should (string-match-p "Diastole" (buffer-string)))
        ;; Point is in its text, past the front matter.
        (should (looking-at-p "#\\+begin_quote"))
        (insert "Note: relaxation of the ventricles.\n")
        (readq--note-set "title" "Diastole")
        (readq-edit-extract-done))
      (should-not (buffer-live-p buf))
      (should-not (window-live-p win))
      ;; The note is saved, and renamed after its new title.
      (should-not (file-exists-p file))
      (should (string-match-p "--diastole__extract\\.org\\'" (readq--get x58a :file)))
      (with-current-buffer (find-buffer-visiting (readq--get x58a :file))
        (should-not (buffer-modified-p)))
      (should (string-match-p "Note: relaxation of the ventricles" (readq-test--note x58a)))
      ;; The title follows the note; the schedule doesn't change.
      (should (equal (readq--get x58a :title) "Diastole"))
      (should (equal (readq--get x58a :due) (readq--date-in 1)))
      (should (= (or (readq--get x58a :sessions) 0) 0)))))

(ert-deftest readq-edtest-reuses-window ()
  (readq-edtest--with-extracts
    (let ((w1 (readq-edit-extract x57)))
      (should (eq (window-buffer (readq-edit-extract x57)) (window-buffer w1)))
      ;; Another extract replaces it in the same side window.
      (let ((w2 (readq-edit-extract x90)))
        (should (string-match-p "Cardiac output"
                                (with-current-buffer (window-buffer w2) (buffer-string))))
        (should (= (length (cl-remove-if-not (lambda (w) (window-parameter w 'window-side))
                                             (window-list)))
                   1))))))

(ert-deftest readq-edtest-command-from-book ()
  (readq-edtest--with-extracts
    (readq-edtest--on-page 90
      (call-interactively #'readq-edit-extract)
      (should (equal (buffer-local-value 'readq--edit-extract-id (current-buffer))
                     (readq--get x90 :id))))))

(ert-deftest readq-edtest-deleted-heading ()
  (readq-edtest--with-extracts
    (readq--delete-org-entry x57)
    (should-error (readq-edit-extract x57) :type 'user-error)
    (should-error (readq-edit-extract book) :type 'user-error)))

(provide 'readq-edit-test)
;;; readq-edit-test.el ends here
