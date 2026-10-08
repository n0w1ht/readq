;;; readq-highlight-test.el --- Highlights of extracts in books -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-highlight-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The EPUB tests need nov.el and zip; the multi-region test needs
;; multi-region 0.2 on the load path.

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-sections-test)
(require 'multi-region nil t)

(defconst readq-htest--para1
  "The heart is a muscular organ that pumps blood through the blood vessels of the circulatory system.  Blood provides the body with oxygen and nutrients, as well as assisting in the removal of metabolic wastes.")

(defconst readq-htest--para2
  "In humans, the heart is approximately the size of a closed fist and is located between the lungs, in the middle compartment of the chest, called the mediastinum.")

(defmacro readq-htest--with-epub (&rest body)
  "Run BODY in a nov.el buffer of a queued EPUB with two paragraphs."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((nov-save-place-file nil)
            (auto-mode-alist (cons '("\\.epub\\'" . nov-mode) auto-mode-alist))
            (f (expand-file-name "heart.epub" readq-test--dir))
            (transient-mark-mode t))
       (readq-stest--make-epub f "3.0"
                               (list (concat readq-htest--para1 "</p><p>" readq-htest--para2))
                               '(("One" 1)))
       (let ((book (readq-add-book f 20)))
         (readq-mode 1)
         (readq-open book)
         (nov-goto-document 1)
         (unwind-protect (progn ,@body)
           (kill-buffer (current-buffer)))))))

(defun readq-htest--range (from to)
  "Return (BEG . END) of the text from regexp FROM to the end of regexp TO."
  (goto-char (point-min))
  (re-search-forward from)
  (let ((beg (match-beginning 0)))
    (re-search-forward to)
    (cons beg (point))))

(defun readq-htest--highlights ()
  "Return the (BEG . END) of readq's highlights in this buffer, in order."
  (sort (mapcar (lambda (o) (cons (overlay-start o) (overlay-end o)))
                (cl-remove-if-not (lambda (o) (overlay-get o 'readq-extract))
                                  (overlays-in (point-min) (point-max))))
        (lambda (a b) (< (car a) (car b)))))

(defun readq-htest--select (range)
  "Make RANGE the active region."
  (goto-char (car range))
  (set-mark (car range))
  (goto-char (cdr range))
  (activate-mark))

(ert-deftest readq-htest-epub-region-across-paragraphs ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-htest--with-epub
    ;; From the middle of one paragraph into the next: nov.el's paragraph
    ;; break has more whitespace than the extract's text.
    (let ((range (readq-htest--range "Blood[ \n]+provides" "the[ \n]+lungs,")))
      (readq-htest--select range)
      (let ((x (readq-extract)))
        (should (< (length (readq--get x :snippet)) (- (cdr range) (car range))))
        (should (equal (readq-htest--highlights) (list range)))
        ;; Still exact when the chapter is shown again.
        (nov-goto-document 1)
        (should (equal (readq-htest--highlights)
                       (list (readq-htest--range "Blood[ \n]+provides" "the[ \n]+lungs,"))))))))

(ert-deftest readq-htest-epub-old-extract-without-tail ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")))
  (readq-htest--with-epub
    ;; Extracts made before readq stored passages' last words are
    ;; measured the way their text was cleaned up.
    (let ((range (readq-htest--range "Blood[ \n]+provides" "the[ \n]+lungs,")))
      (readq-htest--select range)
      (let ((x (readq-extract)))
        (readq--put x :tail nil)
        (readq--decorate-extracts)
        (should (equal (readq-htest--highlights) (list range)))))))

(ert-deftest readq-htest-epub-multi-region-combined ()
  (skip-unless (and (require 'nov nil t) (executable-find "zip")
                    (fboundp 'multi-region-selections)))
  (readq-htest--with-epub
    (multi-region-mode 1)
    (let ((r1 (readq-htest--range "muscular[ \n]+organ" "metabolic[ \n]+wastes\\."))
          (r2 (readq-htest--range "located[ \n]+between" "the[ \n]+mediastinum\\.")))
      (multi-region--add (car r1) (cdr r1))
      (multi-region--add (car r2) (cdr r2))
      (readq-extract)
      (should (equal (readq-htest--highlights) (list r1 r2))))))

(ert-deftest readq-htest-eww-region ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write
                  "web/heart.html"
                  (format "<html><body><p>%s</p><p>%s</p></body></html>"
                          readq-htest--para1 readq-htest--para2)))
           (book (readq-add-book file 20))
           (transient-mark-mode t))
      (readq-open book)
      (readq-ftest--run-timers)
      (let ((range (readq-htest--range "Blood[ \n]+provides" "the[ \n]+lungs,")))
        (readq-htest--select range)
        (readq-extract)
        (should (equal (readq-htest--highlights) (list range)))))))

(ert-deftest readq-htest-text-region ()
  (readq-ftest--with-db
    (let* ((file (readq-ftest--write "lib/heart.org"
                                     (concat "* Heart\n" readq-htest--para1 "\n\n"
                                             readq-htest--para2 "\n")))
           (book (readq-add-book file 20))
           (transient-mark-mode t))
      (readq-open book)
      (readq-ftest--run-timers)
      (let ((range (readq-htest--range "Blood provides" "the lungs,")))
        (readq-htest--select range)
        (readq-extract)
        (should (equal (readq-htest--highlights) (list range)))))))

(ert-deftest readq-htest-passage-end-repeated-tail ()
  ;; The last words may also appear earlier: the end nearest the
  ;; expected length wins.
  (with-temp-buffer
    (insert "the end of it. More words follow here and the end of it.")
    (should (= (readq--passage-end 1 (list :length 56 :tail "the end of it.") nil) 57))
    (should (= (readq--passage-end 1 (list :length 14 :tail "the end of it.") nil) 15))))

(provide 'readq-highlight-test)
;;; readq-highlight-test.el ends here
