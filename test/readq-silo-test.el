;;; readq-silo-test.el --- Tests for keeping extracts in Denote silos -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L . -L test -l test/readq-silo-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)

(defvar denote-silo-directories)

(defmacro readq-sitest--with-silos (&rest body)
  "Run BODY with an empty queue, ~/notes/ and ~/Pathology/notes/ as silos.
`notes' and `patho' are the two folders, under a fake home."
  (declare (indent 0))
  `(readq-test--with-db
     (let* ((notes (expand-file-name "home/notes/" readq-test--dir))
            (patho (expand-file-name "home/Pathology/notes/" readq-test--dir))
            (readq-extracts-directory notes)
            (readq-silos (list notes patho))
            (readq-auto-import-highlights nil))
       (ignore notes patho)
       (unwind-protect (progn ,@body)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b)
                      (string-prefix-p readq-test--dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))))))

(defun readq-sitest--dir (item)
  "Return the folder of the note of ITEM."
  (file-name-directory (expand-file-name (readq--get item :file))))

(ert-deftest readq-sitest-silo-from-book-location ()
  ;; A book under the parent of a silo keeps its extracts in that silo;
  ;; other books use the usual folder.
  (readq-sitest--with-silos
    (let* ((rosen (readq-add-book (readq-test--touch "home/Pathology/Breast/rosen.pdf")
                                  20 "Rosen"))
           (gray (readq-add-book (readq-test--touch "home/books/gray.pdf") 20 "Gray"))
           (x (readq--create-extract rosen "lobular" :page 3))
           (y (readq--create-extract gray "systole" :page 5)))
      (should (equal (expand-file-name (readq--get rosen :silo)) patho))
      (should-not (readq--get gray :silo))
      (should (equal (readq-sitest--dir x) patho))
      (should (equal (readq-sitest--dir y) notes))
      ;; Extracts of extracts stay with their book.
      (let ((z (readq--create-extract x "sub" :page 3)))
        (should (equal (readq-sitest--dir z) patho))))))

(ert-deftest readq-sitest-set-silo-moves-notes ()
  (readq-sitest--with-silos
    (let* ((book (readq-add-book (readq-test--touch "home/books/robbins.pdf") 20 "Robbins"))
           (x (readq--create-extract book "necrosis" :page 1))
           (sub (readq--create-extract x "coagulative" :page 1))
           (old (readq--get x :file)))
      (should (equal (readq-sitest--dir x) notes))
      (find-file-noselect old)
      (readq-set-silo book patho)
      (should (equal (readq-sitest--dir x) patho))
      (should (equal (readq-sitest--dir sub) patho))
      (should (file-exists-p (readq--get x :file)))
      (should-not (file-exists-p old))
      ;; A buffer visiting the note follows it.
      (should (get-file-buffer (readq--get x :file)))
      ;; New extracts go there too.
      (should (equal (readq-sitest--dir (readq--create-extract book "apoptosis" :page 2))
                     patho))
      ;; Back to the usual folder: no silo is recorded.
      (readq-set-silo book notes)
      (should-not (readq--get book :silo))
      (should (equal (readq-sitest--dir x) notes)))))

(ert-deftest readq-sitest-renamed-note-found-in-any-silo ()
  ;; A note moved or renamed outside readq is found again by its
  ;; identifier, whichever silo it is in.
  (readq-sitest--with-silos
    (let* ((book (readq-add-book (readq-test--touch "home/books/gray.pdf") 20 "Gray"))
           (x (readq--create-extract book "systole" :page 5))
           (moved (expand-file-name (concat (readq--get x :id) "--moved.org") patho)))
      (make-directory patho t)
      (rename-file (readq--get x :file) moved)
      (should (equal (expand-file-name (readq--extract-file x)) moved))
      ;; Its identifier is taken, in every silo.
      (should (member moved (readq--note-files (readq--get x :id)))))))

(ert-deftest readq-sitest-denote-silo-directories ()
  ;; Without `readq-silos', denote-silo's folders are the silos.
  (readq-sitest--with-silos
    (let ((readq-silos nil)
          (denote-silo-directories (list notes patho)))
      (should (equal (readq--silos) (list notes patho)))
      (should (equal (expand-file-name
                      (readq--guess-silo (expand-file-name "home/Pathology/x.pdf"
                                                           readq-test--dir)))
                     patho))
      (should-not (readq--guess-silo (expand-file-name "home/books/x.pdf"
                                                       readq-test--dir))))
    (unless (boundp 'denote-silo-directories)
      (let ((readq-silos nil))
        (should-not (readq--silos))
        (should-not (readq--guess-silo (expand-file-name "home/Pathology/x.pdf"
                                                         readq-test--dir)))))))

(ert-deftest readq-sitest-cards-file-in-silo ()
  (readq-sitest--with-silos
    (let ((readq-srs-file nil)
          (book (readq-add-book (readq-test--touch "home/Pathology/rosen.pdf") 20 "Rosen")))
      (should (equal (file-name-directory (readq--srs-file book)) patho)))))

(provide 'readq-silo-test)
;;; readq-silo-test.el ends here
