;;; readq-drawer-test.el --- Tests for readq's data in property drawers -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-drawer-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'org-id)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defun readq-drtest--org (item)
  "Return the contents of ITEM's Org file, from its buffer."
  (with-current-buffer (find-file-noselect (readq--get item :file))
    (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))

(defun readq-drtest--write (file text)
  "Replace the contents of the Org FILE with TEXT, as an old readq wrote it."
  (with-current-buffer (find-file-noselect file)
    (erase-buffer)
    (insert text)
    (let ((save-silently t)) (save-buffer))))

(ert-deftest readq-drtest-new-extract ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x (readq--create-extract book "Systole is contraction." :page 57
                                     :comment "Key")))
      (should (equal (readq-drtest--org x)
                     (concat ":PROPERTIES:\n:READQ_BOOK: " (readq--get book :id) "\n:END:\n"
                             "#+TITLE: Extracts from Guyton\n#+STARTUP: overview\n\n"
                             "* Systole is contraction.\n:PROPERTIES:\n"
                             ":READQ_ID: " (readq--get x :id) "\n"
                             ":READQ_SOURCE: [[readq:" (readq--get x :id) "][Guyton, p. 57]]\n"
                             ":END:\n"
                             "#+begin_quote\nSystole is contraction.\n#+end_quote\n"
                             "Note: Key\n\n")))
      ;; readq finds its file and its text as before.
      (should (readq--own-file-p (readq--get x :file)))
      (should (readq--extracts-file-of-p (readq--get x :file) book))
      (should (equal (plist-get (readq--extract-content x) :text) "Systole is contraction."))
      (should (equal (plist-get (readq--extract-content x) :note) "Key")))))

(ert-deftest readq-drtest-visible-form ()
  (readq-xtest--with-db
    (let* ((readq-metadata-in-drawers nil)
           (book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x (readq--create-extract book "Systole is contraction." :page 57)))
      (should (equal (readq-drtest--org x)
                     (concat "#+TITLE: Extracts from Guyton\n"
                             "#+READQ_BOOK: " (readq--get book :id) "\n#+STARTUP: overview\n\n"
                             "* Systole is contraction.\n:PROPERTIES:\n"
                             ":READQ_ID: " (readq--get x :id) "\n:END:\n"
                             "Source: [[readq:" (readq--get x :id) "][Guyton, p. 57]]\n"
                             "#+begin_quote\nSystole is contraction.\n#+end_quote\n\n"))))))

(ert-deftest readq-drtest-extract-ids ()
  (readq-xtest--with-db
    (let* ((readq-extract-ids t)
           (book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x (readq--create-extract book "Systole is contraction." :page 57)))
      (with-current-buffer (find-file-noselect (readq--get x :file))
        (let ((pos (org-find-property "READQ_ID" (readq--get x :id))))
          (should (org-entry-get pos "ID"))
          (should-not (equal (org-entry-get pos "ID") (readq--get x :id))))))))

(ert-deftest readq-drtest-tidy-old-file ()
  (readq-xtest--with-db
    (let* ((readq-metadata-in-drawers nil)
           (book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x1 (readq--create-extract book "Systole is contraction." :page 57 :comment "Key"))
           (x2 (readq--create-extract book "Diastole is relaxation." :page 58))
           (sub (readq--create-extract x1 "contraction"))
           (file (readq--get x1 :file)))
      ;; An :ID: org-node gave x2, and a Source line quoted in a passage.
      (with-current-buffer (find-file-noselect file)
        (org-entry-put (org-find-property "READQ_ID" (readq--get x2 :id)) "ID" "my-own-id")
        (goto-char (point-max))
        (insert "Source: [[readq:zzz][not readq's line]]\n")
        (let ((save-silently t)) (save-buffer)))
      (let ((readq-metadata-in-drawers t))
        ;; Old files are read as they are.
        (should (readq--extracts-file-of-p file book))
        (should (equal (plist-get (readq--extract-content x1) :text)
                       "Systole is contraction."))
        ;; 3 extracts and the file's header.
        (should (= (readq-tidy-extracts) 4))
        (let ((org (readq-drtest--org x1)))
          (should (string-prefix-p (concat ":PROPERTIES:\n:READQ_BOOK: " (readq--get book :id)
                                           "\n:END:\n#+TITLE: Extracts from Guyton\n"
                                           "#+STARTUP: overview\n")
                                   org))
          (should-not (string-match-p "^#\\+READQ_BOOK" org))
          (should-not (string-match-p "^Source: \\[\\[readq:[0-9a-f]+\\]\\[Guyton" org))
          ;; What isn't readq's stays.
          (should (string-match-p "^Source: \\[\\[readq:zzz\\]" org))
          (should (string-match-p "^Note: Key$" org)))
        (with-current-buffer (find-file-noselect file)
          (dolist (x (list x1 x2 sub))
            (let ((pos (org-find-property "READQ_ID" (readq--get x :id))))
              (should (string-prefix-p (concat "[[readq:" (readq--get x :id) "][")
                                       (org-entry-get pos "READQ_SOURCE")))))
          (should (equal (org-entry-get (org-find-property "READQ_ID" (readq--get x2 :id)) "ID")
                         "my-own-id"))
          (should-not (org-entry-get (org-find-property "READQ_ID" (readq--get x1 :id)) "ID"))
          (should-not (buffer-modified-p)))
        (should (readq--extracts-file-of-p file book))
        (should (equal (plist-get (readq--extract-content x1) :text)
                       "Systole is contraction."))
        ;; Nothing left to do the second time.
        (should (= (readq-tidy-extracts) 0))
        ;; With `readq-extract-ids', the ones without an ID get one.
        (let ((readq-extract-ids t))
          (should (= (readq-tidy-extracts book) 2))
          (with-current-buffer (find-file-noselect file)
            (should (org-entry-get (org-find-property "READQ_ID" (readq--get x1 :id)) "ID"))
            (should (equal (org-entry-get (org-find-property "READQ_ID" (readq--get x2 :id))
                                          "ID")
                           "my-own-id")))))
      ;; And back to visible lines.
      (should (= (readq-tidy-extracts) 4))
      (let ((org (readq-drtest--org x1)))
        (should (string-match-p (concat "^#\\+READQ_BOOK: " (readq--get book :id) "$") org))
        (should-not (string-match-p "READQ_SOURCE" org))
        (should-not (string-match-p "\\`:PROPERTIES:" org))
        (should (string-match-p
                 (concat ":END:\nSource: \\[\\[readq:" (readq--get x1 :id)
                         "\\]\\[Guyton, p\\. 57\\]\\]\n#\\+begin_quote\nSystole")
                 org))))))

(ert-deftest readq-drtest-tidy-keeps-file-id ()
  (readq-xtest--with-db
    (let* ((readq-metadata-in-drawers nil)
           (book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x (readq--create-extract book "Systole is contraction." :page 57))
           (file (readq--get x :file)))
      ;; org-node made the file a node.
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (insert ":PROPERTIES:\n:ID: file-node\n:END:\n")
        (let ((save-silently t)) (save-buffer)))
      (let ((readq-metadata-in-drawers t))
        (readq-tidy-extracts)
        (should (string-prefix-p (concat ":PROPERTIES:\n:ID: file-node\n:READQ_BOOK: "
                                         (readq--get book :id) "\n:END:\n#+TITLE:")
                                 (readq-drtest--org x)))
        (should (readq--extracts-file-of-p file book)))
      (readq-tidy-extracts)
      (should (string-prefix-p ":PROPERTIES:\n:ID: file-node\n:END:\n#+TITLE: Extracts from Guyton\n#+READQ_BOOK: "
                               (readq-drtest--org x))))))

(ert-deftest readq-drtest-merge-keeps-source ()
  (readq-xtest--with-db
    (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
           (x1 (readq--create-extract book "Systole is contraction." :page 57))
           (x2 (readq--create-extract book "Diastole is relaxation." :page 58)))
      (readq-merge-extract x2 x1)
      (should (string-match-p
               (format "Merged from: Diastole is relaxation.\nSource: \\[\\[readq:%s::p58\\]\\[Guyton, p\\. 58\\]\\]\n#\\+begin_quote\nDiastole"
                       (readq--get book :id))
               (readq-drtest--org x1))))))

(provide 'readq-drawer-test)
;;; readq-drawer-test.el ends here
