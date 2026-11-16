;;; readq-draft.el --- Card drafts from a language model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Hormoz Zamanpour Siahkal

;; Author: Hormoz Zamanpour Siahkal <n0w1ht@users.noreply.github.com>
;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; Part of readq; see readq.el.  Load readq with (require 'readq).
;;
;; `readq-draft-cards' sends the text of an extract to the model gptel
;; is set up with (a local one, if that is what you use) and asks for
;; a few flashcard drafts: cloze deletions and questions.  You choose
;; one; it is written into the extract's note, for you to correct
;; before the extract becomes a card.  Nothing is exported by itself.

;;; Code:

(require 'readq-cards)

(declare-function gptel-request "ext:gptel" (&optional prompt &rest args))

(defcustom readq-draft-count 3
  "How many flashcard drafts `readq-draft-cards' asks the model for."
  :type 'integer
  :group 'readq-flashcards)

(defcustom readq-draft-instructions
  "You write flashcards for a student from a passage of a textbook.
Write %d different flashcards that each test one fact of the passage.
Use only what the passage says.  Each flashcard is one line, in one of
these two forms, and you write nothing else:

CLOZE: a sentence of the passage, shortened if needed, with the key term in double braces like {{this}}
Q: a short question || A: its short answer"
  "What `readq-draft-cards' tells the model; %d is `readq-draft-count'.
The model must answer with lines starting with CLOZE: or Q:, the
answer of a question after \"|| A:\" or on a line starting with A:."
  :type 'string
  :group 'readq-flashcards)

(defvar readq--drafts (make-hash-table :test #'equal)
  "The drafts the model wrote and you did not choose from yet, by extract id.")

(defun readq--parse-drafts (response)
  "Return the flashcard drafts in the model's RESPONSE.
Each is (cloze TEXT) or (basic QUESTION ANSWER)."
  (let ((text (replace-regexp-in-string
               "<think>\\(?:.\\|\n\\)*?</think>" "" response))
        (case-fold-search nil)
        (clean (lambda (s)
                 (string-trim (replace-regexp-in-string "[ \t\n]+" " " s)
                              "[ \t\n*|]+" "[ \t\n*|]+")))
        drafts)
    (with-temp-buffer
      (insert text "\n")
      (goto-char (point-min))
      (while (re-search-forward "^[^[:alpha:]\n]*\\(CLOZE\\|Q\\):[ \t*]*" nil t)
        (let* ((kind (match-string 1))
               (beg (point))
               (end (save-excursion
                      (if (re-search-forward "^[^[:alpha:]\n]*\\(?:CLOZE\\|Q\\):" nil t)
                          (match-beginning 0)
                        (point-max))))
               (body (buffer-substring-no-properties beg end)))
          (if (equal kind "CLOZE")
              (let ((cloze (funcall clean body)))
                (when (string-match-p "{{[^}]+}}" cloze)
                  (push (list 'cloze cloze) drafts)))
            (when (string-match "\\(?:||\\|\n\\)[ \t*]*A:" body)
              (let ((q (funcall clean (substring body 0 (match-beginning 0))))
                    (a (funcall clean (substring body (match-end 0)))))
                (unless (or (string-empty-p q) (string-empty-p a))
                  (push (list 'basic q a) drafts)))))
          (goto-char end))))
    (nreverse drafts)))

(defun readq--draft-label (draft)
  "Return the line that shows DRAFT when you choose among drafts."
  (pcase draft
    (`(cloze ,text) (concat "Cloze: " text))
    (`(basic ,q ,a) (format "Q: %s  A: %s" q a))))

(defun readq--apply-draft (item draft)
  "Write the flashcard DRAFT into the note of extract ITEM.
A cloze replaces the quoted passage; a question becomes the note's
title and its answer replaces the passage.  Pictures and \"Note:\"
lines stay.  Undo in the note brings the passage back."
  (let ((buf (or (readq--extract-buffer item)
                 (user-error "The note of \"%s\" is gone" (readq--get item :title))))
        (text (readq--org-escape (pcase draft
                                   (`(cloze ,text) text)
                                   (`(basic ,_ ,a) a)))))
    (with-current-buffer buf
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (readq--note-body-start))
          (let ((case-fold-search t))
            (if (re-search-forward "^#\\+begin_quote[ \t]*\n" nil t)
                (let ((beg (point)))
                  (if (re-search-forward "^#\\+end_quote" nil t)
                      (delete-region beg (match-beginning 0))
                    (delete-region beg (point-max)))
                  (goto-char beg)
                  (insert text "\n"))
              (insert (readq--quote-block text))))))
      (pcase draft
        (`(basic ,q ,_)
         (readq--note-set "title" q)
         (readq--put item :title q)))
      (let ((save-silently t)) (save-buffer)))
    (readq--sync-extract item t)
    (readq--save)
    (readq--refresh-dashboard)))

(defun readq--choose-draft (item)
  "Let the user choose one of the drafts waiting for extract ITEM."
  (let* ((id (readq--get item :id))
         (table (mapcar (lambda (d) (cons (readq--draft-label d) d))
                        (gethash id readq--drafts)))
         (choice (completing-read
                  (format "Card for \"%s\": "
                          (truncate-string-to-width (readq--get item :title) 30 nil nil "…"))
                  table nil t))
         (draft (cdr (assoc choice table))))
    (when draft
      (remhash id readq--drafts)
      (readq--apply-draft item draft)
      ;; Show it for correcting, unless its note is already in front.
      (unless (eq (or (buffer-base-buffer) (current-buffer))
                  (readq--extract-buffer item))
        (readq-edit-extract item))
      (message "Draft written; correct it, then %s makes it a card"
               (substitute-command-keys "\\[readq-mark-ready]"))
      draft)))

(defun readq--drafts-arrived (item response info)
  "Take the model's RESPONSE with drafts for extract ITEM; INFO is gptel's."
  (cond
   ((stringp response)
    (let ((drafts (readq--parse-drafts response)))
      (cond
       ((null drafts)
        (message "readq: the model wrote no usable card for \"%s\"; try again"
                 (readq--get item :title)))
       (t
        (puthash (readq--get item :id) drafts readq--drafts)
        (if (or (active-minibuffer-window) executing-kbd-macro)
            (message "readq: %d card drafts are ready; %s to choose"
                     (length drafts)
                     (substitute-command-keys "\\[readq-draft-cards]"))
          (readq--choose-draft item))))))
   ((null response)
    (message "readq: no drafts, the model did not answer (%s)"
             (or (plist-get info :status) "no reason given")))))

;;;###autoload
(defun readq-draft-cards (item &optional again)
  "Ask a language model for flashcard drafts of extract ITEM; choose one.
The model is the one gptel is set up with.  It gets the text of the
extract and `readq-draft-instructions', and answers with cloze and
question drafts.  The one you choose is written into the extract's
note: correct it, then mark the extract ready (`readq-mark-ready').
Drafts are only drafts: check them against the passage.

ITEM is the extract you are on.  Drafts you did not choose from yet
are offered again; with a prefix argument (AGAIN), ask the model anew."
  (interactive (list (readq--extract-here "Draft cards for") current-prefix-arg))
  (unless (readq--extract-p item) (user-error "Only extracts can become flashcards"))
  (if (and (not again) (gethash (readq--get item :id) readq--drafts))
      (readq--choose-draft item)
    (unless (or (fboundp 'gptel-request) (require 'gptel nil t))
      (user-error "Card drafts need the gptel package, set up with a model"))
    (let ((text (plist-get (readq--extract-content item) :text)))
      (when (string-empty-p (string-trim (or text "")))
        (user-error "This extract has no text"))
      (gptel-request (concat "Passage:\n\n" (string-trim text))
        :system (format readq-draft-instructions readq-draft-count)
        :stream nil
        :callback (lambda (response info)
                    (readq--drafts-arrived item response info)))
      (message "Asking the model for card drafts…"))))

(provide 'readq-draft)

;;; readq-draft.el ends here
