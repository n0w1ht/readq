;;; readq-tags-test.el --- Tests for readq tags -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-tags-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-cards-test)

(defmacro readq-ttest--with-library (&rest body)
  "Run BODY with three due books: cardio (50), leisure (10), untagged (30)."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let* ((cardio (readq-add-book (readq-test--touch "cardio.pdf") 50 "Cardio book"
                                    '("#Cardio")))
            (novel (readq-add-book (readq-test--touch "novel.epub") 10 "Novel"
                                   '("leisure")))
            (plain (readq-add-book (readq-test--touch "plain.pdf") 30 "Plain")))
       (ignore cardio novel plain)
       ,@body)))

(defun readq-ttest--next (&optional tags)
  "Run `readq-next' with TAGS and return the item it opened."
  (let (opened)
    (cl-letf (((symbol-function 'readq-open) (lambda (item) (setq opened item) t)))
      (with-temp-buffer (readq-next tags)))
    opened))

;;;; Tags themselves

(ert-deftest readq-ttest-normalize ()
  (should (equal (readq--normalize-tag "#Cardio") "cardio"))
  (should (equal (readq--normalize-tag " heart failure ") "heart_failure"))
  (should (equal (readq--normalize-tag "pre-clinical") "pre_clinical"))
  (should (equal (readq--normalize-tags '("#cardio" "Cardio" "#" "" "leisure"))
                 '("cardio" "leisure"))))

(ert-deftest readq-ttest-read-tags-separators ()
  ;; Commas and spaces both separate tags in the minibuffer.
  (cl-letf (((symbol-function 'completing-read-multiple)
             (lambda (&rest _) (split-string "#Cardio, leisure  renal" crm-separator t))))
    (should (equal (readq--read-tags "Tags: ") '("cardio" "leisure" "renal"))))
  (cl-letf (((symbol-function 'completing-read-multiple) (lambda (&rest _) nil)))
    (should-not (readq--read-tags "Tags: "))
    (should-error (readq--read-tags "Tags: " nil t) :type 'user-error)))

(ert-deftest readq-ttest-add-and-set ()
  (readq-ttest--with-library
    (should (equal (readq--get cardio :tags) '("cardio")))
    (should-not (readq--get plain :tags))
    (readq-set-tags plain '("#Renal" "cardio"))
    (should (equal (readq--item-tags plain) '("renal" "cardio")))
    (should (equal (readq--all-tags) '("cardio" "leisure" "renal")))
    ;; Saved with the book.
    (setq readq--books nil readq--loaded nil)
    (should (equal (readq--get (readq--book-by-file (readq--get plain :file)) :tags)
                   '("renal" "cardio")))))

(ert-deftest readq-ttest-add-directory-with-tags ()
  (readq-xtest--with-db
    (readq-test--touch "lib/a.pdf")
    (readq-test--touch "lib/b.epub")
    (readq-add-directory (expand-file-name "lib" readq-test--dir) 40 '("cardio"))
    (should (= 2 (cl-count-if (lambda (b) (equal (readq--get b :tags) '("cardio")))
                              (readq--books))))))

;;;; Inheritance

(ert-deftest readq-ttest-sections-and-extracts-inherit ()
  (readq-ftest--with-db
    (let* ((book (readq-add-book (readq-ftest--write "lib/notes.org" readq-ftest--org)
                                 50 "Notes" '("physiology")))
           (systole (readq--make-section book (nth 1 (readq--book-outline book)) 10))
           (transient-mark-mode t))
      (readq-set-tags systole '("cardio"))
      (should (equal (readq--item-tags systole) '("cardio" "physiology")))
      (should (readq--tags-match-p systole '("physiology")))
      ;; An extract made while reading the section has its tags too.
      (readq-open systole)
      (readq-ftest--run-timers)
      (readq-ftest--select "Systole is the phase[^.]*\\.")
      (let ((x (readq-extract)))
        (should (equal (readq--get x :tags) '("cardio")))
        (should (equal (readq--item-tags x) '("cardio" "physiology"))))
      ;; Tagging the book later reaches everything that comes from it.
      (readq-set-tags book '("physiology" "exam"))
      (should (member "exam" (readq--item-tags systole))))))

;;;; Reading by tag

(ert-deftest readq-ttest-queue-by-tag ()
  (readq-ttest--with-library
    (should (equal (readq--queue) (list novel plain cardio)))
    (should (equal (readq--queue nil nil '("cardio")) (list cardio)))
    (should (equal (readq--queue nil nil '("cardio" "leisure")) (list novel cardio)))
    (should-not (readq--queue nil nil '("nothing")))))

(ert-deftest readq-ttest-next-from-tag ()
  (readq-ttest--with-library
    ;; Without tags the most important book comes first...
    (should (eq (readq-ttest--next) novel))
    ;; ...but "only from cardio" picks the cardio book.
    (should (eq (readq-ttest--next '("cardio")) cardio))))

(ert-deftest readq-ttest-focus ()
  (readq-ttest--with-library
    (readq-focus '("#Cardio"))
    (should (equal readq--focus '("cardio")))
    (should (eq (readq-ttest--next) cardio))
    ;; Tags given to readq-next win over the focus.
    (should (eq (readq-ttest--next '("leisure")) novel))
    ;; The focus is saved with the queue.
    (setq readq--books nil readq--loaded nil readq--focus nil)
    (readq--books)
    (should (equal readq--focus '("cardio")))
    ;; Nothing due in the focus: offer to read ahead within it only.
    (readq--put (readq--book-by-file (expand-file-name "cardio.pdf" readq-test--dir))
                :due (readq--date-in 3))
    (let (question)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (setq question q) nil)))
        (should-not (readq-ttest--next)))
      (should (string-match-p "Nothing is due today in #cardio\\.  Read ahead with \"Cardio book\""
                              question)))
    (readq-focus nil)
    (should-not readq--focus)
    (should (equal (readq--get (readq-ttest--next) :title) "Novel"))))

(ert-deftest readq-ttest-dashboard ()
  (readq-ttest--with-library
    (readq)
    (goto-char (point-min))
    (should (re-search-forward "pdf +Cardio book +#cardio" nil t))
    (readq-focus '("leisure"))
    (with-current-buffer "*readq*"
      (should (string-match-p "Novel" (buffer-string)))
      (should-not (string-match-p "Cardio book\\|Plain" (buffer-string)))
      (should (equal mode-line-process '(:eval (readq--dashboard-summary))))
      (should (string-match-p "1 in queue — focus: #leisure" (readq--dashboard-summary))))
    (readq-focus nil)
    (with-current-buffer "*readq*"
      (should (string-match-p "Plain" (buffer-string))))
    (kill-buffer "*readq*")))

;;;; Flashcards carry the tags

(ert-deftest readq-ttest-flashcard-tags ()
  (readq-ctest--with-db
    (let* ((pair (readq-ctest--make "Systole ejects {{blood}}."))
           (book (car pair))
           (x (cdr pair)))
      (readq-set-tags book '("cardio"))
      (readq-set-tags x '("exam"))
      (readq-mark-ready x)
      (readq-export-cards 'org-drill)
      (should (string-match-p "^\\* Heart, p\\. 12 :drill:exam:cardio:$"
                              (readq-ctest--file
                               (expand-file-name "lib/Heart-cards.org" readq-test--dir))))
      (should (equal (nth 3 (readq--anki-note (readq--make-card x)))
                     '("readq" "readq-heart" "exam" "cardio"))))))

(provide 'readq-tags-test)
;;; readq-tags-test.el ends here
