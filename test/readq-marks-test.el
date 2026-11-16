;;; readq-marks-test.el --- Tests for highlights that are not extracts -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-marks-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)
(require 'readq-formats-test)
(require 'readq-multi-region-test)
(require 'readq-mixed-test)

(defun readq-mktest--select (from to)
  "Make the text between the strings FROM and TO the active region."
  (goto-char (point-min))
  (search-forward from)
  (set-mark (match-beginning 0))
  (search-forward to)
  (activate-mark))

(ert-deftest readq-mktest-highlight-text ()
  (readq-mxtest--with-org-book
    (let ((transient-mark-mode t)
          (queue (length (readq--books))))
      (readq-mktest--select "The cardiac" "close.")
      (let* ((made (readq-highlight))
             (h (car made)))
        ;; A highlight is kept with the book and is not an item.
        (should (= (length made) 1))
        (should (equal (plist-get h :text) "The cardiac cycle: X then the valves close."))
        (should (equal (readq--get book :highlights) made))
        (should (= (length (readq--books)) queue))
        (should-not (and (file-directory-p readq-extracts-directory)
                         (directory-files readq-extracts-directory nil "\\.org\\'" t)))
        ;; It is shown, and found again at point.
        (deactivate-mark)
        (goto-char (point-min))
        (search-forward "cycle")
        (should (cl-some (lambda (o) (overlay-get o 'readq-highlight-id))
                         (overlays-at (point))))
        (should (equal (readq--highlight-here) (cons book h)))
        ;; It survives a reload of the queue.
        (readq--save)
        (should (equal (plist-get (car (readq--get book :highlights)) :id)
                       (plist-get h :id)))
        ;; Removing it leaves nothing behind.
        (readq-highlight '(4))
        (should-not (readq--get book :highlights))
        (should-not (cl-some (lambda (o) (overlay-get o 'readq-highlight))
                             (overlays-in (point-min) (point-max))))
        (should-error (readq-remove-highlight) :type 'user-error)))))

(ert-deftest readq-mktest-promote-highlight ()
  (readq-mxtest--with-org-book
    (let ((transient-mark-mode t))
      (readq-mktest--select "The cardiac" "close.")
      (readq-highlight)
      (deactivate-mark)
      (goto-char (point-min))
      (search-forward "cycle")
      ;; With nothing selected, extracting takes the highlight here.
      (let* ((made (readq-extract))
             (x (if (keywordp (car made)) made (car made))))
        (should (eq (readq--get x :format) 'extract))
        (should (string-match-p "valves close" (readq--get x :snippet)))
        (should-not (readq--get book :highlights))
        (should-not (eq (readq--get x :status) 'finished))))))

(ert-deftest readq-mktest-extract-keep ()
  (readq-mxtest--with-org-book
    (let ((transient-mark-mode t))
      (readq-mktest--select "The cardiac" "close.")
      (let* ((made (readq-extract-keep))
             (x (if (keywordp (car made)) made (car made))))
        ;; A note of its own, that never comes up.
        (should (file-exists-p (readq--get x :file)))
        (should (eq (readq--get x :status) 'finished))
        (should-not (memq x (readq--queue (+ (float-time) (* 400 86400)))))
        ;; A highlight can be kept the same way.
        (readq-mktest--select "More" "text.")
        (readq-highlight)
        (deactivate-mark)
        (goto-char (point-min))
        (search-forward "More")
        (let* ((made (readq-extract-keep))
               (y (if (keywordp (car made)) made (car made))))
          (should (eq (readq--get y :status) 'finished))
          (should (string-match-p "More text" (readq--get y :snippet))))))))

(ert-deftest readq-mktest-pdf ()
  (readq-mtest--with-pdf
    (setq pdf-view-active-region '(1 (0.1 0.1 0.5 0.2)))
    (let* ((readq-highlight-color "#00ff00")
           (made (readq-highlight))
           (h (car made)))
      ;; Saved into the PDF, in the highlight color.
      (should (= (length readq-mtest--annotations) 1))
      (should (equal (nth 2 (car readq-mtest--annotations)) "#00ff00"))
      (should (= (plist-get h :page) 1))
      (should (equal (plist-get h :text) "Text 1 at 0.1."))
      (should-not pdf-view-active-region)
      (should-not (cl-remove-if-not (lambda (i) (eq (readq--get i :format) 'extract))
                                    (readq--books)))
      ;; The importer does not take it for a highlight made elsewhere.
      (should (readq--known-highlight-p book 1 '((0.101 0.101 0.501 0.201)) nil))
      ;; On its page, extracting takes it; the annotation is not added twice.
      (should (equal (readq--highlight-here) (cons book h)))
      (let* ((made (readq-extract))
             (x (if (keywordp (car made)) made (car made))))
        (should (= (readq--get x :page) 1))
        (should (equal (readq--get x :snippet) "Text 1 at 0.1."))
        (should (= (length readq-mtest--annotations) 1))
        (should-not (readq--get book :highlights))
        (should (readq--known-highlight-p book 1 '((0.101 0.101 0.501 0.201)) nil))))))

(ert-deftest readq-mktest-find-highlight ()
  (readq-mxtest--with-org-book
    (let ((transient-mark-mode t) asked)
      (should-error (readq-find-highlight) :type 'user-error)
      (readq-mktest--select "More" "text.")
      (readq-highlight)
      (deactivate-mark)
      (goto-char (point-min))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt table &rest _) (setq asked (caar table)))))
        (readq-find-highlight))
      (should (string-match-p "More text" asked))
      (should (looking-at-p "More text")))))

(provide 'readq-marks-test)

;;; readq-marks-test.el ends here
