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
    ;; In the Org file, the extract at point.
    (with-current-buffer (find-file-noselect (readq--get x90 :file))
      (goto-char (org-find-property "READQ_ID" (readq--get x90 :id)))
      (forward-line 3)
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
        ;; Only this extract shows.
        (should (string-match-p "Diastole" (buffer-string)))
        (should-not (string-match-p "Systole\\|four chambers" (buffer-string)))
        ;; Point is in its text, past the properties.
        (should-not (org-at-heading-p))
        (insert "Note: relaxation of the ventricles.\n")
        (goto-char (point-min))
        (org-edit-headline "Diastole")
        (readq-edit-extract-done))
      (should-not (buffer-live-p buf))
      (should-not (window-live-p win))
      ;; The base buffer isn't narrowed, and the file is saved.
      (with-current-buffer (find-buffer-visiting file)
        (should (= (point-min) 1))
        (should (string-match-p "four chambers" (buffer-string)))
        (should-not (buffer-modified-p)))
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should (string-match-p "Note: relaxation of the ventricles" text)))
      ;; The title follows the heading; the schedule doesn't change.
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
