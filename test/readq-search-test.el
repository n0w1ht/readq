;;; readq-search-test.el --- Tests for searching extracts -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-search-test.el \
;;     -f ert-run-tests-batch-and-exit
;; The consult tests run when consult (and compat) are on the load path.

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defmacro readq-setest--with-extracts (&rest body)
  "Run BODY with two books and their extracts, in separate folders.
Binds `heart', `kidney', `x-systole', `x-henle' and `x-gfr'."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq-extracts-directory nil)
           (readq--focus nil))
       (let* ((heart (readq-add-book (readq-test--touch "cardio/guyton-heart.pdf") 20
                                     "Guyton Heart" '("cardio")))
              (kidney (readq-add-book (readq-test--touch "renal/guyton-kidney.pdf") 30
                                      "Guyton Kidney" '("renal")))
              (x-systole (readq--create-extract heart "Systole is the phase of contraction."
                                                :page 57))
              (x-henle (readq--create-extract kidney "The loop of Henle concentrates urine."
                                              :page 12))
              (x-gfr (readq--create-extract kidney "Glomerular filtration rate is about 125 mL/min."
                                            :page 14 :tags '("exam"))))
         (ignore heart kidney x-systole x-henle x-gfr)
         ,@body))))

(defun readq-setest--consult-p ()
  "Return non-nil when consult can be loaded."
  (require 'consult nil t))

;;;; Files and paths

(ert-deftest readq-setest-extracts-files ()
  (readq-setest--with-extracts
    (let ((files (readq--extracts-files)))
      (should (= (length files) 2))
      (should (cl-every #'file-exists-p files))
      ;; Each lives next to its book.
      (should (cl-some (lambda (f) (string-match-p "/cardio/" f)) files))
      (should (cl-some (lambda (f) (string-match-p "/renal/" f)) files)))
    (should (equal (readq--extracts-files '("cardio"))
                   (list (expand-file-name (readq--get x-systole :file)))))
    (should (equal (readq--extracts-files '("exam"))
                   (list (expand-file-name (readq--get x-gfr :file)))))
    (should-not (readq--extracts-files '("derm")))))

(ert-deftest readq-setest-search-paths ()
  (let ((files '("/a/one/x.org" "/a/one/y.org" "/a/two/z.org")))
    (should (equal (readq--search-paths files) files))
    (let ((readq-search-max-command-length 20))
      (should (equal (readq--search-paths files) '("/a/one/" "/a/two/"))))))

(ert-deftest readq-setest-common-directory ()
  (let ((dir (file-name-as-directory (make-temp-file "readq-common" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "one" dir))
          (make-directory (expand-file-name "two" dir))
          (should (equal (readq--common-directory
                          (list (expand-file-name "one/a.org" dir)
                                (expand-file-name "two/b.org" dir)))
                         dir))
          (should (equal (readq--common-directory
                          (list (expand-file-name "one/a.org" dir)))
                         (expand-file-name "one/" dir))))
      (delete-directory dir t))))

;;;; readq-search

(ert-deftest readq-setest-search-uses-consult-ripgrep ()
  (skip-unless (and (readq-setest--consult-p) (executable-find "rg")))
  (readq-setest--with-extracts
    (let (called)
      (cl-letf (((symbol-function 'consult-ripgrep)
                 (lambda (dir &optional _initial) (setq called (list dir default-directory)))))
        (readq-search)
        (should (equal (sort (copy-sequence (car called)) #'string<)
                       (sort (readq--extracts-files) #'string<)))
        (should (equal (cadr called) (file-name-as-directory readq-test--dir)))
        ;; The focus limits the files searched.
        (let ((readq--focus '("cardio")))
          (readq-search)
          (should (equal (car called) (readq--extracts-files '("cardio")))))))))

(ert-deftest readq-setest-search-finds-text-with-ripgrep ()
  ;; What consult-ripgrep runs, on the paths readq-search gives it.
  (skip-unless (executable-find "rg"))
  (readq-setest--with-extracts
    (let* ((files (readq--extracts-files))
           (out (with-temp-buffer
                  (apply #'call-process "rg" nil t nil "-n" "--no-heading" "Henle" files)
                  (buffer-string))))
      (should (string-match-p "loop of Henle" out))
      (should (string-match-p "guyton-kidney" out))
      (should-not (string-match-p "guyton-heart" out)))))

(ert-deftest readq-setest-search-without-consult ()
  (readq-setest--with-extracts
    (let (called)
      (cl-letf (((symbol-function 'require)
                 (let ((orig (symbol-function 'require)))
                   (lambda (feature &rest args)
                     (unless (eq feature 'consult) (apply orig feature args)))))
                ((symbol-function 'read-regexp) (lambda (&rest _) "Henle"))
                ((symbol-function 'multi-occur)
                 (lambda (bufs re) (setq called (cons re (mapcar #'buffer-file-name bufs))))))
        (readq-search)
        (should (equal (car called) "Henle"))
        (should (= (length (cdr called)) 2))))))

(ert-deftest readq-setest-search-nothing ()
  (readq-xtest--with-db
    (should-error (readq-search) :type 'user-error)
    (should-error (readq-find-extract) :type 'user-error)))

;;;; readq-find-extract

(ert-deftest readq-setest-candidates ()
  (readq-setest--with-extracts
    (let ((cands (readq--extract-candidates nil)))
      (should (= (length cands) 3))
      (let ((gfr (car (rassq x-gfr cands))))
        (should (string-match-p "Glomerular filtration" gfr))
        (should (string-match-p "#exam" gfr))
        (should (string-match-p "#renal" gfr))
        (should (equal (readq--extract-group gfr nil) "Guyton Kidney"))
        (should (equal (readq--extract-group gfr t) gfr))
        (let ((ann (readq--extract-annotation gfr)))
          (should (string-match-p "p\\. 14" ann))
          (should (string-match-p "pri 30" ann))
          (should (string-match-p "due" ann)))))
    (should (equal (mapcar #'cdr (readq--extract-candidates '("cardio")))
                   (list x-systole)))))

(ert-deftest readq-setest-find-extract-completing-read ()
  (readq-setest--with-extracts
    (cl-letf (((symbol-function 'require)
               (let ((orig (symbol-function 'require)))
                 (lambda (feature &rest args)
                   (unless (eq feature 'consult) (apply orig feature args)))))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (let ((md (funcall table "" nil 'metadata)))
                   (should (eq (alist-get 'group-function (cdr md)) #'readq--extract-group)))
                 (cl-find-if (lambda (c) (string-match-p "loop of Henle" c))
                             (all-completions "" table)))))
      (readq-find-extract)
      (should (derived-mode-p 'org-mode))
      (should (equal (org-entry-get nil "READQ_ID") (readq--get x-henle :id)))
      ;; Showing an extract is not a review.
      (should-not readq-review-mode)
      (should (equal (readq--get x-henle :due) (readq--date-in 1))))))

(ert-deftest readq-setest-find-extract-consult ()
  (skip-unless (readq-setest--consult-p))
  (readq-setest--with-extracts
    (let (opts)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (cands &rest options)
                   (setq opts options)
                   ;; Narrowing to "due" and previewing work on the candidates.
                   (let ((pred (plist-get (plist-get options :narrow) :predicate))
                         (consult--narrow ?f))
                     (should-not (cl-some pred cands)))
                   (let ((state (plist-get options :state)))
                     (funcall state 'preview x-systole)
                     (should (equal (buffer-file-name)
                                    (expand-file-name (readq--get x-systole :file))))
                     (funcall state 'exit nil)
                     (funcall state 'return x-gfr))
                   x-gfr)))
        (readq-find-extract)
        (should (eq (plist-get opts :group) #'readq--extract-group))
        (should (equal (org-entry-get nil "READQ_ID") (readq--get x-gfr :id)))))))

(ert-deftest readq-setest-find-deleted-heading ()
  (readq-setest--with-extracts
    (with-current-buffer (find-file-noselect (readq--get x-henle :file))
      (widen)
      (goto-char (org-find-property "READQ_ID" (readq--get x-henle :id)))
      (org-cut-subtree)
      (save-buffer))
    (should-error (readq--goto-extract x-henle) :type 'user-error)))

;;;; Setup check

(ert-deftest readq-setest-doctor-ripgrep ()
  (readq-test--with-db
    (let ((readq-flashcard-backend 'org-drill)
          (readq-dashboard-icons nil))
      (cl-letf (((symbol-function 'executable-find)
                 (let ((orig (symbol-function 'executable-find)))
                   (lambda (name &rest args)
                     (unless (equal name "rg") (apply orig name args))))))
        (let ((rg (cl-find "ripgrep" (readq--doctor-checks) :key #'cadr :test #'equal)))
          (should (memq (car rg) (if (locate-library "consult") '(warn) '(info)))))))))

(provide 'readq-search-test)
;;; readq-search-test.el ends here
