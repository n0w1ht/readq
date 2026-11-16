;;; readq-draft-test.el --- Tests for card drafts from a model -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-draft-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defconst readq-drtest--answer
  "<think>The passage is about the heart.
Q: not this one || A: no</think>
Here are your cards:

1. CLOZE: The {{sinoatrial node}} sets the pace of the heart.
2. **Q:** What sets the pace of the heart? || **A:** The sinoatrial node.
- Q: Where is the sinoatrial node?
  A: In the wall of the right atrium.
CLOZE: A cloze without braces is dropped.
Q: A question without an answer?
")

(defmacro readq-drtest--with-model (answer &rest body)
  "Run BODY with an extract `x' and a model that answers ANSWER at once.
`asked' is what the model was sent, as (PROMPT SYSTEM)."
  (declare (indent 1))
  `(readq-xtest--with-db
     (let* ((book (readq-add-book (readq-test--touch "guyton.pdf") 20 "Guyton"))
            (x (readq--create-extract
                book "The sinoatrial node, in the wall of the right atrium, sets the pace."
                :page 12))
            (asked nil))
       (ignore book)
       (clrhash readq--drafts)
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (prompt &rest args)
                    (setq asked (list prompt (plist-get args :system)))
                    (funcall (plist-get args :callback) ,answer '(:status "ok"))))
                 ((symbol-function 'readq-edit-extract) #'ignore))
         ,@body))))

(ert-deftest readq-drtest-parse ()
  (should (equal (readq--parse-drafts readq-drtest--answer)
                 '((cloze "The {{sinoatrial node}} sets the pace of the heart.")
                   (basic "What sets the pace of the heart?" "The sinoatrial node.")
                   (basic "Where is the sinoatrial node?"
                          "In the wall of the right atrium."))))
  (should-not (readq--parse-drafts "I cannot help with that.")))

(ert-deftest readq-drtest-cloze ()
  (readq-drtest--with-model readq-drtest--answer
    (let (offered)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _)
                   (setq offered (mapcar #'car table))
                   (car offered))))
        (readq-draft-cards x))
      ;; The model got the passage and was asked for three drafts.
      (should (string-match-p "sinoatrial node, in the wall" (car asked)))
      (should (string-match-p "Write 3 different" (cadr asked)))
      (should (= (length offered) 3))
      ;; The cloze replaced the passage; the note is still the extract's.
      (let ((card (readq--make-card x)))
        (should (eq (plist-get card :type) 'cloze))
        (should (string-match-p "The {{c1::sinoatrial node}} sets the pace"
                                (plist-get card :text)))
        (should-not (string-match-p "right atrium" (plist-get card :text))))
      (should (file-exists-p (readq--get x :file)))
      (should-not (gethash (readq--get x :id) readq--drafts))
      ;; Nothing was exported or marked ready.
      (should-not (eq (readq--get x :status) 'ready)))))

(ert-deftest readq-drtest-question ()
  (readq-drtest--with-model readq-drtest--answer
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _) (car (nth 1 table)))))
      (readq-draft-cards x))
    (let ((card (readq--make-card x)))
      (should (eq (plist-get card :type) 'basic))
      (should (equal (plist-get card :front) "What sets the pace of the heart?"))
      (should (string-match-p "The sinoatrial node\\." (plist-get card :text))))
    (should (equal (readq--get x :title) "What sets the pace of the heart?"))
    ;; The file is named after the question, as Denote names files.
    (should (string-match-p "what-sets-the-pace" (readq--get x :file)))))

(ert-deftest readq-drtest-waiting-and-failures ()
  ;; Drafts that arrive while the minibuffer is busy wait for you.
  (readq-drtest--with-model readq-drtest--answer
    (let ((calls 0))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
        (readq-draft-cards x))
      (should (= (length (gethash (readq--get x :id) readq--drafts)) 3))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (&rest _) (cl-incf calls)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _) (car (car table)))))
        (readq-draft-cards x))
      ;; The second call used them without asking the model again.
      (should (= calls 0))
      (should (eq (plist-get (readq--make-card x) :type) 'cloze))))
  ;; No answer, or no usable card: the note is left alone.
  (dolist (answer '(nil "Sorry, no."))
    (readq-drtest--with-model answer
      (let ((before (readq--extract-body x)))
        (readq-draft-cards x)
        (should (equal (readq--extract-body x) before))
        (should-not (gethash (readq--get x :id) readq--drafts))))))

(provide 'readq-draft-test)

;;; readq-draft-test.el ends here
