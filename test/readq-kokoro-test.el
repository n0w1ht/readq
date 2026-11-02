;;; readq-kokoro-test.el --- Tests for reading aloud with Kokoro -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-kokoro-test.el \
;;     -f ert-run-tests-batch-and-exit

;; kokoro.el itself is not needed: its functions are replaced by fakes.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defvar kokoro--session)
(defvar kokoro--paused)
(defvar kokoro--process)
(defvar kokoro-audio-format)

(defmacro readq-ktest--with-extracts (&rest body)
  "Run BODY with a book `book' and due extracts `x1', `x2' of it."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq--focus nil))
       (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
              (x1 (readq--create-extract book "Systole is the phase of contraction."
                                         :page 57 :comment "Key definition"))
              (x2 (readq--create-extract book "Diastole is the phase of relaxation."
                                         :page 58)))
         (readq--put x1 :due (readq--today) :priority 10)
         (readq--put x2 :due (readq--today) :priority 30)
         (ignore book x1 x2)
         ,@body))))

(defmacro readq-ktest--with-kokoro (&rest body)
  "Run BODY as if kokoro.el were loaded."
  (declare (indent 0))
  `(let ((had (featurep 'kokoro))
         (kokoro--session nil)
         (kokoro--paused nil)
         (kokoro--process nil)
         (kokoro-audio-format "mp3"))
     (provide 'kokoro)
     (unwind-protect (progn ,@body)
       (unless had (setq features (delq 'kokoro features))))))

;;;; Text to read

(ert-deftest readq-ktest-spoken-org ()
  (should (equal (readq--spoken-org
                  (concat ":PROPERTIES:\n:READQ_ID: abc\n:END:\n"
                          "Source: [[readq:abc][Guyton, p. 57]]\n"
                          "[[file:~/notes/readq-figures/heart.png]]\n"
                          "#+begin_quote\nThe [[https://x.org][heart]] pumps.\n"
                          ",* Not a heading\n#+end_quote\n"
                          "Note: see [[readq:def]]\n"))
                 "The heart pumps.\n* Not a heading\nNote: see readq:def")))

(ert-deftest readq-ktest-extract-text ()
  (readq-ktest--with-extracts
    ;; The title readq made is the start of the passage: not read twice.
    (should (equal (readq--extract-spoken-text x1)
                   "Systole is the phase of contraction.\nNote: Key definition"))
    ;; A title of your own is read first; sub-extracts are left out.
    (readq--create-extract x2 "phase of relaxation" :title "Relaxing")
    (let ((buf (find-file-noselect (readq--get x2 :file))))
      (with-current-buffer buf
        (goto-char (org-find-property "READQ_ID" (readq--get x2 :id)))
        (org-edit-headline "Heart cycle")
        (save-buffer)))
    (should (equal (readq--extract-spoken-text x2)
                   "Heart cycle.\n\nDiastole is the phase of relaxation."))))

(ert-deftest readq-ktest-due-extracts ()
  (readq-ktest--with-extracts
    (readq--put book :due (readq--today))
    (should (equal (readq--due-extracts) (list x1 x2)))
    (readq--put x1 :due (readq--date-in 3))
    (should (equal (readq--due-extracts) (list x2)))))

;;;; Saving as audio

(ert-deftest readq-ktest-save-extracts-audio ()
  (readq-ktest--with-extracts
    (readq-ktest--with-kokoro
      (let* ((saved nil)
             (out (expand-file-name "audio/due.mp3" readq-test--dir))
             (due-before (readq--get x1 :due))
             (sessions-before (readq--get x1 :sessions)))
        (cl-letf (((symbol-function 'kokoro-save-region-audio)
                   (lambda (beg end output)
                     (push (list (buffer-substring-no-properties beg end) output) saved))))
          (readq-save-extracts-audio (list x1 x2) out))
        (should (equal (cadr (car saved)) out))
        (should (file-directory-p (file-name-directory out)))
        (should (equal (car (car saved))
                       (concat "Extract 1 of 2.\n\nSystole is the phase of contraction.\n"
                               "Note: Key definition\n\n"
                               "Extract 2 of 2.\n\nDiastole is the phase of relaxation.")))
        ;; Saving is not reviewing.
        (should (equal (readq--get x1 :due) due-before))
        (should (equal (readq--get x1 :sessions) sessions-before))))))

(ert-deftest readq-ktest-save-extracts-audio-interactive ()
  (readq-ktest--with-extracts
    (readq-ktest--with-kokoro
      (let ((readq-audio-directory (expand-file-name "audio/" readq-test--dir))
            (saved nil))
        (cl-letf (((symbol-function 'kokoro-save-region-audio)
                   (lambda (_beg _end output) (push output saved)))
                  ((symbol-function 'read-file-name)
                   (lambda (_prompt dir default &rest _) (expand-file-name default dir))))
          (call-interactively #'readq-save-extracts-audio))
        (should (equal (car saved)
                       (expand-file-name (format "extracts-due-%s.mp3" (readq--today))
                                         readq-audio-directory)))
        ;; Nothing due: nothing to save.
        (readq--put x1 :due (readq--date-in 2))
        (readq--put x2 :due (readq--date-in 2))
        (should-error (call-interactively #'readq-save-extracts-audio)
                      :type 'user-error)))))

;;;; Reading aloud

(ert-deftest readq-ktest-read-aloud-extract ()
  (readq-ktest--with-extracts
    (readq-ktest--with-kokoro
      (let ((read nil))
        (cl-letf (((symbol-function 'kokoro-read-string)
                   (lambda (string &optional display) (setq read (list string display)))))
          (should (readq--open-extract x2))
          (readq-read-aloud))
        (should (equal read (list "Diastole is the phase of relaxation."
                                  (current-buffer))))
        (readq--end-review)))))

(ert-deftest readq-ktest-read-aloud-book-bookmark ()
  (readq-test--with-db
    (readq-ktest--with-kokoro
      (let* ((f (readq-test--touch "notes.txt"))
             (_ (with-temp-file f
                  (dotimes (i 200) (insert (format "Sentence number %d.\n" i)))))
             (book (readq-add-book f 20))
             (from nil))
        (readq-open book)
        (readq-test--run-timers)
        (goto-char (point-min))
        (forward-line 120)
        (readq--record-position)
        (let ((mark (point)))
          ;; Wandering off without reading: the bookmark is where to start.
          (goto-char (point-min))
          (cl-letf (((symbol-function 'kokoro-read-dwim) (lambda () (setq from (point)))))
            (readq-read-aloud))
          (should (= from mark)))
        (kill-buffer (current-buffer))))))

(ert-deftest readq-ktest-read-aloud-elsewhere ()
  (readq-ktest--with-kokoro
    (with-temp-buffer
      (should-error (readq-read-aloud) :type 'user-error))))

;;;; Listening counts as reading

(ert-deftest readq-ktest-listening-counts ()
  (readq-test--with-db
    (readq-ktest--with-kokoro
      (let* ((f (readq-test--touch "notes.txt"))
             (_ (with-temp-file f (insert "Some text.\n")))
             (book (readq-add-book f 20))
             (proc (make-process :name "fake-kokoro" :command '("sleep" "30")))
             (idle (seconds-to-time 1000))
             (readq-tick-interval 15)
             buf)
        (unwind-protect
            (progn
              (readq-open book)
              (setq buf (current-buffer))
              (with-temp-buffer
                (switch-to-buffer (current-buffer))
                (cl-letf (((symbol-function 'current-idle-time) (lambda () idle)))
                  (with-current-buffer buf (setq readq--session-seconds 0))
                  ;; Idle, and not reading aloud: no time.
                  (readq--tick)
                  (should (= (buffer-local-value 'readq--session-seconds buf) 0))
                  ;; Kokoro reads the book: its time counts.
                  (setq kokoro--process proc
                        kokoro--session (list :buffer buf))
                  (readq--tick)
                  (should (= (buffer-local-value 'readq--session-seconds buf) 15))
                  ;; Paused: no time.
                  (setq kokoro--paused t)
                  (readq--tick)
                  (should (= (buffer-local-value 'readq--session-seconds buf) 15))
                  ;; Turned off.
                  (setq kokoro--paused nil)
                  (let ((readq-count-listening nil))
                    (readq--tick))
                  (should (= (buffer-local-value 'readq--session-seconds buf) 15))))
              ;; Selected and read aloud at once: counted once.
              (switch-to-buffer buf)
              (cl-letf (((symbol-function 'current-idle-time) (lambda () nil)))
                (readq--tick))
              (should (= (buffer-local-value 'readq--session-seconds buf) 30)))
          (delete-process proc)
          (when (buffer-live-p buf) (kill-buffer buf)))))))

(provide 'readq-kokoro-test)
;;; readq-kokoro-test.el ends here
