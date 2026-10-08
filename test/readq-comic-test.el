;;; readq-comic-test.el --- Tests for comics (CBZ, CBR) -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-comic-test.el \
;;     -f ert-run-tests-batch-and-exit
;; Each archiver's tests run when it is installed (7z, bsdtar, unzip).

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
    (and p (or (not (equal name "bsdtar")) (readq--bsdtar-p p)) p)))

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

;;;; Archives

(ert-deftest readq-ctest-format ()
  (should (eq (readq--format "/x/Watchmen.cbz") 'comic))
  (should (eq (readq--format "/x/Watchmen.CBR") 'comic))
  (should (readq--page-format-p 'comic)))

(ert-deftest readq-ctest-archive-kind ()
  (readq-test--with-db
    (should (eq (readq--comic-kind (readq-xtest--copy-fixture "comic.cbz")) 'zip))
    (should (eq (readq--comic-kind (readq-xtest--copy-fixture "comic.cb7")) '7z))
    ;; A .cbr is often a ZIP renamed: what counts is its contents.
    (should (eq (readq--comic-kind (readq-xtest--copy-fixture "comic.cbz" "renamed.cbr")) 'zip))
    (let ((rar (expand-file-name "real.cbr" readq-test--dir)))
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file rar (set-buffer-multibyte nil) (insert "Rar!\032\007\001\000rest")))
      (should (eq (readq--comic-kind rar) 'rar)))
    (should-not (readq--comic-kind (readq-test--touch "plain.cbz")))))

(ert-deftest readq-ctest-tool-kinds ()
  (should (eq (readq--comic-tool-kind "C:/Program Files/7-Zip/7z.exe") '7z))
  (should (eq (readq--comic-tool-kind "/usr/bin/7za") '7z))
  (should (eq (readq--comic-tool-kind "C:/Windows/System32/tar.exe") 'bsdtar))
  (should (eq (readq--comic-tool-kind "/usr/bin/bsdtar") 'bsdtar))
  (should (eq (readq--comic-tool-kind "unzip") 'unzip))
  (should (eq (readq--comic-tool-kind "UnRAR.exe") 'unrar)))

(ert-deftest readq-ctest-pages-cbz ()
  (readq-test--with-db
    (let ((file (readq-xtest--copy-fixture "comic.cbz" "My Comic [1].cbz")))
      (readq-ctest--each-program '("7z" "bsdtar" "unzip")
        ;; Images only, without macOS's leftovers, in natural order.
        (should (equal (readq--comic-page-list file) readq-ctest--pages))
        (should (= (readq--comic-count-pages file) 4))
        (let ((data (readq--comic-page-data file "Chapter 1/page1.png")))
          (should (= (length data) 89))
          (should-not (multibyte-string-p data))
          (should (eq (image-type-from-data data) 'png)))
        (should (= (length (readq--comic-page-data file "cover.png")) 85))))))

(ert-deftest readq-ctest-pages-cb7-and-renamed ()
  (readq-test--with-db
    (let ((cb7 (readq-xtest--copy-fixture "comic.cb7"))
          (cbr (readq-xtest--copy-fixture "comic.cbz" "renamed.cbr")))
      (readq-ctest--each-program '("7z" "bsdtar")
        (should (equal (readq--comic-page-list cb7)
                       (remove "info.txt" readq-ctest--pages)))
        (should (= (length (readq--comic-page-data cb7 "Chapter 1/page2.png")) 86))
        (should (equal (readq--comic-page-list cbr) readq-ctest--pages)))
      ;; unzip reads the ZIP whatever its name, but not 7z.
      (when-let ((unzip (readq-ctest--program "unzip")))
        (let ((readq-comic-program unzip))
          (should (equal (readq--comic-page-list cbr) readq-ctest--pages))
          (should-error (readq--comic-page-list cb7) :type 'user-error))))))

(ert-deftest readq-ctest-finding-a-program ()
  (readq-test--with-db
    (let ((zip (readq-xtest--copy-fixture "comic.cbz"))
          (cb7 (readq-xtest--copy-fixture "comic.cb7"))
          (found '("unzip")))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name &rest _) (and (member name found) (concat "/bin/" name))))
                ((symbol-function 'file-executable-p) #'ignore))
        (should (equal (readq--comic-program zip) '(unzip . "/bin/unzip")))
        (should-error (readq--comic-program cb7) :type 'user-error)
        ;; 7-Zip comes first, and reads everything.
        (setq found '("unzip" "7z"))
        (should (equal (readq--comic-program zip) '(7z . "/bin/7z")))
        (should (equal (readq--comic-program cb7) '(7z . "/bin/7z")))
        ;; A tar that is not bsdtar (GNU tar) cannot read ZIP or RAR.
        (setq found '("tar"))
        (cl-letf (((symbol-function 'readq--bsdtar-p) #'ignore))
          (should-error (readq--comic-program zip) :type 'user-error))
        (cl-letf (((symbol-function 'readq--bsdtar-p) (lambda (_) t)))
          (should (equal (readq--comic-program zip) '(bsdtar . "/bin/tar"))))))))

(ert-deftest readq-ctest-commands ()
  ;; The arguments each archiver gets, unrar's included.
  (readq-test--with-db
    (let ((rar (expand-file-name "real.cbr" readq-test--dir))
          calls)
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file rar (set-buffer-multibyte nil) (insert "Rar!\032\007\000")))
      (cl-letf (((symbol-function 'readq--comic-run)
                 (lambda (tool &rest args) (push (cons (car tool) args) calls)
                   (if (member "lb" args) "b/2.jpg\nb/1.jpg\nnotes.txt\n" "data"))))
        (let ((readq-comic-program "/bin/unrar"))
          (should (equal (readq--comic-page-list rar) '("b/1.jpg" "b/2.jpg")))
          (readq--comic-page-data rar "b/1.jpg")
          (should (equal (car calls) (list 'unrar "p" "-inul" "--" rar "b/1.jpg"))))
        (let ((readq-comic-program "/bin/unzip")
              (zip (readq-xtest--copy-fixture "comic.cbz")))
          ;; unzip's wildcards are escaped.
          (readq--comic-page-data zip "a[1]*.png")
          (should (equal (car calls) (list 'unzip "-p" "--" zip "a[[]1[]][*].png"))))))))

(ert-deftest readq-ctest-archiver-failure ()
  (readq-test--with-db
    (let ((bad (readq-test--touch "broken.cbz")))
      (let ((coding-system-for-write 'no-conversion))
        (with-temp-file bad (set-buffer-multibyte nil) (insert "PK\003\004broken")))
      (readq-ctest--each-program '("7z" "bsdtar" "unzip")
        (should-error (readq--comic-page-list bad))
        (should-not (readq--comic-count-pages bad))))))

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
      (should (= readq--comic-page 1))
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
      (should (= readq--comic-page 3))
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
      (readq-comic-goto-page 99)
      (should (= readq--comic-page 4))
      (readq-comic-previous-page 2)
      (should (= readq--comic-page 2))
      (readq-comic-first-page)
      (readq-comic-previous-page)
      (should (= readq--comic-page 1))
      (readq-comic-fit-width)
      (should (eq readq--comic-fit 'width))
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
      (should (= readq--comic-page 4)))))

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
    (let ((readq-flashcard-backend 'org-drill)
          (readq-dashboard-icons nil))
      (let ((check (lambda ()
                     (car (cl-find "Comics" (readq--doctor-checks)
                                   :key #'cadr :test #'equal)))))
        (cl-letf (((symbol-function 'readq--comic-programs) #'ignore))
          (should (eq (funcall check) 'info))
          (readq--put (readq-add-book (readq-test--touch "x.cbz") 20) :format 'comic)
          (should (eq (funcall check) 'fail)))
        (cl-letf (((symbol-function 'readq--comic-programs)
                   (lambda () '((unzip . "/bin/unzip")))))
          (should (eq (funcall check) 'warn)))
        (cl-letf (((symbol-function 'readq--comic-programs)
                   (lambda () '((7z . "/bin/7z")))))
          (should (eq (funcall check) 'ok)))))))

(provide 'readq-comic-test)
;;; readq-comic-test.el ends here
