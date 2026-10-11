;;; readq-anki-gate-test.el --- Tests for readq's Anki-first option -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-anki-gate-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Runs test/fake-ankiconnect.py (needs python3).

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)

(defconst readq-gtest--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar readq-gtest--launched 0
  "Times Anki was started during a test.")

(defmacro readq-gtest--with-anki (reviews &rest body)
  "Run BODY with a fake AnkiConnect that reports REVIEWS reviews today.
REVIEWS nil means Anki is not running.  Starting Anki is recorded in
`readq-gtest--launched' instead of done."
  (declare (indent 1))
  `(let* ((port (+ 20000 (random 20000)))
          (process-environment (cons (format "READQ_FAKE_ANKI_REVIEWS=%s" (or ,reviews 0))
                                     process-environment))
          (proc (and ,reviews
                     (start-process "fake-anki" nil "python3"
                                    (expand-file-name "fake-ankiconnect.py" readq-gtest--dir)
                                    (number-to-string port)
                                    (expand-file-name "anki.log" readq-test--dir))))
          (readq-anki-connect-url (format "http://127.0.0.1:%d" (if proc port 9)))
          (readq--anki-gate-passed nil)
          (readq-gtest--launched 0)
          (tries 0))
     (while (and proc (< tries 50) (not (readq--anki-reachable-p)))
       (setq tries (1+ tries))
       (accept-process-output nil 0.1))
     (unwind-protect
         (cl-letf (((symbol-function 'readq--launch-anki)
                    (lambda () (setq readq-gtest--launched (1+ readq-gtest--launched)) t)))
           ,@body)
       (when proc (delete-process proc)))))


(defun readq-gtest--book ()
  "Add a text book to the queue and return it."
  (let ((f (expand-file-name "notes.txt" readq-test--dir)))
    (with-temp-file f (insert "Cardiac cycle.\n"))
    (readq-add-book f 20)))

(defun readq-gtest--refusal (fn)
  "Call FN and return the message of the `user-error' it signals, or nil."
  (condition-case err (progn (funcall fn) nil)
    (user-error (error-message-string err))))

(ert-deftest readq-gtest-off-by-default ()
  (should-not (default-value 'readq-anki-gate-minimum))
  (readq-test--with-db
    (readq-gtest--with-anki nil
      (let ((book (readq-gtest--book)))
        (should (readq-open book))
        (should readq-book-mode)
        (should (= readq-gtest--launched 0))))))

(ert-deftest readq-gtest-too-few-reviews ()
  (skip-unless (executable-find "python3"))
  (readq-test--with-db
    (readq-gtest--with-anki 12
      (let ((readq-anki-gate-minimum 50)
            (book (readq-gtest--book)))
        (should (equal (readq-gtest--refusal (lambda () (readq-open book)))
                       "Anki first: 12 of 50 reviews done today.  Switching to Anki"))
        (should (= readq-gtest--launched 1))
        (should-not (readq--book-buffer book))
        ;; readq-next refuses too, before offering anything.
        (should (string-prefix-p "Anki first: 12 of 50"
                                 (readq-gtest--refusal #'readq-next)))
        (should (= readq-gtest--launched 2))
        (should-not (readq--book-buffer book))
        (should-not readq--anki-gate-passed)))))

(ert-deftest readq-gtest-anki-not-running ()
  (readq-test--with-db
    (readq-gtest--with-anki nil
      (let ((readq-anki-gate-minimum 50)
            (book (readq-gtest--book)))
        (should (equal (readq-gtest--refusal (lambda () (readq-open book)))
                       "Anki first: Anki is not running, and 50 reviews are needed today.  Starting Anki"))
        (should (= readq-gtest--launched 1))
        (should-not (readq--book-buffer book))))))

(ert-deftest readq-gtest-anki-not-found ()
  (readq-test--with-db
    (readq-gtest--with-anki nil
      (cl-letf (((symbol-function 'readq--launch-anki) #'ignore))
        (let ((readq-anki-gate-minimum 50)
              (book (readq-gtest--book)))
          (should (string-suffix-p "Cannot find Anki; set `readq-anki-program'"
                                   (readq-gtest--refusal (lambda () (readq-open book))))))))))

(ert-deftest readq-gtest-enough-reviews ()
  (skip-unless (executable-find "python3"))
  (readq-test--with-db
    (let ((readq-anki-gate-minimum 50)
          book)
      (readq-gtest--with-anki 50
        (setq book (readq-gtest--book))
        (should (readq-open book))
        (should readq-book-mode)
        (should (= readq-gtest--launched 0))
        (should (equal readq--anki-gate-passed (readq--today)))
        (kill-buffer (current-buffer))
        ;; Once reached, the day is not checked again, even without Anki.
        (let ((readq-anki-connect-url "http://127.0.0.1:9"))
          (should (readq-open book)))
        (kill-buffer (current-buffer))
        ;; A new day asks again.
        (setq readq--anki-gate-passed "2000-01-01")
        (let ((readq-anki-connect-url "http://127.0.0.1:9"))
          (should (readq-gtest--refusal (lambda () (readq-open book)))))))))

(ert-deftest readq-gtest-launch-anki ()
  (readq-test--with-db
    (let* ((marker (expand-file-name "anki-started" readq-test--dir))
           (script (expand-file-name "anki" readq-test--dir))
           (readq-anki-program script)
           (tries 0))
      (with-temp-file script (insert "#!/bin/sh\ntouch " (shell-quote-argument marker) "\n"))
      (set-file-modes script #o755)
      (should (eq (readq--anki-program) script))
      (should (readq--launch-anki))
      (while (and (< tries 50) (not (file-exists-p marker)))
        (setq tries (1+ tries))
        (sleep-for 0.1))
      (should (file-exists-p marker))
      (let ((readq-anki-program nil)
            (exec-path nil)
            (process-environment (cons "LOCALAPPDATA" process-environment)))
        (unless (file-executable-p "/Applications/Anki.app/Contents/MacOS/anki")
          (should-not (readq--anki-program)))))))

(provide 'readq-anki-gate-test)
;;; readq-anki-gate-test.el ends here
