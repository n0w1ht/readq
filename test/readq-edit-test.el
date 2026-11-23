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

(defvar readq-edtest--seen nil
  "What `denote-readq-edtest' saw: its buffer's file and point.")

(defun denote-readq-edtest ()
  "Stand-in for a Denote command that works on the current file."
  (interactive)
  (setq readq-edtest--seen (list buffer-file-name (point)))
  (insert "[[denote:x]]"))

(ert-deftest readq-edtest-denote-commands-in-note ()
  (readq-edtest--with-extracts
    (let* ((file (expand-file-name (readq--get x58a :file)))
           (buf (window-buffer (readq-edit-extract x58a)))
           (map (make-sparse-keymap))
           (pos nil))
      (define-key map (kbd "C-c z") #'denote-readq-edtest)
      (with-current-buffer buf
        (forward-line 1)
        (setq pos (point))
        (should (eq (command-remapping #'denote-readq-edtest)
                    #'readq-edit-extract-in-note))
        (let ((global (current-global-map))
              (readq-edtest--seen nil))
          (unwind-protect
              (progn (use-global-map (make-composed-keymap map global))
                     (execute-kbd-macro (kbd "C-c z")))
            (use-global-map global))
          ;; It ran in the note's buffer, at the same place.
          (should (equal readq-edtest--seen (list file pos)))
          ;; What it inserted shows here, and point is after it.
          (should (looking-back (regexp-quote "[[denote:x]]") pos))))
      (with-current-buffer (find-buffer-visiting file)
        (should (string-match-p "\\[\\[denote:x\\]\\]" (buffer-string)))))))

(ert-deftest readq-edtest-click-highlight-opens-note ()
  (readq-edtest--with-extracts
    (let* ((xh (readq--create-extract book "Preload stretches the ventricle." :page 58
                                      :edges '((0.1 0.5 0.6 0.55))))
           (annot (lambda (page edges)
                    `((page . ,page) (type . highlight) (markup-edges ,@edges))))
           opened)
      (cl-letf (((symbol-function 'readq--buffer-book) (lambda (&rest _) book))
                ((symbol-function 'readq-edit-extract) (lambda (x) (setq opened x))))
        ;; The extract's highlight: its note opens, and pdf-tools does nothing more.
        (should (readq--open-clicked-extract (funcall annot 58 '((0.1 0.5 0.6 0.55)))))
        (should (eq opened xh))
        ;; Another highlight on the page, or the same place on another page: pdf-tools'.
        (setq opened nil)
        (should-not (readq--open-clicked-extract (funcall annot 58 '((0.1 0.8 0.6 0.85)))))
        (should-not (readq--open-clicked-extract (funcall annot 59 '((0.1 0.5 0.6 0.55)))))
        (let ((readq-click-opens-extract nil))
          (should-not (readq--open-clicked-extract (funcall annot 58 '((0.1 0.5 0.6 0.55))))))
        (should-not opened)))))

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
