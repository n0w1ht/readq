;;; readq-viewer-test.el --- The viewer table -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'readq)
(require 'readq-test)
(require 'readq-extract-test)

(defvar readq-vtest--page 1)
(defvar readq-vtest-page-hook nil)

(define-derived-mode readq-vtest-mode special-mode "vtest"
  "A viewer made up for the tests.")

(defmacro readq-vtest--with-viewer (&rest body)
  "Run BODY with a made-up viewer defined, and forget it afterwards."
  (declare (indent 0))
  `(let ((readq-viewers (copy-tree readq-viewers))
         (readq-vtest--page 1))
     (readq-define-viewer 'vtest
       :modes '(readq-vtest-mode)
       :mode-hook 'readq-vtest-mode-hook
       :page-hook 'readq-vtest-page-hook
       :kind 'pdf
       :position (lambda (_win) (list :page readq-vtest--page :total 10))
       :goto (lambda (pos) (setq readq-vtest--page (plist-get pos :page)))
       :page (lambda () readq-vtest--page))
     ,@body))

(ert-deftest readq-vtest-define-adds-and-merges ()
  (let ((readq-viewers nil))
    (readq-define-viewer 'one :modes '(text-mode) :kind 'pdf)
    (readq-define-viewer 'two :modes '(prog-mode))
    (readq-define-viewer 'one :kind 'comic :text t)
    (should (equal (mapcar #'car readq-viewers) '(one two)))
    (with-temp-buffer
      (text-mode)
      (should (eq (car (readq--viewer-here)) 'one))
      (should (eq (readq--viewer-get :kind) 'comic))
      (should (readq--viewer-get :text))
      (should-not (readq--viewer-call :goto '(:page 1))))
    (with-temp-buffer
      (should-not (readq--viewer-here)))))

(ert-deftest readq-vtest-a-new-viewer-is-tracked ()
  (readq-xtest--with-db
    (readq-vtest--with-viewer
      (let* ((file (readq-test--touch "book.pdf"))
             (book (readq-add-book file 30)))
        (should (memq 'readq-vtest-mode-hook (readq--mode-hooks)))
        (with-temp-buffer
          (setq buffer-file-name file)
          (readq-vtest-mode)
          (let ((readq--inhibit-restore t))
            (readq-book-mode 1))
          (should readq-book-mode)
          (should (equal (readq--buffer-position) '(:page 1 :total 10)))
          ;; Turning the page is recorded through the viewer's hook.
          (setq readq-vtest--page 4)
          (run-hooks 'readq-vtest-page-hook)
          (should (= (readq--get book :page) 4))
          (should (= (readq--get book :total) 10))
          (readq--restore-position '(:page 7))
          (should (= readq-vtest--page 7))
          (should (= (readq--pdf-page-here) 7))
          (setq buffer-file-name nil)
          (readq-book-mode -1))))))

(ert-deftest readq-vtest-extract-through-the-viewer ()
  (readq-xtest--with-db
    (readq-vtest--with-viewer
      (let* ((file (readq-test--touch "book.pdf"))
             (book (readq-add-book file 30))
             (readq-extract-add-highlight t)
             highlighted cleared)
        (readq-define-viewer 'vtest
          :parts (lambda ()
                   (readq--selection-parts
                    '((:text "Systole is  the phase." :page 3 :edges (0.1 0.1 0.5 0.2)))))
          :highlight (lambda (parts)
                       (setq highlighted (length parts))
                       (plist-put (car parts) :edges '((0.1 0.1 0.5 0.15))))
          :clear-selection (lambda () (setq cleared t)))
        (with-temp-buffer
          (setq buffer-file-name file)
          (readq-vtest-mode)
          (setq readq--book-id (readq--get book :id))
          (let ((x (car (readq--extract-from-pdf nil 'separate))))
            (setq buffer-file-name nil)
            (should (= highlighted 1))
            (should cleared)
            (should (= (readq--get x :page) 3))
            (should (equal (readq--get x :edges) '((0.1 0.1 0.5 0.15))))
            (should (string-match-p "Systole is the phase" (readq--extract-body x)))))))))

(ert-deftest readq-vtest-pdf-canvas-entry ()
  "The pdf-canvas entry, with pdf-canvas itself played by stand-ins."
  (let (page cleared saved annotated deleted)
    (with-temp-buffer
      (setq major-mode 'pdf-canvas-mode)
      (cl-letf (((symbol-function 'pdf-canvas-current-page) (lambda () 5))
                ((symbol-function 'pdf-canvas-page-count) (lambda () 8))
                ((symbol-function 'pdf-canvas-goto-page) (lambda (p) (setq page p)))
                ((symbol-function 'pdf-canvas-selections)
                 (lambda ()
                   (list (list :index 0 :page 2 :text "one" :edges '(0.1 0.1 0.2 0.2))
                         (list :index 2 :page 3 :figure t :edges '(0.3 0.3 0.6 0.6))
                         (list :index 1 :page 3 :text "two" :edges '(0.1 0.5 0.2 0.6)))))
                ((symbol-function 'pdf-canvas-clear-selections) (lambda () (setq cleared t)))
                ((symbol-function 'pdf-canvas-region-image)
                 (lambda (p edges dpi) (list p edges dpi)))
                ((symbol-function 'pdf-canvas-annotate)
                 (lambda (&rest _)
                   (setq annotated t)
                   (list (list :page 2 :quads '((0.1 0.1 0.2 0.15))))))
                ((symbol-function 'pdf-canvas-annotations)
                 (lambda (p)
                   (list (list :page p :type 'highlight :quads '((0.1 0.1 0.2 0.15)))
                         (list :page p :type 'highlight :quads '((0.7 0.7 0.9 0.8))))))
                ((symbol-function 'pdf-canvas-delete-annotation)
                 (lambda (a) (push a deleted)))
                ((symbol-function 'pdf-canvas-save) (lambda () (setq saved t))))
        (should (eq (car (readq--viewer-here)) 'pdf-canvas))
        (should (equal (readq--buffer-position) '(:page 5 :total 8)))
        (readq--restore-position '(:page 2))
        (should (= page 2))
        (should (= (readq--pdf-page-here) 5))
        (should (readq--viewer-call :selection-p))
        (let ((parts (readq--pdf-parts)))
          (should (equal (mapcar (lambda (p) (plist-get p :page)) parts) '(2 3 3)))
          (should (equal (plist-get (car parts) :text) "one"))
          (should (equal (plist-get (cadr parts) :image) '(:pdf-area (0.3 0.3 0.6 0.6))))
          (readq--viewer-call :highlight parts)
          (should (and annotated saved))
          (should (equal (plist-get (car parts) :edges) '((0.1 0.1 0.2 0.15)))))
        (should (equal (readq--viewer-call :figure-region)
                       '(3 (0.3 0.3 0.6 0.6) (0.1 0.5 0.2 0.6))))
        (should (equal (readq--pdf-crop "f.pdf" 3 '(0 0 1 1))
                       (list 3 '(0 0 1 1) readq-figure-dpi)))
        (readq--viewer-call :clear-selection)
        (should cleared)
        (setq saved nil)
        (should (= (readq--viewer-call :delete-highlights
                                       '((:page 2 :edges ((0.1 0.1 0.2 0.15)))))
                   1))
        (should saved)
        (should (equal (plist-get (car deleted) :quads) '((0.1 0.1 0.2 0.15))))))))

(provide 'readq-viewer-test)

;;; readq-viewer-test.el ends here
