;;; readq-canvas-test.el --- readq with pdf-canvas -*- lexical-binding: t; -*-

;; Run with pdf-canvas, built for the Emacs that runs the tests, on the
;; load path:
;;   emacs -Q --batch -L . -L test -L /path/to/pdf-canvas \
;;     -l test/readq-canvas-test.el -f ert-run-tests-batch-and-exit
;;
;; The tests are skipped where pdf-canvas or its module cannot be loaded.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-figure-test)
(require 'pdf-canvas nil t)

(defun readq-pctest--available-p ()
  "Return non-nil when pdf-canvas and its module can be used."
  (and (fboundp 'pdf-canvas--load-module)
       (ignore-errors (pdf-canvas--load-module) t)
       (fboundp 'pdf-canvas-selections)))

(defmacro readq-pctest--with-book (book &rest body)
  "Open outline.pdf in pdf-canvas as a queued book, bind it to BOOK, run BODY."
  (declare (indent 1))
  `(readq-ftest--with-db
     (let* ((file (readq-xtest--copy-fixture "outline.pdf"))
            (,book (readq-add-book file 30 "Outline"))
            (auto-mode-alist (cons '("\\.pdf\\'" . pdf-canvas-mode) auto-mode-alist))
            (magic-mode-alist nil)
            (pdf-canvas-prefetch nil)
            (readq-ask-figure-caption nil))
       (readq-mode 1)
       (unwind-protect
           (progn
             (readq-open ,book)
             (pdf-canvas--update)
             ,@body)
         (readq-mode -1)))))

(ert-deftest readq-pctest-session ()
  (skip-unless (readq-pctest--available-p))
  (readq-pctest--with-book book
    (should (eq major-mode 'pdf-canvas-mode))
    (should readq-book-mode)
    ;; Turning pages is recorded through pdf-canvas's page hook.
    (pdf-canvas-goto-page 5)
    (should (= (readq--get book :page) 5))
    (should (= (readq--get book :total) 8))
    (should (equal (readq--buffer-position) '(:page 5 :total 8)))
    (readq--restore-position '(:page 2))
    (should (= (pdf-canvas-current-page) 2))))

(ert-deftest readq-pctest-extract ()
  (skip-unless (readq-pctest--available-p))
  (readq-pctest--with-book book
    (should-error (readq-extract) :type 'user-error)
    ;; The two lines of page 2, selected by line.
    (pdf-canvas-add-selection '(:page 2 :ends (0.0 0.0 1.0 1.0) :mode 2))
    (let* ((sel (car (pdf-canvas-selections)))
           (x (readq-extract)))
      (should (string-match-p "Some text on page 2" (plist-get sel :text)))
      (should (= (readq--get x :page) 2))
      (should (equal (readq--get x :edges) (list (plist-get sel :edges))))
      (should (string-match-p "Some text on page 2"
                              (readq-xtest--org-text x)))
      ;; Extracting deselects.
      (should-not (pdf-canvas-selections)))))

(ert-deftest readq-pctest-figure ()
  (skip-unless (readq-pctest--available-p))
  (readq-pctest--with-book book
    (pdf-canvas-add-selection '(:page 3 :edges (0.1 0.1 0.6 0.3) :figure t))
    (let ((x (readq-extract-figure)))
      (should (= (readq--get x :page) 3))
      (should (readq-figtest--png-p (readq--figure-file x)))
      ;; At `readq-figure-dpi', half the page width.
      (let ((width (* 0.5 (car (pdf-canvas--page-size pdf-canvas--doc 2))
                      (/ readq-figure-dpi 72.0))))
        (should (< (abs (- (readq-figtest--png-width (readq--figure-file x))
                           width))
                   3)))
      (should-not (pdf-canvas-selections)))
    ;; A figure selected along with text goes into the same extract.
    (pdf-canvas-add-selection '(:page 4 :ends (0.0 0.0 1.0 1.0) :mode 2))
    (pdf-canvas-add-selection '(:page 4 :edges (0.2 0.2 0.5 0.5) :figure t))
    (let* ((readq-extract-multiple 'combine)
           (x (readq-extract)))
      (should (= (readq--get x :page) 4))
      (should (string-match-p "\\[\\[file:" (readq-xtest--org-text x))))))

(provide 'readq-canvas-test)
;;; readq-canvas-test.el ends here
