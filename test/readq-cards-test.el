;;; readq-cards-test.el --- Tests for readq flashcards -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-cards-test.el \
;;     -f ert-run-tests-batch-and-exit
;;
;; The AnkiConnect test runs test/fake-ankiconnect.py (needs python3).
;; The org-drill test runs when org-drill (and persist) are on the load path.

;;; Code:

(require 'ert)
(require 'org)
(require 'json)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-ctest--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defmacro readq-ctest--with-db (&rest body)
  "Run BODY with an empty database; extracts and cards next to the books."
  (declare (indent 0))
  `(readq-xtest--with-db
     (let ((readq-extracts-directory nil)
           (readq-drill-file nil)
           (readq-anki-export-file (expand-file-name "anki.txt" readq-test--dir))
           (readq-flashcard-backend 'ask)
           (readq-dismiss-after-export t))
       ,@body)))

(defun readq-ctest--file (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun readq-ctest--edit-entry (item fn)
  "Call FN at the heading of extract ITEM in its Org buffer, then save."
  (with-current-buffer (find-file-noselect (readq--get item :file))
    (widen)
    (goto-char (org-find-property "READQ_ID" (readq--get item :id)))
    (funcall fn)
    (save-buffer)))

(defun readq-ctest--make (&optional text heading)
  "Make a book with an extract of TEXT; optionally retitle it HEADING.
Return (BOOK . EXTRACT)."
  (let* ((book (readq-add-book (readq-test--touch "lib/Heart.pdf") 20 "Heart"))
         (x (readq--create-extract book (or text "Systole ejects blood.")
                                   :page 12 :comment "Key definition")))
    (when heading
      (readq-ctest--edit-entry x (lambda () (org-edit-headline heading))))
    (cons book x)))

;;;; Clozes

(ert-deftest readq-ctest-number-clozes ()
  (should (equal (readq--number-clozes "{{a}} and {{c1::b}} and {{c::d::hint}}")
                 "{{c2::a}} and {{c1::b}} and {{c3::c::d::hint}}"))
  (should (equal (readq--number-clozes "no clozes [1]") "no clozes [1]"))
  (should (= (readq--cloze-count "{{c1::a}} {{c1::b}} {{c2::c}}") 2))
  (should (= (readq--cloze-count "none") 0))
  (should (equal (readq--number-clozes "{{across\nlines}}") "{{c1::across\nlines}}")))

(ert-deftest readq-ctest-cloze-to-drill ()
  (should (equal (readq--cloze-to-drill
                  "The {{c1::mitral}} valve has {{c2::two::number}} cusps [1].")
                 "The [mitral] valve has [two||number] cusps (1).")))

(ert-deftest readq-ctest-cloze-command ()
  (with-temp-buffer
    (insert "The mitral valve")
    (let ((transient-mark-mode t))
      (goto-char 5) (set-mark 11) (activate-mark)
      (readq-cloze 5 11)
      (should (equal (buffer-string) "The {{mitral}} valve"))
      (readq-cloze 16 21 "part")
      (should (equal (buffer-string) "The {{mitral}} {{valve::part}}")))))

;;;; Reading extracts

(ert-deftest readq-ctest-extract-content ()
  (readq-ctest--with-db
    (let* ((pair (readq-ctest--make "* Systole ejects\nblood." "What does systole do?"))
           (content (readq--extract-content (cdr pair))))
      (should (equal (plist-get content :heading) "What does systole do?"))
      (should (equal (plist-get content :text) "* Systole ejects\nblood."))
      (should (equal (plist-get content :note) "Key definition")))))

(ert-deftest readq-ctest-make-card ()
  (readq-ctest--with-db
    (let* ((pair (readq-ctest--make "Systole ejects {{blood}}."))
           (card (readq--make-card (cdr pair))))
      (should (eq (plist-get card :type) 'cloze))
      (should (equal (plist-get card :text) "Systole ejects {{c1::blood}}."))
      (should (equal (plist-get card :source) "Heart, p. 12")))))

;;;; Marking extracts ready

(ert-deftest readq-ctest-mark-ready-while-reviewing ()
  (readq-ctest--with-db
    (let* ((x (cdr (readq-ctest--make)))
           next-called)
      (readq--put x :due (readq--today))
      (should (readq-open x))
      (cl-letf (((symbol-function 'readq-next) (lambda () (setq next-called t))))
        (readq-mark-ready x))
      (should next-called)
      (should-not readq-review-mode)
      (should (eq (readq--get x :status) 'ready))
      (should-not (memq x (readq--queue)))
      (should (equal (readq--due-string x) "ready"))
      (should (string-match-p ":ready:" (readq-ctest--file (readq--get x :file))))
      (should (equal (readq--ready-extracts) (list x)))
      ;; Unmark: back in the queue, tag gone.
      (readq-mark-ready x)
      (should (eq (readq--get x :status) 'active))
      (should-not (string-match-p ":ready:" (readq-ctest--file (readq--get x :file))))
      (should-not (readq--ready-extracts)))))

(ert-deftest readq-ctest-ready-tag-added-by-hand ()
  (readq-ctest--with-db
    (let ((x (cdr (readq-ctest--make))))
      (readq-ctest--edit-entry x (lambda () (org-toggle-tag "ready" 'on)))
      (should (equal (readq--ready-extracts) (list x))))))

(ert-deftest readq-ctest-nothing-ready ()
  (readq-ctest--with-db
    (readq-ctest--make)
    (should-error (readq-export-cards 'org-drill) :type 'user-error)))

;;;; org-drill

(ert-deftest readq-ctest-export-org-drill ()
  (readq-ctest--with-db
    (let* ((pair (readq-ctest--make "Systole ejects blood into the aorta."
                                    "What does systole do?"))
           (book (car pair))
           (basic (cdr pair))
           (cloze (readq--create-extract
                   book "The {{mitral}} valve has {{two::number}} cusps [1]." :page 13))
           (single (readq--create-extract book "The {{tricuspid}} valve." :page 14)))
      (dolist (x (list basic cloze single)) (readq-mark-ready x))
      (should (= (readq-export-cards 'org-drill) 3))
      (let* ((file (expand-file-name "lib/Heart-cards.org" readq-test--dir))
             (org (readq-ctest--file file)))
        (should (string-match-p "\\`#\\+TITLE: Flashcards from Heart" org))
        ;; Question/answer card: heading asks, child heading answers.
        (should (string-match-p
                 (concat "^\\* What does systole do\\? +:drill:\n"
                         ":PROPERTIES:\n:READQ_CARD_OF: " (readq--get basic :id) "\n:END:\n"
                         "\\*\\* Answer\nSystole ejects blood into the aorta\\.\n"
                         "Key definition\n"
                         "\\*\\* Source\n\\[\\[readq:")
                 org))
        ;; Cloze card with two clozes: hidden one at a time.
        (should (string-match-p
                 (concat "^\\* Heart, p\\. 13 +:drill:\n:PROPERTIES:\n:READQ_CARD_OF: "
                         (readq--get cloze :id) "\n:DRILL_CARD_TYPE: hide1cloze\n:END:\n"
                         "The \\[mitral\\] valve has \\[two||number\\] cusps (1)\\.\n")
                 org))
        (should (string-match-p
                 (concat ":READQ_CARD_OF: " (readq--get single :id) "\n:END:\n"
                         "The \\[tricuspid\\] valve\\.")
                 org))
        ;; The cards file is not mistaken for an extracts file.
        (with-current-buffer (find-file-noselect file)
          (goto-char (point-max))
          (should-not (readq--extract-at-point))))
      (dolist (x (list basic cloze single))
        (should (eq (readq--get x :status) 'finished))
        (should (eq (plist-get (readq--get x :exported) :backend) 'org-drill))
        (should (equal (readq--due-string x) "exported")))
      (let ((org (readq-ctest--file (readq--get basic :file))))
        (should (string-match-p ":exported:" org))
        (should-not (string-match-p ":ready:" org)))
      ;; Exported cards are not exported again.
      (should-error (readq-export-cards 'org-drill) :type 'user-error))))

(ert-deftest readq-ctest-org-drill-reads-cards ()
  (skip-unless (require 'org-drill nil t))
  (readq-ctest--with-db
    (let* ((pair (readq-ctest--make "The {{mitral}} valve has {{two}} cusps."))
           (basic (readq--create-extract (car pair) "Answer text." :page 3)))
      (readq-ctest--edit-entry basic (lambda () (org-edit-headline "A question?")))
      (readq-mark-ready (cdr pair))
      (readq-mark-ready basic)
      (readq-export-cards 'org-drill)
      (with-current-buffer (find-file-noselect
                            (expand-file-name "lib/Heart-cards.org" readq-test--dir))
        (org-mode)
        ;; Two cards; their Answer/Source children are not cards.
        (should (= (length (delq nil (org-map-entries #'org-drill-entry-p nil 'file))) 2))
        (goto-char (point-min))
        (re-search-forward "hide1cloze")
        (should (equal (org-entry-get nil "DRILL_CARD_TYPE") "hide1cloze"))
        ;; org-drill finds both clozes in the card.
        (let ((count 0))
          (org-back-to-heading)
          (let ((end (save-excursion (outline-next-heading) (point))))
            (while (re-search-forward org-drill-cloze-regexp end t)
              (setq count (1+ count))))
          (should (= count 2)))))))

(ert-deftest readq-ctest-keep-in-queue-after-export ()
  (readq-ctest--with-db
    (let ((x (cdr (readq-ctest--make)))
          (readq-dismiss-after-export nil))
      (readq-mark-ready x)
      (readq-export-cards 'org-drill)
      (should (eq (readq--get x :status) 'active)))))

(ert-deftest readq-ctest-single-drill-file ()
  (readq-ctest--with-db
    (let* ((readq-drill-file (expand-file-name "all-cards.org" readq-test--dir))
           (x (cdr (readq-ctest--make))))
      (readq-mark-ready x)
      (readq-export-cards 'org-drill)
      (should (string-match-p "^#\\+TITLE: Flashcards from readq"
                              (readq-ctest--file readq-drill-file))))))

;;;; Anki: import file

(ert-deftest readq-ctest-export-anki-file ()
  (readq-ctest--with-db
    (let* ((readq-anki-method 'file)
           (pair (readq-ctest--make "Systole \"ejects\" blood.\n\nInto the aorta."
                                    "What does systole do?"))
           (cloze (readq--create-extract (car pair) "The {{mitral}} valve." :page 13)))
      (readq-mark-ready (cdr pair))
      (readq-mark-ready cloze)
      (should (= (readq-export-cards 'anki) 2))
      (let* ((lines (split-string (readq-ctest--file readq-anki-export-file) "\n" t)))
        (should (equal (cl-subseq lines 0 5)
                       '("#separator:Tab" "#html:true" "#notetype column:1"
                         "#deck column:2" "#tags column:5")))
        (should (= (length lines) 7))
        (let ((basic (split-string (nth 5 lines) "\t"))
              (cl (split-string (nth 6 lines) "\t")))
          (should (equal (car basic) "\"Basic\""))
          (should (equal (nth 1 basic) "\"readq::Heart\""))
          (should (equal (nth 2 basic) "\"What does systole do?\""))
          (should (string-match-p "Systole \"\"ejects\"\" blood\\." (nth 3 basic)))
          (should (string-match-p "<p>" (nth 3 basic)))
          (should (string-match-p "readq-source.*Heart, p\\. 12" (nth 3 basic)))
          (should (string-match-p "Key definition" (nth 3 basic)))
          (should (equal (nth 4 basic) "\"readq readq-heart\""))
          (should (equal (car cl) "\"Cloze\""))
          (should (string-match-p "The {{c1::mitral}} valve\\." (nth 2 cl)))))
      ;; A second export appends rows without repeating the header.
      (let ((x (readq--create-extract (car pair) "More {{text}}." :page 20)))
        (readq-mark-ready x)
        (readq-export-cards 'anki))
      (let ((lines (split-string (readq-ctest--file readq-anki-export-file) "\n" t)))
        (should (= (length lines) 8))
        (should (= (cl-count "#separator:Tab" lines :test #'equal) 1))))))

(ert-deftest readq-ctest-anki-unreachable-falls-back-to-file ()
  (readq-ctest--with-db
    (let ((readq-anki-method 'ankiconnect)
          (readq-anki-connect-url "http://127.0.0.1:9")
          (x (cdr (readq-ctest--make))))
      (readq-mark-ready x)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (= (readq-export-cards 'anki) 1)))
      (should (file-exists-p readq-anki-export-file)))))

;;;; Anki: AnkiConnect (fake server)

(defun readq-ctest--start-fake-anki (log)
  "Start the fake AnkiConnect server logging to LOG; return (PROCESS . URL)."
  (let* ((port (+ 20000 (random 20000)))
         (proc (start-process "fake-anki" nil "python3"
                              (expand-file-name "fake-ankiconnect.py" readq-ctest--dir)
                              (number-to-string port) log))
         (readq-anki-connect-url (format "http://127.0.0.1:%d" port))
         (tries 0))
    (while (and (< tries 50) (not (readq--anki-reachable-p)))
      (setq tries (1+ tries))
      (accept-process-output nil 0.1))
    (cons proc readq-anki-connect-url)))

(ert-deftest readq-ctest-export-ankiconnect ()
  (skip-unless (executable-find "python3"))
  (readq-ctest--with-db
    (let* ((log (expand-file-name "anki-requests.log" readq-test--dir))
           (server (readq-ctest--start-fake-anki log))
           (readq-anki-connect-url (cdr server))
           (readq-anki-method 'ankiconnect)
           (readq-flashcard-backend 'anki))
      (unwind-protect
          (let* ((pair (readq-ctest--make "Systole ejects blood." "What does systole do?"))
                 (book (car pair))
                 (cloze (readq--create-extract book "The {{mitral}} valve, café." :page 13))
                 (dup (readq--create-extract book "Known." :page 14))
                 (broken (readq--create-extract book "Fails." :page 15))
                 (warnings nil))
            (readq-ctest--edit-entry dup (lambda () (org-edit-headline "DUPLICATE question")))
            (readq-ctest--edit-entry broken (lambda () (org-edit-headline "BROKEN question")))
            (dolist (x (list (cdr pair) cloze dup broken)) (readq-mark-ready x))
            (should (readq--anki-reachable-p))
            (cl-letf (((symbol-function 'display-warning)
                       (lambda (_type msg &rest _) (push msg warnings))))
              ;; The duplicate counts as exported; the broken one does not.
              (should (= (readq-export-cards (quote anki)) 3)))
            (should (string-match-p "BROKEN question: AnkiConnect: model was not found"
                                    (car warnings)))
            (should (eq (readq--get broken :status) 'ready))
            (should (eq (readq--get dup :status) 'finished))
            (let* ((json-object-type 'alist) (json-key-type 'string) (json-array-type 'list)
                   (requests (mapcar #'json-read-from-string
                                     (split-string (readq-ctest--file log) "\n" t)))
                   (notes (cl-remove-if-not
                           (lambda (r) (equal (cdr (assoc "action" r)) "addNote"))
                           requests)))
              (should (member '(("action" . "createDeck") ("version" . 6)
                                ("params" ("deck" . "readq::Heart")))
                              requests))
              (should (= (length notes) 4))
              (let* ((n1 (cdr (assoc "note" (cdr (assoc "params" (nth 0 notes))))))
                     (n2 (cdr (assoc "note" (cdr (assoc "params" (nth 1 notes)))))))
                (should (equal (cdr (assoc "deckName" n1)) "readq::Heart"))
                (should (equal (cdr (assoc "modelName" n1)) "Basic"))
                (should (equal (cdr (assoc "Front" (cdr (assoc "fields" n1))))
                               "What does systole do?"))
                (should (string-match-p "Systole ejects blood\\."
                                        (cdr (assoc "Back" (cdr (assoc "fields" n1))))))
                (should (equal (cdr (assoc "tags" n1)) '("readq" "readq-heart")))
                (should (eq (cdr (assoc "allowDuplicate" (cdr (assoc "options" n1)))) :json-false))
                (should (equal (cdr (assoc "modelName" n2)) "Cloze"))
                (should (string-match-p "The {{c1::mitral}} valve, café\\."
                                        (cdr (assoc "Text" (cdr (assoc "fields" n2)))))))))
        (delete-process (car server))))))

(provide 'readq-cards-test)
;;; readq-cards-test.el ends here
