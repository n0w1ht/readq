;;; readq-relearn.el --- Failed cards send you back to the source -*- lexical-binding: t; -*-

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
;; A card you keep failing was learned badly: the fact needs its
;; context again.  When the card of an extract has been failed
;; `readq-card-lapse-threshold' times, the extract comes back into the
;; reading queue, due today; when it comes up, its place in the book is
;; shown beside it.
;;
;; With org-srs, readq counts each time you rate a card \"again\".  With
;; Anki, it reads the lapses of the cards it added through AnkiConnect,
;; once a day when Anki is running, or with `readq-check-failed-cards'.

;;; Code:

(require 'readq-cards)

(defvar org-srs-review-rating)
(defvar org-srs-review-item)
(declare-function org-srs-item-marker "ext:org-srs-item" (item &optional id buffer))
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))

(defcustom readq-card-lapse-threshold 3
  "How many failures of its card bring an extract back to the queue.
A failure is rating the card \"again\" in org-srs, or a lapse in Anki.
After the extract came back, the count starts anew.  Nil turns this off."
  :type '(choice (const :tag "Never bring extracts back" nil) integer)
  :group 'readq-flashcards)

(defcustom readq-card-lapse-check-anki t
  "Non-nil to ask Anki for failed cards once a day, at `readq-next'.
Nothing happens when Anki is not running.  `readq-check-failed-cards'
asks at any time."
  :type 'boolean
  :group 'readq-flashcards)

(defcustom readq-relearn-show-source t
  "Non-nil to show the source beside an extract that came back.
That is an extract whose card you kept failing, when it comes up for
review.  Your bookmark in the book does not move."
  :type 'boolean
  :group 'readq-flashcards)

(defun readq--relearn (item)
  "Bring extract ITEM, whose card keeps failing, back to the queue today."
  (readq--put item
              :status 'active
              :due (readq--today)
              :interval 1
              :lapses-handled (or (readq--get item :lapses) 0)
              :relearn (readq--today))
  (readq--queue-changed))

(defun readq--card-lapses (item lapses)
  "Record that the card of extract ITEM has failed LAPSES times in all.
Return non-nil when that brought the extract back to the queue."
  (unless (eql lapses (readq--get item :lapses))
    (readq--put item :lapses lapses)
    (when (and readq-card-lapse-threshold
               (not (readq--get item :relearn))
               (>= (- lapses (or (readq--get item :lapses-handled) 0))
                   readq-card-lapse-threshold))
      (readq--relearn item)
      t)))

;;;; org-srs

(defun readq--srs-rated ()
  "Count a failure for the extract of the org-srs card rated \"again\".
Runs in `org-srs-review-after-rate-hook'."
  (when (and readq-card-lapse-threshold
             (eq (bound-and-true-p org-srs-review-rating) :again))
    (condition-case err
        (when-let* ((marker (or (and (bound-and-true-p org-srs-review-item)
                                     (ignore-errors
                                       (apply #'org-srs-item-marker org-srs-review-item)))
                                (and (derived-mode-p 'org-mode) (point-marker))))
                    (id (org-entry-get marker "READQ_CARD_OF" t))
                    (item (readq--book-by-id id)))
          (when (readq--card-lapses item (1+ (or (readq--get item :lapses) 0)))
            (message "readq: failed %d times; \"%s\" is back in the reading queue"
                     readq-card-lapse-threshold (readq--get item :title)))
          (readq--save))
      (error (message "readq: could not count the failed card: %s"
                      (error-message-string err))))))

(add-hook 'org-srs-review-after-rate-hook #'readq--srs-rated)

;;;; Anki

(defun readq--anki-lapses (items)
  "Return an alist (ITEM . LAPSES) for ITEMS, extracts with an Anki note.
LAPSES is the sum over the note's cards."
  (let* ((ids (mapcar (lambda (x) (plist-get (readq--get x :exported) :anki-id)) items))
         (notes (card-export-anki "notesInfo" `((notes . ,(vconcat ids)))))
         (cards (apply #'append
                       (mapcar (lambda (n) (append (cdr (assq 'cards n)) nil)) notes)))
         (infos (and cards (card-export-anki "cardsInfo" `((cards . ,(vconcat cards))))))
         (by-note (make-hash-table :test #'eql)))
    (dolist (c infos)
      (let ((note (cdr (assq 'note c))))
        (puthash note (+ (gethash note by-note 0) (or (cdr (assq 'lapses c)) 0)) by-note)))
    (cl-loop for x in items
             for id in ids
             when (gethash id by-note)
             collect (cons x (gethash id by-note)))))

(defvar readq--failed-cards-checked nil
  "The day Anki was last asked for failed cards.")

;;;###autoload
(defun readq-check-failed-cards (&optional quiet)
  "Bring back the extracts whose Anki cards you keep failing.
An extract whose card has lapsed `readq-card-lapse-threshold' times
since it was exported, or since it last came back, is due today again.
Only cards added through AnkiConnect are known.  With QUIET, say
nothing unless extracts came back.  Return those extracts."
  (interactive)
  (let ((items (cl-remove-if-not
                (lambda (x) (and (readq--extract-p x)
                                 (plist-get (readq--get x :exported) :anki-id)))
                (readq--books)))
        back)
    (cond
     ((null items)
      (unless quiet (message "No extract has a card in Anki that readq knows")))
     ((not (card-export-anki-reachable-p))
      (unless quiet (user-error "Cannot reach Anki; start it, with the AnkiConnect add-on")))
     (t
      (pcase-dolist (`(,x . ,lapses) (readq--anki-lapses items))
        (when (readq--card-lapses x lapses)
          (push x back)))
      (setq readq--failed-cards-checked (readq--today))
      (readq--save)
      (cond (back
             (message "%d extract%s back in the queue, their cards kept failing: %s"
                      (length back) (if (cdr back) "s are" " is")
                      (mapconcat (lambda (x) (readq--get x :title)) back "; ")))
            ((not quiet) (message "No card has failed %d times" readq-card-lapse-threshold)))))
    back))

(defun readq--check-failed-cards-daily ()
  "Ask Anki for failed cards, the first time today.
Runs in `readq-before-suggest-hook'; never signals."
  (when (and readq-card-lapse-threshold readq-card-lapse-check-anki
             (not (equal readq--failed-cards-checked (readq--today))))
    (setq readq--failed-cards-checked (readq--today))
    (condition-case err (readq-check-failed-cards t)
      (error (message "readq: could not ask Anki for failed cards: %s"
                      (error-message-string err))))))

(add-hook 'readq-before-suggest-hook #'readq--check-failed-cards-daily)

;;;; When it comes up

(defun readq--relearn-p (item)
  "Return non-nil when ITEM is an extract that came back for a failed card."
  (and (readq--extract-p item) (readq--get item :relearn)))

(defun readq--open-relearn (item)
  "Show extract ITEM for review, with its source beside it."
  (when (readq--open-extract item)
    (let ((win (selected-window))
          (book (readq--book-by-id (readq--get item :book))))
      (when (and readq-relearn-show-source book (not (readq--missing-p book)))
        (condition-case err
            (let ((display-buffer-overriding-action
                   '(display-buffer-pop-up-window (inhibit-same-window . t))))
              (readq-goto-source item))
          (error (message "readq: could not show the source: %s"
                          (error-message-string err))))
        (when (window-live-p win) (select-window win)))
      (message "Its card failed %d times.  Reread the source, rework the extract, then %s."
               (or (readq--get item :lapses) 0)
               (substitute-command-keys "\\[readq-next]")))
    t))

(readq--add-opener 5 #'readq--relearn-p #'readq--open-relearn)

(defun readq--relearn-done (item &rest _)
  "Forget that ITEM came back for a failed card, once it was reviewed."
  (when (readq--get item :relearn)
    (readq--put item :relearn nil)))

(add-hook 'readq-rescheduled-functions #'readq--relearn-done)

(provide 'readq-relearn)

;;; readq-relearn.el ends here
