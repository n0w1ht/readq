;;; readq-mixed-test.el --- Extracts of passages and pictures -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-mixed-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; multi-region (0.4 or later) reports pictures in its selections; here
;; its `multi-region-selections' is imitated, so it need not be loaded.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-figure-test)
(require 'readq-multi-region-test)

(defmacro readq-mxtest--selections (sels &rest body)
  "Run BODY with multi-region reporting the selections SELS."
  (declare (indent 1))
  `(let ((cleared nil))
     (cl-letf (((symbol-function 'readq--multi-region-p) (lambda () t))
               ((symbol-function 'multi-region-selections) (lambda (&rest _) ,sels))
               ((symbol-function 'multi-region-clear) (lambda () (setq cleared t))))
       ,@body
       (should cleared))))

(defconst readq-mxtest--org
  "* Heart
The cardiac cycle: X then the valves close. More text.
")

(defun readq-mxtest--diagram ()
  "Copy the diagram fixture into the test directory and return it."
  (readq-xtest--copy-fixture "diagram.png" "pic.png"))

(defun readq-mxtest--entry (x)
  "Return the Org entry of extract X."
  (with-temp-buffer
    ;; The PDF tests don't save buffers: read the one visiting the file.
    (let ((buf (find-buffer-visiting (readq--get x :file))))
      (if buf (insert-buffer-substring buf) (insert-file-contents (readq--get x :file))))
    (org-mode)
    (goto-char (org-find-property "READQ_ID" (readq--get x :id)))
    (buffer-substring (line-beginning-position 0)
                      (save-excursion (org-end-of-subtree t) (point)))))

(defmacro readq-mxtest--with-org-book (&rest body)
  "Run BODY in a queued Org book showing `readq-mxtest--org'.
`x-pos' is where the X stands for a picture."
  (declare (indent 0))
  `(readq-ftest--with-db
     (let ((book (readq-add-book (readq-ftest--write "lib/heart.org" readq-mxtest--org)
                                 20 "Heart")))
       (readq-open book)
       (let ((x-pos (save-excursion (goto-char (point-min)) (search-forward "X") (1- (point))))
             (cycle (save-excursion (goto-char (point-min)) (search-forward "The") (- (point) 3)))
             (close (save-excursion (goto-char (point-min)) (search-forward "close.") (point))))
         (ignore x-pos cycle close)
         ,@body))))

;;;; Splitting a selection

(ert-deftest readq-mxtest-selection-pieces ()
  (let ((sel (list :beg 10 :end 30 :text "Before  XX  after it"
                   :images (list (list :beg 18 :end 20 :file "/a.png")))))
    (should (equal (readq--selection-pieces sel #'string-trim)
                   '((:text "Before" :beg 10)
                     (:image (:file "/a.png") :beg 18)
                     (:text "after it" :beg 20)))))
  ;; A picture at either end leaves no empty passage; data stays data.
  (let ((sel (list :beg 1 :end 3 :text "XY"
                   :images (list (list :beg 2 :end 3 :data "img" :type 'png)
                                 (list :beg 1 :end 2 :file "/b.png")))))
    (should (equal (readq--selection-pieces sel #'string-trim)
                   '((:image (:file "/b.png") :beg 1)
                     (:image (:data "img" :type png) :beg 2)))))
  ;; Without pictures, the selection is one passage, as before.
  (should (equal (readq--selection-pieces (list :beg 5 :end 9 :text " abc ") #'string-trim)
                 '((:text "abc" :beg 5)))))

;;;; Text books

(ert-deftest readq-mxtest-passage-and-picture ()
  (readq-mxtest--with-org-book
    (let* ((pic (readq-mxtest--diagram))
           (sel (list :beg cycle :end close
                      :text (buffer-substring-no-properties cycle close)
                      :images (list (list :beg x-pos :end (1+ x-pos) :file pic)))))
      (readq-mxtest--selections (list sel)
        (let* ((x (readq-extract))
               (files (readq--figure-files x))
               (entry (readq-mxtest--entry x)))
          (should (readq--extract-p x))
          (should-not (readq--get x :figure))
          (should (= (length files) 1))
          (should (readq-figtest--png-p (car files)))
          (should (equal (file-name-directory (car files))
                         (expand-file-name readq-figures-directory)))
          (should (string-match-p "\\`heart_.*_s1\\.png\\'" (file-name-nondirectory (car files))))
          ;; Passage, picture, passage, in the order they were read.
          (should (string-match-p
                   (concat "#\\+begin_quote\nThe cardiac cycle:\n#\\+end_quote\n"
                           "\\[\\[file:" (regexp-quote (abbreviate-file-name (car files)))
                           "\\]\\]\n"
                           "#\\+begin_quote\nthen the valves close\\.\n#\\+end_quote")
                   entry))
          ;; Its text is the passages, without the picture's placeholder.
          (should (equal (readq--get x :snippet)
                         "The cardiac cycle:\n\nthen the valves close."))
          (should (equal (readq--get x :title) "The cardiac cycle: then the valves close."))
          (should (= (length (readq--get x :parts)) 2))
          ;; The original picture is copied, not moved.
          (should (file-exists-p pic))
          ;; Deleting the extract deletes its pictures.
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
            (readq-delete-extract x))
          (should-not (file-exists-p (car files))))))))

(ert-deftest readq-mxtest-separate ()
  ;; C-u C-u: each picture a figure extract, each passage an extract.
  (readq-mxtest--with-org-book
    (let ((sel (list :beg cycle :end close
                     :text (buffer-substring-no-properties cycle close)
                     :images (list (list :beg x-pos :end (1+ x-pos)
                                         :data (readq-figtest--png) :type 'png)))))
      (readq-mxtest--selections (list sel)
        (let ((xs (readq-extract '(16))))
          (should (= (length xs) 3))
          (should-not (readq--get (nth 0 xs) :figure))
          (should (readq--get (nth 1 xs) :figure))
          (should (readq-figtest--png-p (readq--figure-file (nth 1 xs))))
          (should (equal (readq--get (nth 2 xs) :snippet) "then the valves close.")))))))

(ert-deftest readq-mxtest-pictures-only ()
  (readq-mxtest--with-org-book
    (let ((pic (readq-mxtest--diagram)))
      ;; One picture alone: a figure extract.
      (readq-mxtest--selections
          (list (list :beg x-pos :end (1+ x-pos) :text "X"
                      :images (list (list :beg x-pos :end (1+ x-pos) :file pic))))
        (let ((x (readq-extract)))
          (should (readq--get x :figure))
          (should (string-prefix-p "Figure: Heart" (readq--get x :title)))))
      ;; Two: one extract of both, named after its place.
      (readq-mxtest--selections
          (list (list :beg x-pos :end (1+ x-pos) :text "X"
                      :images (list (list :beg x-pos :end (1+ x-pos) :file pic)))
                (list :beg (1- close) :end close :text "."
                      :images (list (list :beg (1- close) :end close :file pic))))
        (let* ((x (readq-extract))
               (files (readq--figure-files x)))
          (should (string-prefix-p "Figures: Heart" (readq--get x :title)))
          (should (= (length files) 2))
          (should-not (equal (car files) (cadr files)))
          (should-not (readq--get x :parts)))))))

(ert-deftest readq-mxtest-sub-extract ()
  ;; A sub-extract of an extract with a picture keeps the picture.
  (readq-mxtest--with-org-book
    (let* ((book (readq--buffer-book))
           (x (readq--create-extract book "Alpha beta gamma." :point 3))
           (pic (readq-mxtest--diagram)))
      (readq--put x :due (readq--today))
      (should (readq-open x))
      (goto-char (point-min))
      (search-forward "Alpha")
      (let* ((beg (- (point) 5))
             (sel (list :beg beg :end (+ beg 17) :text "Alpha beta gamma."
                        :images (list (list :beg (+ beg 6) :end (+ beg 10) :file pic)))))
        (readq-mxtest--selections (list sel)
          (let ((sub (readq-extract)))
            (should (equal (readq--get sub :parent) (readq--get x :id)))
            (should (= (length (readq--figure-files sub)) 1))
            (should (equal (readq--get sub :snippet) "Alpha\n\ngamma."))))))))

;;;; PDFs

(ert-deftest readq-mxtest-pdf ()
  (readq-mtest--with-pdf
    (setq page 2)
    (let (crops)
      (cl-letf (((symbol-function 'readq--pdf-crop)
                 (lambda (_file page edges) (push (cons page edges) crops)
                   (readq-figtest--png))))
        (readq-mxtest--selections
            (list (list :page 2 :edges '(0.1 0.1 0.9 0.2) :text "Text 2 at 0.1.")
                  (list :page 2 :edges '(0.2 0.3 0.8 0.6) :text "" :figure t)
                  (list :page 2 :edges '(0.1 0.7 0.9 0.8) :text "Text 2 at 0.7."))
          (let* ((x (readq-extract))
                 (entry (readq-mxtest--entry x)))
            ;; The area is cropped, not highlighted; the passages are.
            (should (equal crops '((2 0.2 0.3 0.8 0.6))))
            (should (= (length readq-mtest--annotations) 2))
            (should (= (length (readq--figure-files x)) 1))
            (should (string-match-p "_p2\\.png\\'" (car (readq--figure-files x))))
            (should (string-match-p
                     "Text 2 at 0\\.1\\.\n#\\+end_quote\n\\[\\[file:[^]]+\\]\\]\n#\\+begin_quote\nText 2 at 0\\.7"
                     entry))
            (should (equal (mapcar (lambda (p) (plist-get p :page)) (readq--get x :parts))
                           '(2 2)))
            (should (equal (readq--get x :edges) '((0.1 0.1 0.9 0.2))))))))))

(ert-deftest readq-mxtest-without-pictures-unchanged ()
  (readq-mtest--with-pdf
    (readq-mxtest--selections
        (list (list :page 1 :edges '(0.1 0.1 0.5 0.2) :text "Text 1 at 0.1.")
              (list :page 1 :edges '(0.1 0.5 0.5 0.6) :text "Text 1 at 0.5."))
      (let ((x (readq-extract)))
        (should-not (readq--get x :figures))
        (should (string-match-p "#\\+begin_quote\nText 1 at 0\\.1\\.\n\nText 1 at 0\\.5\\.\n#\\+end_quote"
                                (readq-mxtest--entry x)))))))

(provide 'readq-mixed-test)
;;; readq-mixed-test.el ends here
