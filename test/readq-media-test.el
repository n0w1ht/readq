;;; readq-media-test.el --- Tests for audio and video in readq -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-media-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Playback tests run the real mpv (skipped without it), with no audio or
;; video output, fast.  The URL test also needs python3 for a local web
;; server.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-mtest-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun readq-media-test--mpv-p ()
  "Return non-nil when mpv is installed."
  (executable-find "mpv"))

(defmacro readq-media-test--with-db (&rest body)
  "Run BODY with an empty database and a fast, silent mpv."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq-mpv-args '("--no-config" "--vo=null" "--ao=null" "--speed=20"))
           (readq-mpv-interval 0.1)
           (readq-extracts-fallback-directory
            (expand-file-name "fallback" readq-test--dir)))
       (unwind-protect (progn ,@body)
         (when readq--media-session
           (ignore-errors (delete-process (plist-get readq--media-session :process)))
           (setq readq--media-session nil))))))

(defun readq-media-test--wait (pred &optional seconds)
  "Wait until PRED returns non-nil, at most SECONDS (default 20)."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(defun readq-media-test--book ()
  "Add the lecture fixture to the queue and return it."
  (readq-add-book (readq-xtest--copy-fixture "lecture.opus") 20 "Lecture"))

(defun readq-media-test--arg (prefix)
  "Return the argument of the last mpv command starting with PREFIX."
  (cl-find-if (lambda (a) (string-prefix-p prefix a)) readq--mpv-last-command))

;;;; Without playing

(ert-deftest readq-media-test-format-time ()
  (should (equal (readq--format-time 0) "0:00"))
  (should (equal (readq--format-time 75.6) "1:16"))
  (should (equal (readq--format-time 3725) "1:02:05"))
  (should (equal (readq--format-time nil) "?")))

(ert-deftest readq-media-test-formats ()
  (should (eq (readq--format "talk.MP3") 'media))
  (should (eq (readq--format "lecture.mkv") 'media))
  (should (eq (readq--format "https://www.youtube.com/watch?v=abc") 'media))
  (should (readq--url-p "https://youtu.be/abc"))
  (should-not (readq--url-p "C:/Videos/a.mp4"))
  (should (equal (readq--normalize-file "https://youtu.be/abc") "https://youtu.be/abc")))

(ert-deftest readq-media-test-parse ()
  ;; mpv's status line may come first on the same line.
  (should (equal (readq--mpv-parse "A: 00:00:01 / 00:01:30 (2%)READQ {\"event\":\"pos\",\"pos\":1.5}")
                 '(:event "pos" :pos 1.5)))
  (should-not (readq--mpv-parse "A: 00:00:01 / 00:01:30 (2%)"))
  (should-not (readq--mpv-parse "READQ {broken")))

(ert-deftest readq-media-test-program-on-windows ()
  (let* ((dir (make-temp-file "mpv" t))
         (exe (expand-file-name "mpv.exe" dir))
         (com (expand-file-name "mpv.com" dir)))
    (unwind-protect
        (progn
          (with-temp-file exe) (with-temp-file com)
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) exe)))
            (let ((system-type 'windows-nt) (readq-mpv-program nil))
              ;; mpv.com: its output reaches Emacs.
              (should (equal (readq--mpv-program) com)))
            (let ((system-type 'gnu/linux) (readq-mpv-program nil))
              (should (equal (readq--mpv-program) exe))))
          (let ((readq-mpv-program "/opt/mpv"))
            (should (equal (readq--mpv-program) "/opt/mpv")))
          (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
            (let ((system-type 'gnu/linux) (readq-mpv-program nil))
              (should-error (readq--mpv-program) :type 'user-error))))
      (delete-directory dir t))))

(ert-deftest readq-media-test-fallback-without-reports ()
  ;; If mpv's output never reaches Emacs, its watch-later file is used.
  (readq-media-test--with-db
    (let* ((book (readq-add-book (readq-test--touch "talk.mp3") 20 "Talk"))
           (wl (make-temp-file "wl" t)))
      (readq--put book :total 120.0)
      (with-temp-file (expand-file-name "ABCDEF" wl) (insert "start=41.500000\n"))
      (readq--media-finish (list :id (readq--get book :id) :started (- (float-time) 90)
                                 :wl wl :time nil :reason nil :marks nil)
                           0)
      (should (= (readq--get book :time) 41.5))
      (should (< 0.34 (readq--get book :progress) 0.35))
      (should (= (readq--get book :sessions) 1))
      (should-not (file-exists-p wl))
      ;; No watch-later file after a normal exit: it played to the end.
      (readq--media-finish (list :id (readq--get book :id) :started (float-time)
                                 :wl (make-temp-file "wl" t) :time nil :reason nil
                                 :marks nil)
                           0)
      (should (= (readq--get book :time) 120.0))
      (should (eq (readq--get book :status) 'finished)))))

;;;; Playing in mpv

(ert-deftest readq-media-test-add-and-dashboard ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let ((book (readq-media-test--book)))
      (should (eq (readq--get book :format) 'media))
      (should (< 89.9 (readq--get book :total) 90.1))
      (should (equal (readq--position-string book) "0:00 / 1:30"))
      (readq)
      (goto-char (point-min))
      (should (re-search-forward "audio +Lecture .* 0:00 / 1:30" nil t))
      (kill-buffer "*readq*"))))

(ert-deftest readq-media-test-stop-midway-with-mark ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (readq-mpv-args (append readq-mpv-args
                                   (list (concat "--script="
                                                 (expand-file-name "mpv-mark-test.lua"
                                                                   readq-mtest-dir))))))
      (readq-open book)
      (should (readq--media-playing-p))
      (should (equal (readq-media-test--arg "--start=") "--start=0.000"))
      (should (readq-media-test--wait
               (lambda () (and (plist-get readq--media-session :marks)
                               (> (or (plist-get readq--media-session :time) 0) 8)))))
      ;; Finishing the session closes mpv and saves.
      (should (eq (readq-finish-session) book))
      (should-not (readq--media-playing-p))
      (let ((time (readq--get book :time)))
        (should (< 8 time 80))
        (should (= (readq--get book :sessions) 1))
        (should-not (readq--due-p book))
        (should (eq (readq--get book :status) 'active))
        ;; The mark became an extract that plays from a little before it.
        (let ((x (car (readq--extracts-of book t))))
          (should (string-match-p "\\`Lecture at 0:0[0-9]\\'" (readq--get x :title)))
          (should (string-match-p "\\[Lecture, 0:0[0-9]\\]\\]" (readq-xtest--org-text x)))
          (readq-goto-source x)
          (should (plist-get readq--media-session :peek))
          (should (equal (readq-media-test--arg "--start=") "--start=0.000"))
          (readq--media-stop)
          ;; Looking it up did not move your place.
          (should (= (readq--get book :time) time)))
        ;; Playing again resumes where you stopped.
        (readq-open book)
        (should (equal (readq-media-test--arg "--start=") (format "--start=%.3f" time)))
        (readq--media-stop)))))

(ert-deftest readq-media-test-play-to-end ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let ((book (readq-media-test--book)))
      (readq--put book :time 70.0)
      (readq-open book)
      (should (equal (readq-media-test--arg "--start=") "--start=70.000"))
      (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
      (should (= (readq--get book :progress) 1.0))
      (should (eq (readq--get book :status) 'finished))
      ;; Without finishing at the end, it is rescheduled instead.
      (let ((readq-media-finish-at-end nil))
        (readq--put book :status 'active :time 80.0)
        (readq-open book)
        (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
        (should (eq (readq--get book :status) 'active))
        (should (= (readq--get book :sessions) 2))
        ;; Played to the end: the next time starts over.
        (should (= (readq--media-resume book) 0))))))

(ert-deftest readq-media-test-chapters-as-sections ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let ((book (readq-media-test--book)))
      (should (equal (mapcar (lambda (e) (list (plist-get e :title) (plist-get e :start)
                                               (round (plist-get e :end))))
                             (readq--book-outline book))
                     '(("Introduction" 0.0 30) ("The cardiac cycle" 30.0 60)
                       ("Heart sounds" 60.0 90))))
      (readq-add-sections book)
      (should (string-match-p "The cardiac cycle +0:30–1:00" (buffer-string)))
      (goto-char (point-min))
      (search-forward "The cardiac cycle")
      (readq-sections-mark 5)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (readq-sections-add))
      (kill-buffer (current-buffer))
      (let ((cycle (cl-find "The cardiac cycle" (readq--books)
                            :key (lambda (x) (readq--get x :heading)) :test #'equal)))
        (should (equal (readq--position-string cycle) "0:30 (0:30–1:00)"))
        ;; A chapter plays from its start to its end only.
        (readq-open cycle)
        (should (equal (readq-media-test--arg "--start=") "--start=30.000"))
        (should (equal (readq-media-test--arg "--end=") "--end=60.000"))
        (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
        (should (= (readq--get cycle :time) 60.0))
        (should (= (readq--get cycle :progress) 1.0))
        (should (eq (readq--get cycle :status) 'finished))
        ;; The book's own place did not move.
        (should-not (readq--get book :time))))))

(ert-deftest readq-media-test-next-while-playing ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (other (readq-add-book (readq-test--touch "other.pdf") 50 "Other"))
           opened)
      (readq-open book)
      (should (readq-media-test--wait (lambda () (plist-get readq--media-session :time))))
      (cl-letf (((symbol-function 'readq-open) (lambda (item) (setq opened item) t)))
        (readq-next))
      (should-not (readq--media-playing-p))
      (should (= (readq--get book :sessions) 1))
      (should (eq opened other)))))

(ert-deftest readq-media-test-org-link-plays-moment ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let ((book (readq-media-test--book)))
      (readq--org-follow (format "%s::t65" (readq--get book :id)))
      (should (plist-get readq--media-session :peek))
      (should (equal (readq-media-test--arg "--start=") "--start=55.000"))
      (readq--media-stop)
      (should-not (readq--get book :time)))))

(ert-deftest readq-media-test-url ()
  (skip-unless (and (readq-media-test--mpv-p) (executable-find "python3")))
  (readq-media-test--with-db
    (let* ((port (+ 20000 (random 20000)))
           (server (start-process "readq-http" nil "python3" "-m" "http.server"
                                  (number-to-string port) "--bind" "127.0.0.1"
                                  "--directory" (expand-file-name "fixtures" readq-mtest-dir)))
           (url (format "http://127.0.0.1:%d/lecture.m4a" port)))
      (unwind-protect
          (progn
            (should (readq-media-test--wait
                     (lambda () (ignore-errors
                                  (delete-process
                                   (make-network-process :name "probe" :host "127.0.0.1"
                                                         :service port))
                                  t))
                     10))
            (let ((book (readq-add-url url 30 nil '("cardio"))))
              (should (equal (readq--get book :file) url))
              (should (equal (readq--get book :title) url))
              (should (< 89.9 (readq--get book :total) 90.1))
              (should (equal (readq--media-kind book) "online"))
              (should-not (readq--missing-p book))
              (should (equal (readq--item-tags book) '("cardio")))
              (should-error (readq-add-url url 30) :type 'user-error)
              ;; Online videos have no folder: their extracts go to the
              ;; fallback folder (unless `readq-extracts-directory' is set).
              (let ((readq-extracts-directory nil))
                (should (string-prefix-p (abbreviate-file-name
                                          (expand-file-name "fallback" readq-test--dir))
                                         (readq--extracts-file book))))
              (readq--put book :time 80.0)
              (readq-open book)
              (should (equal (car (last readq--mpv-last-command)) url))
              (should (readq-media-test--wait (lambda () (not (readq--media-playing-p)))))
              (should (eq (readq--get book :status) 'finished))))
        (delete-process server)))))

(ert-deftest readq-media-test-url-yt-dlp-options ()
  (let ((readq-mpv-ytdl-format "bestaudio")
        (readq-mpv-ytdl-path "/opt/yt-dlp"))
    (should (equal (readq--mpv-ytdl-args)
                   '("--ytdl-format=bestaudio"
                     "--script-opts-append=ytdl_hook-ytdl_path=/opt/yt-dlp")))))

(ert-deftest readq-media-test-mark-without-playing ()
  (let ((readq--media-session nil))
    (should-error (readq-media-mark) :type 'user-error)))

(provide 'readq-media-test)
;;; readq-media-test.el ends here
