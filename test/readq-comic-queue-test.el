;;; readq-comic-queue-test.el --- Tests for comics (CBZ, CBR) in the queue -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -L ../readq-comic -l test/readq-comic-queue-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The viewer and the archivers are tested in readq-comic.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)

(defconst readq-ctest--pages
  '("Chapter 1/page1.png" "Chapter 1/page2.png" "Chapter 1/page10.png" "cover.png")
  "The pages of test/fixtures/comic.cbz in reading order.")

(defmacro readq-ctest--with-db (&rest body)
  "Run BODY with an empty database and readq-mode on."
  (declare (indent 0))
  `(readq-ftest--with-db
     (let ((readq-comic-program nil)
           (readq-default-comic-viewer 'emacs)
           (readq-ask-figure-caption nil))
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (with-current-buffer b (derived-mode-p 'readq-comic-mode))
             (with-current-buffer b (when readq-book-mode (readq-book-mode -1)))
             (kill-buffer b)))))))

(defun readq-ctest--program (name)
  "Return the archiver NAME if installed (bsdtar: a tar that is bsdtar)."
  (let ((p (executable-find name)))
    (and p (or (not (equal name "bsdtar")) (readq-comic--bsdtar-p p)) p)))

(defmacro readq-ctest--each-program (names &rest body)
  "Run BODY with `readq-comic-program' set to each of NAMES installed."
  (declare (indent 1))
  `(let ((found nil))
     (dolist (name ,names)
       (when-let ((p (readq-ctest--program name)))
         (setq found t)
         (let ((readq-comic-program p))
           ,@body)))
     (unless found (ert-skip "No archiver installed"))))

(ert-deftest readq-ctest-format ()
  (should (eq (readq--format "/x/Watchmen.cbz") 'comic))
  (should (eq (readq--format "/x/Watchmen.CBR") 'comic))
  (should (readq--page-format-p 'comic)))

;;;; Reading

(ert-deftest readq-ctest-read-and-track ()
  (skip-unless (cl-some #'readq-ctest--program '("7z" "bsdtar" "unzip")))
  (readq-ctest--with-db
    (let* ((file (readq-xtest--copy-fixture "comic.cbz" "Watchmen.cbz"))
           (book (readq-add-book file 20 "Watchmen")))
      (should (eq (readq--get book :format) 'comic))
      (should (= (readq--get book :total) 4))
      (should (equal (readq--kind book) "comic"))
      (should (equal (readq--position-string book) "-"))
      (readq-open book)
      (readq-ftest--run-timers)
      (should (derived-mode-p 'readq-comic-mode))
      (should readq-book-mode)
      (should (eq (readq--buffer-book) book))
      (should (= (readq-comic-current-page) 1))
      (should (string-match-p "Page 1 of 4" (buffer-string)))
      (readq-comic-next-page)
      (readq-comic-next-page)
      (should (= (readq--get book :page) 3))
      (should (= (readq--get book :progress) 0.75))
      (should-not (readq--at-end-p book))
      (kill-buffer (current-buffer))
      (should (= (readq--get book :sessions) 1))
      ;; Back where you left it.
      (readq-open book)
      (readq-ftest--run-timers)
      (should (= (readq-comic-current-page) 3))
      (readq-comic-last-page)
      (should (readq--at-end-p book))
      (should (equal mode-line-process " 4/4"))
      ;; Opening it again reuses the buffer.
      (let ((buf (current-buffer)))
        (should (eq (readq-open-comic file) buf))))))

(ert-deftest readq-ctest-not-queued ()
  (skip-unless (cl-some #'readq-ctest--program '("7z" "bsdtar" "unzip")))
  (readq-ctest--with-db
    (let ((file (readq-xtest--copy-fixture "comic.cbz")))
      (readq-open-comic file)
      (should (derived-mode-p 'readq-comic-mode))
      (should-not readq-book-mode)
      (readq-comic-next-page)
      (should-error (readq-extract nil) :type 'user-error))))

(ert-deftest readq-ctest-sections ()
  (readq-ctest--with-db
    (let* ((book (readq-add-book (readq-test--touch "lib/Saga.cbz") 20 "Saga")))
      (readq--put book :total 120)
      (readq--put book :format 'comic)
      (let ((s (readq-add-section book "Chapter 2" 30 60 20)))
        (should (equal (readq--section-location s) "p 30–60"))
        (should (equal (readq--item-size s) '(31.0 . "p")))
        (readq--put s :page 45)
        (should (equal (readq--position-string s) "p 45 (30–60)"))))))

(ert-deftest readq-ctest-figure ()
  (skip-unless (cl-some #'readq-ctest--program '("7z" "bsdtar" "unzip")))
  (readq-ctest--with-db
    (let* ((file (readq-xtest--copy-fixture "comic.cbz" "Maus.cbz"))
           (book (readq-add-book file 20 "Maus")))
      (readq-open book)
      (readq-ftest--run-timers)
      (readq-comic-goto-page 2)
      (let ((x (readq-extract-figure)))
        (should (= (readq--get x :page) 2))
        (should (equal (readq--get x :book) (readq--get book :id)))
        (let ((img (readq--figure-file x)))
          (should (string-match-p "_p2\\.png\\'" img))
          (should (= (file-attribute-size (file-attributes img)) 86))))
      ;; The figure's source link shows that page.
      (readq-comic-first-page)
      (readq--visit-location book 4)
      (should (= (readq-comic-current-page) 4)))))

(ert-deftest readq-ctest-sumatra-viewer ()
  (readq-ctest--with-db
    (let ((book (readq-add-book (readq-test--touch "x.cbr") 20)))
      (readq--put book :format 'comic)
      (should (eq (readq--viewer book) 'emacs))
      (let ((readq-default-comic-viewer 'sumatra)
            (readq-default-pdf-viewer 'emacs))
        (should (eq (readq--viewer book) 'sumatra)))
      (readq-set-viewer book 'sumatra)
      (should (eq (readq--viewer book) 'sumatra))
      (should (equal (readq--kind book) "sumatra")))))

(ert-deftest readq-ctest-doctor ()
  (readq-ctest--with-db
    (let ((readq-flashcard-backend 'org-srs)
          (readq-dashboard-icons nil))
      (let ((check (lambda ()
                     (car (cl-find "Comics" (readq--doctor-checks)
                                   :key #'cadr :test #'equal)))))
        (cl-letf (((symbol-function 'readq-comic-programs) #'ignore))
          (should (eq (funcall check) 'info))
          (readq--put (readq-add-book (readq-test--touch "x.cbz") 20) :format 'comic)
          (should (eq (funcall check) 'fail)))
        (cl-letf (((symbol-function 'readq-comic-programs)
                   (lambda () '((unzip . "/bin/unzip")))))
          (should (eq (funcall check) 'warn)))
        (cl-letf (((symbol-function 'readq-comic-programs)
                   (lambda () '((7z . "/bin/7z")))))
          (should (eq (funcall check) 'ok)))))))

(provide 'readq-comic-queue-test)
;;; readq-comic-queue-test.el ends here
