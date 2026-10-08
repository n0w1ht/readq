;;; readq-figure-test.el --- Tests for readq's figure extracts -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-figure-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; Batch Emacs shows no images, so the tests put the image properties
;; that nov.el and eww would insert in a graphical Emacs.  PDF crops use
;; the real pdf-tools (READQ_EPDFINFO), mpv tests the real mpv.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-cards-test)
(require 'readq-media-test)

(defun readq-figtest--png ()
  "Return the bytes of the diagram fixture."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally (expand-file-name "diagram.png" readq-xtest--fixtures))
    (buffer-string)))

(defun readq-figtest--png-p (file)
  "Return non-nil when FILE is a PNG."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 8)
    (equal (buffer-string) "\211PNG\r\n\032\n")))

(defun readq-figtest--put-image (pos spec)
  "Show the image SPEC (a plist) at POS, as shr and nov.el do."
  (let ((inhibit-read-only t))
    (put-text-property pos (1+ pos) 'display (cons 'image spec))))

(defun readq-figtest--png-width (file)
  "Return the width in pixels of the PNG FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 16 20)
    (let ((w 0))
      (dolist (c (string-to-list (buffer-string)) w)
        (setq w (+ (* w 256) c))))))

;;;; Creating figures

(ert-deftest readq-figtest-create-figure ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 30 "Heart"))
           (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png)
                                    :page 12 :caption "  Wiggers diagram ")))
      (should (eq (readq--get x :format) 'extract))
      (should (equal (readq--get x :title) "Wiggers diagram"))
      (should (= (readq--get x :priority) (+ 30 readq-extract-priority-offset)))
      (let ((file (readq--figure-file x)))
        (should (file-exists-p file))
        (should (readq-figtest--png-p file))
        ;; All figures in one folder, named by date, book and page.
        (should (equal (file-name-directory file) (expand-file-name readq-figures-directory)))
        (should (string-match-p "\\`heart_[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]_[0-9]\\{6\\}_p12\\.png\\'"
                                (file-name-nondirectory file))))
      ;; The Org entry links the image under the Source line.
      (should (string-match-p
               (concat "^\\* Wiggers diagram\n:PROPERTIES:\n:READQ_ID: [^\n]+\n:END:\n"
                       "Source: \\[\\[readq:[^]]+\\]\\[Heart, p\\. 12\\]\\]\n"
                       "\\[\\[file:" (regexp-quote (abbreviate-file-name (readq--figure-file x)))
                       "\\]\\]\n")
               (readq-xtest--org-text x)))
      ;; Without a caption: a default heading.  A file is copied.
      (let ((y (readq--create-figure
                book (list :file (expand-file-name "diagram.png" readq-xtest--fixtures))
                :page 3)))
        (should (equal (readq--get y :title) "Figure: Heart, p. 3"))
        (should (string-match-p "\\`heart_.*_p3\\.png\\'" (file-name-nondirectory (readq--figure-file y))))
        (should (readq-figtest--png-p (readq--figure-file y)))
        (should-not (equal (readq--figure-file x) (readq--figure-file y)))))))

(ert-deftest readq-figtest-names ()
  (readq-ftest--with-db
    (let* ((pdf (readq-add-book (readq-test--touch "Guyton Physiology.pdf") 30 "Guyton Physiology"))
           (talk (readq-add-book (readq-test--touch "talk.mp3") 30 "Cardio: Lecture 4"))
           (epub (readq-add-book (readq-test--touch "b.epub") 30 "Robbins"))
           (notes (readq-add-book (readq-test--touch "n.org") 30 "Notes"))
           (t1 (encode-time 6 5 4 3 2 2026))
           (t2 (time-add t1 3600)))
      (readq--put talk :format 'media)
      (should (equal (file-name-nondirectory (readq--figure-name pdf 112 "png" t1))
                     "guyton-physiology_2026-02-03_040506_p112.png"))
      (should (equal (file-name-nondirectory (readq--figure-name talk 1421.7 "jpg" t1))
                     "cardio-lecture-4_2026-02-03_040506_23m41s.jpg"))
      (should (equal (readq--figure-place talk 3725) "1h02m05s"))
      (should (equal (readq--figure-place epub 2) "ch3"))
      (should (equal (readq--figure-place notes 4) "s4"))
      (should-not (readq--figure-place notes 0))
      ;; Taken in the same second: numbered, still in order.
      (let* ((a (readq--create-figure pdf (list :data (readq-figtest--png) :type 'png)
                                      :page 9 :time t1))
             (b (readq--create-figure pdf (list :data (readq-figtest--png) :type 'png)
                                      :page 9 :time t1))
             (c (readq--create-figure epub (list :data (readq-figtest--png) :type 'png)
                                      :page 0 :time t2))
             (names (mapcar (lambda (x) (file-name-nondirectory (readq--figure-file x)))
                            (list a b c))))
        (should (equal names '("guyton-physiology_2026-02-03_040506_p9.png"
                               "guyton-physiology_2026-02-03_040506b_p9.png"
                               "robbins_2026-02-03_050506_ch1.png")))
        (should (equal (directory-files readq-figures-directory nil "\\.png\\'") names))
        ;; The folder moved: images are found by name.
        (let ((old (readq--figure-file a))
              (readq-figures-directory (expand-file-name "moved/" readq-test--dir)))
          (copy-directory (file-name-directory old) readq-figures-directory nil nil t)
          (delete-directory (file-name-directory old) t)
          (should (equal (readq--figure-file a)
                         (expand-file-name (car names) readq-figures-directory))))))))

(ert-deftest readq-figtest-delete-removes-image ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 30 "Heart"))
           (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png) :page 1))
           (file (readq--figure-file x)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (readq-delete-extract x))
      (should-not (file-exists-p file))
      (should-not (memq x (readq--books))))))

(ert-deftest readq-figtest-review-shows-images ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 30 "Heart"))
           (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png) :page 1))
           shown)
      (cl-letf (((symbol-function 'display-images-p) (lambda (&rest _) t))
                ((symbol-function 'org-display-inline-images)
                 (lambda (&rest _) (setq shown org-image-actual-width))))
        (should (readq--open-extract x)))
      (should (equal shown (list readq-figure-display-width)))
      ;; Without image support, nothing breaks.
      (readq--end-review)
      (should (readq--open-extract x)))))

;;;; PDF (pdf-tools)

(ert-deftest readq-figtest-pdf-crop ()
  (skip-unless (readq-xtest--pdf-tools-p))
  (readq-ftest--with-db
    (let* ((file (readq-xtest--copy-fixture "outline.pdf"))
           (book (readq-add-book file 30 "Outline"))
           (region '(3 (0.1 0.1 0.6 0.3) (0.2 0.25 0.7 0.5)))
           (readq-ask-figure-caption nil)
           deactivated)
      (with-temp-buffer
        (cl-letf (((symbol-function 'readq--buffer-book) (lambda (&rest _) book))
                  ((symbol-function 'pdf-view-active-region-p) (lambda () region))
                  ((symbol-function 'pdf-view-active-region) (lambda (&rest _) region))
                  ((symbol-function 'pdf-view-deactivate-region)
                   (lambda () (setq deactivated t)))
                  ((symbol-function 'image-mode-window-get) (lambda (&rest _) 7)))
          (let ((x (readq--figure-from-pdf)))
            (should deactivated)
            (should (= (readq--get x :page) 3))
            (should (equal (readq--get x :figure-edges) '(0.1 0.1 0.7 0.5)))
            (should (equal (readq--get x :title) "Figure: Outline, p. 3"))
            (should (readq-figtest--png-p (readq--figure-file x)))
            ;; At 200 dpi, 60% of the page width.
            (let ((page (pdf-info-pagesize 3 file)))
              (should (< (abs (- (readq-figtest--png-width (readq--figure-file x))
                                 (* 0.6 (car page) (/ 200 72.0))))
                         3))))
          ;; No selection: the whole page, if you say so.
          (setq region nil)
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
            (should-error (readq--figure-from-pdf) :type 'user-error))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
            (let ((x (readq--figure-from-pdf)))
              (should (= (readq--get x :page) 7))
              (should (equal (readq--get x :figure-edges) '(0 0 1 1))))))))))

;;;; Org, Markdown, eww, nov.el

(ert-deftest readq-figtest-org-link ()
  (readq-ftest--with-db
    (make-directory (expand-file-name "lib/img" readq-test--dir) t)
    (copy-file (expand-file-name "diagram.png" readq-xtest--fixtures)
               (expand-file-name "lib/img/diagram.png" readq-test--dir) t)
    (let* ((file (readq-ftest--write "lib/notes.org"
                                     (concat "* Heart\nText.\n* Systole\nSee the cycle:\n"
                                             "[[file:img/diagram.png]]\nMore text.\n")))
           (book (readq-add-book file 20 "Notes"))
           (readq-ask-figure-caption t))
      (readq-open book)
      (goto-char (point-min))
      (search-forward "diagram")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "The cycle")))
        (let ((x (readq-extract-figure)))
          (should (equal (readq--get x :title) "The cycle"))
          (should (equal (readq--get x :section) "Systole"))
          (should (= (readq--get x :page) 2))
          (should (readq-figtest--png-p (readq--figure-file x)))
          ;; Figures are not highlighted as passages in the book.
          (readq--decorate-extracts)
          (should-not (cl-some (lambda (o) (overlay-get o 'readq-extract))
                               (overlays-in (point-min) (point-max))))))
      ;; Not on an image.
      (goto-char (point-min))
      (should-error (readq-extract-figure) :type 'user-error))))

(ert-deftest readq-figtest-markdown-link ()
  (readq-ftest--with-db
    (make-directory (expand-file-name "md" readq-test--dir) t)
    (copy-file (expand-file-name "diagram.png" readq-xtest--fixtures)
               (expand-file-name "md/pic.PNG" readq-test--dir) t)
    (let* ((file (readq-ftest--write "md/notes.md"
                                     "# Heart\n\nIntro.\n\nThe cycle ![Wiggers](pic.PNG \"title\") here.\n"))
           (book (readq-add-book file 20 "MD notes"))
           (readq-ask-figure-caption nil))
      (readq-open book)
      (goto-char (point-min))
      (search-forward "The cycle")
      ;; Anywhere on the line.
      (let ((x (readq-extract-figure)))
        (should (string-match-p "\\.png\\'" (readq--get x :figure)))
        (should (readq-figtest--png-p (readq--figure-file x)))))))

(ert-deftest readq-figtest-eww-image ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "web/article.html" readq-ftest--html))
           (book (readq-add-book file 30 "Article"))
           (readq-ask-figure-caption nil))
      (readq-open book)
      (readq-ftest--run-timers)
      (should (derived-mode-p 'eww-mode))
      (goto-char (point-min))
      (re-search-forward "Diastole[ \n]+is")
      ;; shr shows images from their data.
      (readq-figtest--put-image (line-beginning-position)
                                (list :type 'png :data (readq-figtest--png)))
      (end-of-line)
      (let ((x (readq-extract-figure)))
        (should (equal (readq--get x :section) "Diastole"))
        (should (string-match-p "\\`Figure: Article, Diastole" (readq--get x :title)))
        (should (readq-figtest--png-p (readq--figure-file x)))))))

(ert-deftest readq-figtest-nov-image ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-ftest--with-db
    (let* ((nov-save-place-file nil)
           (f (expand-file-name "test.epub" readq-test--dir))
           (readq-ask-figure-caption nil))
      (readq-test--make-epub f (list "One." "Two has a figure." "Three."))
      (let ((book (readq-add-book f 10 "EPUB"))
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist)))
        (readq-open book)
        (should (eq major-mode 'nov-mode))
        (nov-goto-document 2)
        (goto-char (point-min))
        (search-forward "figure")
        ;; nov.el shows images from their file.
        (readq-figtest--put-image (- (point) 3)
                                  (list :type 'png :file (expand-file-name
                                                          "diagram.png" readq-xtest--fixtures)))
        (let ((x (readq-extract-figure)))
          (should (= (readq--get x :page) 2))
          (should (= (readq--get x :point) (- (point) 3)))
          (should (readq-figtest--png-p (readq--figure-file x))))))))

;;;; Okular: the clipboard

(ert-deftest readq-figtest-clipboard ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 30 "Heart"))
           (png (readq-figtest--png))
           (readq-ask-figure-caption nil)
           (clip nil))
      (cl-letf (((symbol-function 'gui-get-selection)
                 (lambda (_sel type) (and (eq type 'image/png) clip))))
        (should-error (readq-extract-figure-from-clipboard book 4) :type 'user-error)
        (setq clip png)
        (let ((x (readq-extract-figure-from-clipboard book 4)))
          (should (= (readq--get x :page) 4))
          (should (equal (readq--get x :title) "Figure: Heart, p. 4"))
          (should (readq-figtest--png-p (readq--figure-file x))))
        ;; Reading in Okular: the book of the external session, the page asked.
        (let ((readq--external-session (list :id (readq--get book :id))))
          (cl-letf (((symbol-function 'read-number) (lambda (&rest _) 9)))
            (with-temp-buffer
              (let ((x (call-interactively #'readq-extract-figure)))
                (should (= (readq--get x :page) 9))
                (should (equal (readq--get x :book) (readq--get book :id)))))))))))

;;;; Audio and video (mpv)

(ert-deftest readq-figtest-mpv-figure-key ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-add-book (readq-xtest--copy-fixture "clip.mkv") 20 "Clip"))
           (readq-mpv-args (list "--no-config" "--vo=null" "--ao=null"
                                 (concat "--script=" (expand-file-name "mpv-figure-test.lua"
                                                                       readq-mtest-dir)))))
      (readq-open book)
      (should (string-prefix-p "--script-opts-append=readq-figkey="
                               (readq-media-test--arg "--script-opts-append=readq-figkey")))
      (should (readq-media-test--wait (lambda () (plist-get readq--media-session :figures))))
      (let ((shots (plist-get readq--media-session :shots)))
        (readq-finish-session)
        (should-not (file-exists-p shots)))
      (let ((x (car (readq--extracts-of book t))))
        (should x)
        (should (readq--get x :figure))
        (should (< 0 (readq--get x :page) 3))
        (should (string-match-p "\\`Figure: Clip at 0:0[0-9]\\'" (readq--get x :title)))
        (should (readq-figtest--png-p (readq--figure-file x)))))))

(ert-deftest readq-figtest-mpv-audio-has-no-figure ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-media-test--book))
           (readq-mpv-args (list "--no-config" "--vo=null" "--ao=null"
                                 (concat "--script=" (expand-file-name "mpv-figure-test.lua"
                                                                       readq-mtest-dir)))))
      (readq-open book)
      (should (readq-media-test--wait
               (lambda () (> (or (plist-get readq--media-session :time) 0) 1.5))))
      (readq-finish-session)
      (should-not (readq--extracts-of book t)))))

(ert-deftest readq-figtest-frame-from-emacs ()
  (skip-unless (readq-media-test--mpv-p))
  (readq-media-test--with-db
    (let* ((book (readq-add-book (readq-xtest--copy-fixture "clip.mkv") 20 "Clip"))
           (readq-ask-figure-caption nil))
      ;; While it plays, the command takes the frame mpv last reported.
      (cl-letf (((symbol-function 'readq--media-playing-p) (lambda () t)))
        (let ((readq--media-session (list :id (readq--get book :id) :time 2.0)))
          (let ((x (readq-extract-figure)))
            (should (= (readq--get x :page) 2.0))
            (should (readq-figtest--png-p (readq--figure-file x)))))
        (let ((audio (readq-media-test--book)))
          (should-not (readq--media-frame audio 2.0))
          (let ((readq--media-session (list :id (readq--get audio :id) :time 2.0)))
            (should-error (readq-extract-figure) :type 'user-error)))))))

;;;; Flashcards

(ert-deftest readq-figtest-cards ()
  (readq-ctest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 20 "Heart"))
           (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png)
                                    :page 5 :caption "Name the waves"))
           (img (readq--figure-file x))
           (card (readq--make-card x)))
      (should (eq (plist-get card :type) 'basic))
      (should (equal (plist-get card :front) "Name the waves"))
      (should (equal (readq--card-images card) (list img)))
      ;; org-drill: an absolute link, even in a cloze card.
      (should (string-match-p (concat "\\*\\* Answer\n\\[\\[file:" (regexp-quote img) "\\]\\]")
                              (readq--drill-entry card)))
      (let ((cloze (list :item x :book book :type 'cloze :clozes 1 :front "F"
                         :text "The {{c1::P}} wave [[file:figs/a.png]] [1]"
                         :source "S")))
        (should (string-match-p
                 (concat "The \\[P\\] wave \\[\\[file:"
                         (regexp-quote (expand-file-name "lib/figs/a.png" readq-test--dir))
                         "\\]\\] (1)")
                 (readq--drill-entry cloze))))
      ;; Anki: an img tag naming the file in Anki's media folder.
      (let ((back (cdr (nth 1 (nth 2 (readq--anki-note card))))))
        (should (string-match-p (format "<img src=\"readq-%s\"" (file-name-nondirectory img))
                                back))))))

(ert-deftest readq-figtest-anki-file-media ()
  (readq-ctest--with-db
    (let* ((readq-anki-method 'file)
           (media (expand-file-name "collection.media/" readq-test--dir))
           (book (readq-add-book (readq-test--touch "lib/Heart.pdf") 20 "Heart"))
           (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png)
                                    :page 5 :caption "Name the waves"))
           warnings)
      (readq-mark-ready x)
      ;; Without a media folder: a warning says where to put the image.
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _) (push msg warnings))))
        (should (= (readq-export-cards 'anki) 1)))
      (should (string-match-p "collection.media" (car warnings)))
      (should (string-match-p (regexp-quote (readq--anki-media-name (readq--figure-file x)))
                              (car warnings)))
      (should (string-match-p "<img src=\"\"readq-" (readq-ctest--file readq-anki-export-file)))
      ;; With one, it is copied there.
      (make-directory media t)
      (let ((readq-anki-media-directory media)
            (y (readq--create-figure book (list :data (readq-figtest--png) :type 'png) :page 6)))
        (readq-mark-ready y)
        (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (error "Warned"))))
          (readq-export-cards 'anki))
        (should (file-exists-p (expand-file-name (readq--anki-media-name (readq--figure-file y))
                                                 media)))))))

(ert-deftest readq-figtest-ankiconnect-media ()
  (skip-unless (executable-find "python3"))
  (readq-ctest--with-db
    (let* ((log (expand-file-name "anki-requests.log" readq-test--dir))
           (server (readq-ctest--start-fake-anki log))
           (readq-anki-connect-url (cdr server))
           (readq-anki-method 'ankiconnect))
      (unwind-protect
          (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 20 "Heart"))
                 (x (readq--create-figure book (list :data (readq-figtest--png) :type 'png)
                                          :page 5 :caption "Name the waves"))
                 (name (readq--anki-media-name (readq--figure-file x))))
            (readq-mark-ready x)
            (should (= (readq-export-cards 'anki) 1))
            (let* ((json-object-type 'alist) (json-key-type 'string) (json-array-type 'list)
                   (requests (mapcar #'json-read-from-string
                                     (split-string (readq-ctest--file log) "\n" t)))
                   (store (cl-find "storeMediaFile" requests
                                   :key (lambda (r) (cdr (assoc "action" r))) :test #'equal))
                   (add (cl-position "addNote" requests
                                     :key (lambda (r) (cdr (assoc "action" r))) :test #'equal)))
              (should store)
              (should (equal (cdr (assoc "filename" (cdr (assoc "params" store)))) name))
              (should (equal (cdr (assoc "path" (cdr (assoc "params" store))))
                             (readq--figure-file x)))
              ;; The image is stored before the note that shows it.
              (should (< (cl-position store requests) add))))
        (delete-process (car server))))))

(provide 'readq-figure-test)
;;; readq-figure-test.el ends here
