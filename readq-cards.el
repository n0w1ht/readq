;;; readq-cards.el --- Flashcards from extracts -*- lexical-binding: t; -*-

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

;;; Code:

(require 'readq-extract-tools)

(defvar readq-review-mode)
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-find-property "org" (property &optional value))

;;;;; Flashcards

;; Extracts you have boiled down become flashcards:
;;
;; - An extract whose text contains cloze deletions, written
;;   {{hidden text}} or {{hidden text::hint}} (`readq-cloze' adds them),
;;   becomes a cloze card.  Anki's {{c1::...}} form works too: clozes
;;   with the same number are hidden together.
;; - Any other extract becomes a question/answer card: its heading is
;;   the question and its text the answer.
;;
;; `readq-mark-ready' tags an extract as ready; `readq-export-cards'
;; sends every ready extract to org-srs or Anki.

(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-toggle-tag "org" (tag &optional onoff))
(declare-function org-get-tags "org" (&optional epom local))
(declare-function org-export-string-as "ox" (string backend &optional body-only ext-plist))
(defvar url-http-end-of-headers)
(defvar url-request-method)
(defvar url-request-data)
(defvar url-request-extra-headers)
(defvar url-proxy-services)
(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)
(declare-function json-encode "json" (object))
(declare-function json-read-from-string "json" (string))
(declare-function outline-next-heading "outline" ())
(declare-function url-do-setup "url" ())

(defalias 'readq-cloze #'card-export-anki-cloze
  "Hide the selected text in a cloze deletion: {{text}}.
With a prefix argument, ask for a hint: {{text::hint}}.")

(defun readq--extract-content (item)
  "Read extract ITEM from its Org file.
Return a plist (:heading :text :note), or nil if it cannot be found.
The text is the entry's body without the Source line, quote block
markers and \"Note:\" lines; notes are returned in :note."
  (require 'org)
  (let ((file (readq--get item :file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (when-let* ((pos (org-find-property "READQ_ID" (readq--get item :id))))
              (goto-char pos)
              (let* ((heading (org-get-heading t t t t))
                     (beg (progn (org-end-of-meta-data t) (point)))
                     (end (progn (goto-char pos) (outline-next-heading) (point)))
                     (lines (split-string (buffer-substring-no-properties
                                           (min beg end) end)
                                          "\n"))
                     notes body)
                (dolist (line lines)
                  (cond ((string-match "\\`Source: \\[\\[readq:" line))
                        ((string-match "\\`Note: \\(.*\\)" line)
                         (push (match-string 1 line) notes))
                        (t (push line body))))
                (list :heading heading
                      :text (readq--org-unescape (mapconcat #'identity (nreverse body) "\n"))
                      :note (and notes (mapconcat #'identity (nreverse notes) "\n")))))))))))

(defun readq--make-card (item)
  "Return a flashcard plist for extract ITEM, or nil if it has no text."
  (when-let* ((content (readq--extract-content item))
              (book (readq--book-by-id (readq--get item :book))))
    (let* ((text (card-export-anki-number-clozes (plist-get content :text)))
           (clozes (length (card-export-anki-cloze-ids text))))
      (unless (string-empty-p text)
        (list :item item
              :book book
              :type (if (> clozes 0) 'cloze 'basic)
              :clozes clozes
              :front (plist-get content :heading)
              :text text
              :note (plist-get content :note)
              :source (readq--source-description book (readq--get item :page)
                                                 (readq--get item :section)))))))

(defun readq--update-entry-tags (item add remove)
  "Add the tags ADD to the Org entry of ITEM and remove the tags REMOVE.
Also pick up the entry's heading as ITEM's title, in case you edited it."
  (require 'org)
  (let ((file (readq--get item :file)))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (save-restriction
            (widen)
            (when-let* ((pos (org-find-property "READQ_ID" (readq--get item :id))))
              (goto-char pos)
              (let ((title (org-get-heading t t t t)))
                (unless (string-empty-p title) (readq--put item :title title)))
              (dolist (tag remove) (org-toggle-tag tag 'off))
              (dolist (tag add) (org-toggle-tag tag 'on))
              (let ((save-silently t)) (save-buffer)))))))))

(defun readq-mark-ready (item)
  "Mark extract ITEM as ready to become a flashcard, or unmark it.
A ready extract leaves the reading queue until `readq-export-cards'
turns it into a card.  When you are reviewing it, go on with
`readq-next'."
  (interactive (list (readq--target-book "Mark ready for a flashcard: ")))
  (unless (readq--extract-p item)
    (user-error "Only extracts can become flashcards"))
  (let ((reviewing (and readq-review-mode
                        (equal readq--review-id (readq--get item :id))))
        (ready (not (eq (readq--get item :status) 'ready))))
    (when reviewing (readq--end-review))
    (readq--put item :status (if ready 'ready 'active))
    (when ready (readq--put item :exported nil))
    (readq--update-entry-tags item
                              (and ready (list readq-card-ready-tag))
                              (if ready (list readq-card-exported-tag)
                                (list readq-card-ready-tag)))
    (readq--save)
    (readq--refresh-dashboard)
    (message (if ready "\"%s\" is ready to become a flashcard (%s exports)"
               "\"%s\" is back in the reading queue")
             (readq--get item :title)
             (substitute-command-keys "\\[readq-export-cards]"))
    (when (and reviewing ready) (readq-next))))

(defun readq--ready-extracts ()
  "Return the extracts to export: marked ready, or tagged ready in Org."
  (require 'org)
  (let* ((extracts (cl-remove-if-not
                    (lambda (x) (and (readq--extract-p x) (not (readq--missing-p x))))
                    (readq--books)))
         (files (delete-dups (mapcar (lambda (x) (readq--get x :file)) extracts)))
         (tagged nil))
    (dolist (file files)
      (with-current-buffer (find-file-noselect file)
        (save-restriction
          (widen)
          (setq tagged (append (delq nil (org-map-entries
                                          (lambda () (org-entry-get nil "READQ_ID"))
                                          readq-card-ready-tag 'file))
                               tagged)))))
    (cl-remove-if-not (lambda (x) (or (eq (readq--get x :status) 'ready)
                                      (member (readq--get x :id) tagged)))
                      extracts)))

(defun readq--mark-exported (item backend &optional anki-id anki-hash)
  "Record that extract ITEM was exported to BACKEND.
ANKI-ID and ANKI-HASH, the note's id in Anki and the hash of what was
sent, let `readq-update-anki-cards' update the note later."
  (readq--put item
              :exported (append (list :date (readq--today) :backend backend)
                                (and anki-id (list :anki-id anki-id :anki-hash anki-hash)))
              :status (if readq-dismiss-after-export 'finished 'active))
  (readq--update-entry-tags item (list readq-card-exported-tag)
                            (list readq-card-ready-tag)))

(defun readq--read-backend (ask)
  "Return the flashcard backend, asking when ASK or configured to."
  (pcase (and (not ask) readq-flashcard-backend)
    ('anki 'anki)
    ((or 'org-srs 'org-drill) 'org-srs)   ; org-drill: the backend before org-srs
    (_ (intern (completing-read "Export flashcards to: " '("anki" "org-srs") nil t)))))

;;;###autoload
(defun readq-export-cards (backend)
  "Turn the extracts marked ready into flashcards in BACKEND.
BACKEND is `anki' or `org-srs', see `readq-flashcard-backend'; with
a prefix argument, choose it.  Return the number of cards exported."
  (interactive (list (readq--read-backend current-prefix-arg)))
  (let* ((items (readq--ready-extracts))
         (cards (delq nil (mapcar #'readq--make-card items)))
         (empty (- (length items) (length cards)))
         (unedited (cl-count-if
                    (lambda (c) (and (eq (plist-get c :type) 'basic)
                                     (string-prefix-p
                                      (string-remove-suffix "…" (plist-get c :front))
                                      (plist-get c :text))))
                    cards)))
    (unless items
      (user-error "No extract is ready; mark extracts with `readq-mark-ready'"))
    (let ((done (pcase backend
                  ('org-srs (readq--export-org-srs cards))
                  ('anki (readq--export-anki cards))
                  (_ (user-error "Unknown flashcard backend: %s" backend)))))
      (dolist (card done)
        (readq--mark-exported (plist-get card :item) backend
                              (plist-get card :anki-id) (plist-get card :anki-hash)))
      (readq--save)
      (readq--refresh-dashboard)
      (message "Exported %d flashcard%s to %s%s%s"
               (length done) (if (= (length done) 1) "" "s")
               (if (eq backend 'anki) "Anki" "org-srs")
               (if (> empty 0) (format "; %d ready extract%s had no text" empty
                                       (if (= empty 1) "" "s"))
                 "")
               (if (> unedited 0)
                   (format "; %d question%s still the start of the answer (edit the heading)"
                           unedited (if (= unedited 1) " is" "s are"))
                 ""))
      (length done))))

;;;;;; org-srs

(defun readq--srs-file (book)
  "Return the org-srs file receiving the cards of BOOK."
  (if readq-srs-file
      (expand-file-name readq-srs-file)
    (concat (file-name-sans-extension (expand-file-name (readq--extracts-file book)))
            "-cards.org")))

(defun readq--srs-entry (card)
  "Return the Org entry for CARD, before org-srs adds its review items.
A question/answer card's answer is under Back, where org-srs looks for
it; a cloze card's clozes are in its body."
  (let* ((item (plist-get card :item))
         (cloze (eq (plist-get card :type) 'cloze))
         (note (plist-get card :note))
         (tags (readq--item-tags item))
         ;; Image links survive the cloze conversion and the move to
         ;; another folder.
         (images (readq--images-for-org (plist-get card :text) (readq--card-directory card)))
         (text (car images)))
    (concat "* " (if cloze (plist-get card :source) (plist-get card :front))
            (if tags (concat " :" (mapconcat #'identity tags ":") ":") "") "\n"
            ":PROPERTIES:\n:READQ_CARD_OF: " (readq--get item :id) "\n:END:\n"
            (readq--restore-org-images
             (if cloze
                 (concat (card-export-org-body (card-export-anki-cloze-to-srs text)) "\n")
               (concat "** Back\n" (card-export-org-body text) "\n"))
             (cdr images))
            (if note (concat (if cloze "** Note\n" "") (card-export-org-body note) "\n") "")
            "** Source\n[[readq:" (readq--get item :id) "][" (plist-get card :source) "]]\n\n")))

(defun readq--srs-add-items (card)
  "Add the org-srs review items of CARD to the entry at point.
A question/answer card gets one; a cloze card one per cloze number."
  (if (eq (plist-get card :type) 'cloze)
      (card-export-srs-make-cloze-card
       (card-export-anki-cloze-ids (plist-get card :text)))
    (card-export-srs-make-card)))

(defun readq--export-org-srs (cards)
  "Append CARDS to org-srs files.  Return the cards exported."
  (require 'org)
  (unless (card-export-srs-available-p)
    (user-error "org-srs is not installed"))
  (dolist (card cards)
    (let* ((book (plist-get card :book))
           (file (readq--srs-file book))
           (buf (progn (make-directory (file-name-directory file) t)
                       (find-file-noselect file))))
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (when (= (buffer-size) 0)
              (insert (if readq-srs-file
                          "#+TITLE: Flashcards from readq\n"
                        (format "#+TITLE: Flashcards from %s\n" (readq--get book :title)))
                      "#+STARTUP: overview\n\n"))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (let ((start (point)))
              (insert (readq--srs-entry card))
              (goto-char start)
              (readq--srs-add-items card)))))))
  (dolist (file (delete-dups (mapcar (lambda (c) (readq--srs-file (plist-get c :book))) cards)))
    (with-current-buffer (find-file-noselect file)
      (let ((save-silently t)) (save-buffer))))
  cards)

;;;;;; Anki

(defun readq--anki-deck (book)
  "Return the Anki deck for cards of BOOK."
  (if readq-anki-subdeck-per-book
      (concat readq-anki-deck "::" (replace-regexp-in-string "::" ":" (readq--get book :title)))
    readq-anki-deck))

(defun readq--anki-note (card)
  "Return the Anki note for CARD, a card-export plist."
  (let* ((book (plist-get card :book))
         (note (plist-get card :note))
         (text (readq--images-for-anki (plist-get card :text) (readq--card-directory card)))
         (extra (concat (if note (concat (card-export-org-to-html note) "\n") "")
                        "<div class=\"readq-source\">"
                        (card-export-html-escape (plist-get card :source)) "</div>"))
         (tags (append readq-anki-tags
                       (list (concat "readq-" (readq--slug (readq--get book :title))))
                       (readq--item-tags (plist-get card :item)))))
    (if (eq (plist-get card :type) 'cloze)
        (pcase-let ((`(,model ,text-field ,extra-field) readq-anki-cloze-model))
          (list :model model :deck (readq--anki-deck book)
                :fields (list (cons text-field (card-export-org-to-html text))
                              (cons extra-field extra))
                :tags tags :media (readq--anki-media card)))
      (pcase-let ((`(,model ,front-field ,back-field) readq-anki-basic-model))
        (list :model model :deck (readq--anki-deck book)
              :fields (list (cons front-field (card-export-html-escape (plist-get card :front)))
                            (cons back-field (concat (card-export-org-to-html text)
                                                     "\n" extra)))
              :tags tags :media (readq--anki-media card))))))

(defun readq--anki-added (cards notes results)
  "Return CARDS that Anki now has, given the NOTES sent and their RESULTS.
A new note's id and hash go with its card, to update it later; the
cards Anki refused are listed in a warning."
  (let (done failed)
    (cl-loop for card in cards
             for note in notes
             for result in results
             do (cond ((eq (car-safe result) 'error)
                       (push (cons card (cdr result)) failed))
                      ((numberp result)
                       (push (append card (list :anki-id result
                                                :anki-hash (card-export-note-hash note)))
                             done))
                      (t (push card done))))     ; a duplicate
    (when failed
      (display-warning
       'readq
       (concat "Some cards could not be added to Anki:\n"
               (mapconcat (lambda (f) (format "- %s: %s"
                                              (plist-get (car f) :front) (cdr f)))
                          (nreverse failed) "\n"))))
    (nreverse done)))

(defun readq--export-anki (cards)
  "Send CARDS to Anki, see `readq-anki-method'.  Return the cards exported."
  (let* ((file (expand-file-name readq-anki-export-file))
         (notes (mapcar #'readq--anki-note cards))
         (sent (card-export-anki-send notes file
                                      (and (eq readq-anki-method 'file) 'file))))
    (if (eq (car sent) 'anki)
        (readq--anki-added cards notes (cdr sent))
      (when-let* ((missing (card-export-anki-copy-media notes readq-anki-media-directory)))
        (display-warning
         'readq
         (concat "These figures must go in Anki's media folder (collection.media)"
                 " for the cards to show them; set `readq-anki-media-directory'"
                 " to have readq copy them:\n"
                 (mapconcat (lambda (m) (format "- %s as %s" (cdr m) (car m)))
                            missing "\n"))))
      (message "Wrote %d card%s to %s; import it in Anki with File > Import"
               (length cards) (if (= (length cards) 1) "" "s") file)
      cards)))

;;;###autoload
(defun readq-update-anki-cards ()
  "Send the extracts you edited since exporting them to their Anki notes.
Only cards added through AnkiConnect can be updated: readq knows their
notes.  Tags you added in Anki stay.  Return the number updated."
  (interactive)
  (unless (card-export-anki-reachable-p)
    (user-error "Cannot reach Anki; start it, with the AnkiConnect add-on"))
  (let ((cards nil) (updated 0) missing failed)
    (dolist (x (readq--books))
      (let ((exported (readq--get x :exported)))
        (when-let* ((id (plist-get exported :anki-id))
                    ((readq--extract-p x))
                    ((not (readq--missing-p x)))
                    (card (readq--make-card x)))
          (push (list card (readq--anki-note card) id (plist-get exported :anki-hash))
                cards))))
    (pcase-dolist (`(,card ,status ,hash) (card-export-anki-update-changed (nreverse cards)))
      (let ((x (plist-get card :item)))
        (pcase status
          ('updated (readq--put x :exported
                                (plist-put (copy-sequence (readq--get x :exported))
                                           :anki-hash hash))
                    (setq updated (1+ updated)))
          ('missing (push card missing))
          (`(error . ,msg) (push (cons card msg) failed)))))
    (readq--save)
    (when (or missing failed)
      (display-warning
       'readq
       (concat
        (if missing
            (concat "Anki no longer has these cards; mark their extracts ready \
(`readq-mark-ready') to add them again:\n"
                    (mapconcat (lambda (c) (format "- %s" (plist-get c :front)))
                               (nreverse missing) "\n")
                    "\n")
          "")
        (if failed
            (concat "These cards could not be updated:\n"
                    (mapconcat (lambda (f) (format "- %s: %s" (plist-get (car f) :front) (cdr f)))
                               (nreverse failed) "\n"))
          ""))))
    (message "Updated %d card%s in Anki" updated (if (= updated 1) "" "s"))
    updated))

(provide 'readq-cards)
;;; readq-cards.el ends here
