;;; readq-media.el --- Audio and video in mpv -*- lexical-binding: t; -*-

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

(require 'readq-sections)

(defvar json-array-type)
(defvar json-false)
(defvar json-key-type)
(defvar json-object-type)
(defvar readq-media-toc-names)
(declare-function readq--create-figure "readq-extract")
(declare-function readq--create-extract "readq-extract")
(declare-function json-read-from-string "json" (string))

;;;; Audio and video (mpv)

;; Audio and video files, and online videos (URLs, YouTube...), are
;; played in mpv, started by readq.  A small Lua script readq gives mpv
;; reports on mpv's standard output: the duration, title and chapters
;; when the file is loaded, the position every `readq-mpv-interval'
;; seconds, the moments you mark (`readq-mpv-mark-key'), and how
;; playback ended.  When mpv closes, the session is saved: position,
;; progress, listening time, and an extract for each mark.  If mpv's
;; output does not reach Emacs, the position mpv saves on quitting
;; (--save-position-on-quit, in a folder of its own) is used instead.

(defgroup readq-media nil
  "Audio and video in readq, played in mpv."
  :group 'readq
  :prefix "readq-")

(defcustom readq-mpv-program nil
  "The mpv program, or nil to look for it.
On Windows readq prefers mpv.com (next to mpv.exe), whose output
reaches Emacs."
  :type '(choice (const :tag "Find it" nil) file))

(defcustom readq-mpv-args '("--force-window=yes")
  "Extra arguments for mpv when playing.
--force-window=yes gives audio files a window too, so you can pause,
mark and quit there."
  :type '(repeat string))

(defcustom readq-mpv-mark-key "Ctrl+b"
  "Key, in mpv's notation, that marks the current moment as an extract."
  :type 'string)

(defcustom readq-mpv-figure-key "Ctrl+f"
  "Key, in mpv's notation, that saves the frame shown as a figure extract."
  :type 'string)

(defcustom readq-mpv-mark-lead 10
  "Seconds before a marked moment that playing it back starts."
  :type 'number)

(defcustom readq-mpv-interval 5
  "Seconds between two position reports from mpv."
  :type 'number)

(defcustom readq-media-finish-at-end t
  "When non-nil, audio or video played to its end is marked finished.
For a section (a chapter), this is the end of the chapter."
  :type 'boolean)

(defcustom readq-mpv-ytdl-format nil
  "Format for online videos, passed to mpv as --ytdl-format, or nil.
For example \"bestvideo[height<=?720]+bestaudio/best\", or \"bestaudio\"
to only listen."
  :type '(choice (const :tag "mpv's default" nil) string))

(defcustom readq-mpv-ytdl-path nil
  "The yt-dlp program mpv uses for online videos, or nil for mpv's choice."
  :type '(choice (const :tag "mpv's choice" nil) file))

(defconst readq--mpv-script
  "-- readq: report playback to Emacs.  Written by readq.el; do not edit.
local utils = require 'mp.utils'
local opts = {interval = 5, probe = 'no', markkey = 'Ctrl+b', figkey = 'Ctrl+f', shotdir = ''}
require('mp.options').read_options(opts, 'readq')
local last = nil
local function emit(t)
  io.stdout:write('READQ ' .. utils.format_json(t) .. '\\n')
  io.stdout:flush()
end
mp.observe_property('time-pos', 'number', function(_, v) if v then last = v end end)
local loaded, reported = false, false
local function report()
  if reported then return end
  reported = true
  emit({event = 'loaded', duration = mp.get_property_number('duration'),
        title = mp.get_property('media-title'),
        chapters = mp.get_property_native('chapter-list')})
  if opts.probe == 'yes' then mp.command('quit') end
end
-- Streams may learn their duration a moment after loading.
mp.observe_property('duration', 'number', function(_, v)
  if v and loaded then
    if reported then emit({event = 'duration', duration = v}) else report() end
  end
end)
mp.register_event('file-loaded', function()
  loaded = true
  if mp.get_property_number('duration') or opts.probe ~= 'yes' then
    report()
  else
    mp.add_timeout(3, report)
  end
end)
mp.add_periodic_timer(tonumber(opts.interval), function()
  if last then emit({event = 'pos', pos = last}) end
end)
local function mark()
  if last then
    emit({event = 'mark', pos = last})
    mp.osd_message('readq: marked ' .. mp.format_time(last))
  end
end
mp.add_forced_key_binding(opts.markkey, 'readq-mark', mark)
mp.register_script_message('readq-mark', mark)
local shots = 0
local function figure()
  if opts.shotdir == '' then return end
  local pos = mp.get_property_number('time-pos') or last
  shots = shots + 1
  local file = utils.join_path(opts.shotdir, string.format('fig-%d.png', shots))
  if pos and mp.commandv('screenshot-to-file', file, 'video') then
    emit({event = 'figure', pos = pos, file = file})
    mp.osd_message('readq: figure at ' .. mp.format_time(pos))
  else
    mp.osd_message('readq: no picture to take')
  end
end
mp.add_forced_key_binding(opts.figkey, 'readq-figure', figure)
mp.register_script_message('readq-figure', figure)
mp.register_event('end-file', function(e)
  emit({event = 'end', reason = e.reason, pos = last})
end)
"
  "The Lua script readq gives mpv.")

(defvar readq--media-session nil
  "The audio or video playing in mpv, as a plist, or nil.")

(defvar readq--mpv-last-command nil
  "The last command line readq ran mpv with (for troubleshooting).")

(defvar url-allow-non-local-files)

(defun readq--format-time (seconds)
  "Return SECONDS as \"m:ss\" or \"h:mm:ss\"."
  (if (null seconds)
      "?"
    (let* ((s (round seconds)) (h (/ s 3600)) (m (/ (% s 3600) 60)) (sec (% s 60)))
      (if (> h 0) (format "%d:%02d:%02d" h m sec) (format "%d:%02d" m sec)))))

(defun readq--media-p (item)
  "Return non-nil when ITEM is audio or video, or a section of one."
  (and (not (readq--extract-p item))
       (eq (readq--get (readq--item-book item) :format) 'media)))

(defun readq--media-kind (book)
  "Return \"online\", \"video\" or \"audio\" for the media BOOK."
  (cond ((readq--url-p (readq--get book :file)) "online")
        ((member (downcase (or (file-name-extension (readq--get book :file)) ""))
                 '("mp4" "m4v" "mkv" "webm" "mov" "avi"))
         "video")
        (t "audio")))

(defun readq--media-target (book)
  "Return what mpv plays for BOOK: its file name or URL."
  (let ((file (readq--get book :file)))
    (if (readq--url-p file) file (expand-file-name file))))

(defun readq--mpv-program ()
  "Return the mpv program to run."
  (let ((windows (memq system-type '(windows-nt ms-dos cygwin))))
    (or readq-mpv-program
        (let ((exe (executable-find "mpv")))
          (if (and exe windows)
              (let ((com (concat (file-name-sans-extension exe) ".com")))
                (if (file-exists-p com) com exe))
            exe))
        (and windows
             (cl-find-if #'file-exists-p
                         (delq nil
                               (list "C:/Program Files/mpv/mpv.com"
                                     "C:/Program Files/mpv/mpv.exe"
                                     (when-let* ((home (getenv "USERPROFILE")))
                                       (expand-file-name "scoop/apps/mpv/current/mpv.com"
                                                         home))))))
        (user-error "Cannot find mpv; install it or set `readq-mpv-program'"))))

(defun readq--mpv-script-file ()
  "Return the file of readq's mpv script, writing it if needed."
  ;; An absolute name: mpv and Emacs may not agree on "~" (Windows).
  (let ((file (expand-file-name (locate-user-emacs-file "readq-mpv.lua"))))
    (unless (and (file-exists-p file)
                 (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                        readq--mpv-script))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert readq--mpv-script)))
    file))

(defun readq--mpv-ytdl-args ()
  "Return mpv's arguments for online videos."
  (append (and readq-mpv-ytdl-format
               (list (concat "--ytdl-format=" readq-mpv-ytdl-format)))
          (and readq-mpv-ytdl-path
               (list (concat "--script-opts-append=ytdl_hook-ytdl_path="
                             (expand-file-name readq-mpv-ytdl-path))))))

(defun readq--mpv-parse (line)
  "Return the event in an output LINE of readq's mpv script, or nil."
  ;; mpv's status line can come first on the same line.
  (when (string-match "READQ \\({.*}\\)" line)
    (require 'json)
    (let ((json-object-type 'plist)
          (json-array-type 'list)
          (json-key-type 'keyword)
          (json-false nil))
      (ignore-errors (json-read-from-string (match-string 1 line))))))

(defun readq--mpv-probe (target)
  "Ask mpv about TARGET, a file or URL.
Return a plist (:duration :title :chapters), or nil if mpv is missing
or cannot play it.  Online videos take a few seconds."
  (when-let* ((program (ignore-errors (readq--mpv-program))))
    (let* ((buf (generate-new-buffer " *readq-mpv-probe*"))
           (proc (make-process
                  :name "readq-mpv-probe" :buffer buf :noquery t
                  :connection-type 'pipe :sentinel #'ignore
                  :command (append (list program "--no-config" "--really-quiet"
                                         "--vo=null" "--ao=null"
                                         (concat "--script=" (readq--mpv-script-file))
                                         "--script-opts-append=readq-probe=yes")
                                   (readq--mpv-ytdl-args)
                                   (list "--" (if (readq--url-p target) target
                                                (expand-file-name target))))))
           (deadline (+ (float-time) (if (readq--url-p target) 120 20))))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.1))
      (when (process-live-p proc) (delete-process proc))
      (prog1
          (with-current-buffer buf
            (goto-char (point-min))
            (let (event)
              (while (and (not event) (re-search-forward "READQ {.*}" nil t))
                (let ((ev (readq--mpv-parse (match-string 0))))
                  (when (equal (plist-get ev :event) "loaded") (setq event ev))))
              (when event
                (list :duration (plist-get event :duration)
                      :title (plist-get event :title)
                      :chapters (plist-get event :chapters)))))
        (kill-buffer buf)))))

(defun readq--media-outline (book)
  "Return the chapters of the media BOOK as plists (:title :depth :start :end).
They come from its table of contents with timestamps, if it has one
\(see `readq-set-media-toc'), or else from the chapters in the file."
  (if-let* ((toc (readq--media-toc book)))
      (let ((duration (or (readq--get book :total)
                          (let ((d (plist-get (readq--mpv-probe (readq--media-target book))
                                              :duration)))
                            (when d (readq--put book :total (float d)))
                            d))))
        (message "Sections from %s" (car toc))
        (readq--media-toc-paths (readq--media-toc-ends (cdr toc) duration)))
    (readq--media-embedded-chapters book)))

(defun readq--media-embedded-chapters (book)
  "Return the chapters stored in the media BOOK's file.
They are plists as for `readq--media-outline'."
  (let* ((probe (or (readq--mpv-probe (readq--media-target book))
                    (user-error "mpv could not open \"%s\"" (readq--get book :title))))
         (duration (or (plist-get probe :duration) (readq--get book :total)))
         (chapters (plist-get probe :chapters)))
    (when (and duration (not (readq--get book :total)))
      (readq--put book :total duration))
    (cl-loop for (c . rest) on chapters
             for start = (float (plist-get c :time))
             for end = (float (if rest (plist-get (car rest) :time) (or duration start)))
             when (> end start)
             collect (list :title (or (plist-get c :title)
                                      (format "Chapter at %s" (readq--format-time start)))
                           :depth 1 :start start :end end))))

;;;;; Tables of contents for audio and video

;; A table of contents is text with one timestamp per section:
;;
;;   00:02:03 Section 1              * Section 1
;;   00:04:55 Section 2              00:01:04 Sub-section 1
;;                                   00:03:24 Sub-section 2
;;                                   * Section 2
;;                                   00:11:04 Sub-section 1
;;
;; Times are H:MM:SS, MM:SS or M:SS (with fractions, in brackets or not),
;; at the start or end of the line.  Org "*" or Markdown "#" headings
;; give levels; a heading without a time starts with its first timed line.

(defcustom readq-media-toc-names
  '("%s.toc" "%s.chapters" "%s.chapters.txt" "%s.txt" "%s.org" "%s.md")
  "Files next to an audio or video file that can be its table of contents.
In each, %s is the media file's name without extension.  The first that
has timestamps is used, unless one was chosen with `readq-set-media-toc'."
  :type '(repeat string))

(defconst readq--toc-time-re
  "\\(?:\\([0-9]+\\):\\)?\\([0-9]\\{1,2\\}\\):\\([0-9]\\{2\\}\\)\\(?:[.,]\\([0-9]+\\)\\)?"
  "Regexp matching a timestamp; groups: hours, minutes, seconds, fraction.")

(defun readq--toc-seconds (string &optional offset)
  "Return the seconds of the timestamp matched by `readq--toc-time-re' in STRING.
Its groups come OFFSET groups after the start of the regexp matched (0
by default).  Return nil when it is not a valid time."
  (let* ((o (or offset 0))
         (hours (match-beginning (+ o 1)))
         (h (if hours (string-to-number (match-string (+ o 1) string)) 0))
         (m (string-to-number (match-string (+ o 2) string)))
         (s (string-to-number (match-string (+ o 3) string)))
         (frac (match-string (+ o 4) string)))
    (when (and (< s 60) (or (not hours) (< m 60)))
      (+ (* 3600 h) (* 60 m) s
         (if frac (/ (string-to-number frac) (expt 10.0 (length frac))) 0)))))

(defun readq--toc-split (text)
  "Split TEXT, one line of a table of contents, into (SECONDS . TITLE).
Return nil when it has no timestamp."
  (let ((case-fold-search nil)
        (marker "\\`[-–—•+*]?[ \t]*\\(?:[0-9]+[.)][ \t]+\\)?")
        ;; "]" first in a class is literal; Emacs classes have no escapes.
        (sep "[ \t]*[]–—:|.)-]?[ \t]*"))
    (cond
     ;; "00:01:04 Title", "- [1:04] Title", "1. 01:04 - Title"
     ((string-match (concat marker "[[(]?" readq--toc-time-re "[])]?" sep "\\(.*\\)\\'") text)
      (let ((seconds (readq--toc-seconds text))
            (title (string-trim (match-string 5 text))))
        (when seconds (cons (float seconds) title))))
     ;; "Title - 1:04", "Title (01:04)"
     ((string-match (concat "\\`\\(.*?\\)[ \t]*[-–—|]?[ \t]*[[(]?" readq--toc-time-re
                            "[])]?[ \t]*\\'")
                    text)
      (let ((seconds (readq--toc-seconds text 1))
            (title (string-trim (match-string 1 text))))
        (when (and seconds (not (string-empty-p title)))
          (cons (float seconds) title)))))))

(defun readq--parse-media-toc (text)
  "Parse the table of contents TEXT into plists (:title :depth :start).
Entries are in the order of TEXT; see `readq-media-toc-names' for the
format.  Untimed headings start with their first timed line."
  (let ((level 0) pending entries)
    (dolist (line (split-string text "\n"))
      (let* ((line (string-trim-right line))
             (heading (and (string-match "\\`\\(\\*+\\|#+\\)[ \t]+\\(.*\\)" line)
                           (cons (length (match-string 1 line))
                                 (string-trim (match-string 2 line)))))
             (timed (readq--toc-split (if heading (cdr heading) (string-trim line)))))
        (cond
         (heading
          (setq level (car heading)
                ;; Untimed headings at this level or deeper had no time.
                pending (cl-remove-if (lambda (p) (>= (car p) level)) pending))
          (if timed
              (progn
                (dolist (p pending)
                  (push (list :title (cdr p) :depth (car p) :start (car timed)) entries))
                (setq pending nil)
                (push (list :title (readq--toc-title timed) :depth level
                            :start (car timed))
                      entries))
            (setq pending (append pending (list heading)))))
         (timed
          (dolist (p pending)
            (push (list :title (cdr p) :depth (car p) :start (car timed)) entries))
          (setq pending nil)
          (push (list :title (readq--toc-title timed) :depth (1+ level) :start (car timed))
                entries)))))
    (nreverse entries)))

(defun readq--toc-title (timed)
  "Return the title of the TIMED entry (SECONDS . TITLE)."
  (if (string-empty-p (cdr timed))
      (format "Chapter at %s" (readq--format-time (car timed)))
    (cdr timed)))

(defun readq--media-toc-ends (entries duration)
  "Fill in :end for ENTRIES: the next start at their depth or above, or DURATION."
  (let ((tail entries))
    (while tail
      (let* ((e (car tail))
             (next (cl-find-if (lambda (n) (and (<= (plist-get n :depth) (plist-get e :depth))
                                                (> (plist-get n :start) (plist-get e :start))))
                               (cdr tail))))
        (plist-put e :end (cond (next (plist-get next :start))
                                (duration (max (plist-get e :start) (float duration))))))
      (setq tail (cdr tail)))
    (cl-remove-if (lambda (e) (and (plist-get e :end) (<= (plist-get e :end) (plist-get e :start))))
                  entries)))

(defun readq--media-toc-paths (entries)
  "Give the sub-sections in ENTRIES a :path naming their parents too.
Sub-sections are often called alike (\"Part 1\" in every chapter), so
the queue shows \"Section 1 › Part 1\"."
  (let (parents)
    (dolist (e entries entries)
      (let ((depth (plist-get e :depth)))
        (setq parents (cl-remove-if (lambda (p) (>= (car p) depth)) parents))
        (when parents
          (plist-put e :path (mapconcat #'identity
                                        (append (reverse (mapcar #'cdr parents))
                                                (list (plist-get e :title)))
                                        " › ")))
        (push (cons depth (plist-get e :title)) parents)))))

(defun readq--media-toc-file (book)
  "Return the table of contents file of the media BOOK, or nil.
That is the one chosen with `readq-set-media-toc', or else the first of
`readq-media-toc-names' next to it that has timestamps."
  (let ((chosen (readq--get book :toc-file))
        (file (readq--get book :file)))
    (cond
     (chosen (and (file-readable-p chosen) chosen))
     ((readq--url-p file) nil)
     (t (let ((base (file-name-sans-extension (expand-file-name file))))
          (cl-find-if (lambda (f)
                        (and (file-readable-p f)
                             (not (readq--same-file-p (readq--normalize-file f)
                                                      (readq--get book :file)))
                             (not (readq--own-file-p f))
                             (readq--parse-media-toc (readq--file-text f))))
                      (mapcar (lambda (pattern) (format pattern base))
                              readq-media-toc-names)))))))

(defun readq--file-text (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun readq--media-toc (book)
  "Return the table of contents of the media BOOK as (SOURCE . ENTRIES), or nil.
SOURCE describes where it comes from."
  (let ((text (readq--get book :toc-text))
        (file (unless (readq--get book :toc-text) (readq--media-toc-file book))))
    (when-let* ((entries (cond (text (readq--parse-media-toc text))
                              (file (readq--parse-media-toc (readq--file-text file))))))
      (cons (if text "the text you gave" (abbreviate-file-name file)) entries))))

(defun readq-set-media-toc (book &optional file clear)
  "Give the audio or video BOOK a table of contents with timestamps.
FILE holds it; when the region is active, its text is used instead
\(paste the chapter list of a YouTube description in any buffer and
select it).  With a prefix argument (CLEAR), forget the chosen one, so
that a file next to BOOK or its embedded chapters are used again."
  (interactive
   (let ((b (readq--item-book (readq--target-book "Table of contents of: "))))
     (unless (eq (readq--get b :format) 'media)
       (user-error "Only audio and video take a table of contents with timestamps"))
     (list b
           (unless (or current-prefix-arg (use-region-p))
             (read-file-name "Table of contents file: " nil nil t
                             (let ((f (readq--media-toc-file b)))
                               (and f (file-name-nondirectory f)))))
           current-prefix-arg)))
  (cond
   (clear
    (readq--put book :toc-file nil :toc-text nil)
    (readq--changed book "\"%s\" uses %s" (readq--get book :title)
                    (if (readq--media-toc book) "the table of contents next to it"
                      "its own chapters")))
   (t
    (let* ((text (if (and (not file) (use-region-p))
                     (buffer-substring-no-properties (region-beginning) (region-end))
                   (readq--file-text file)))
           (entries (readq--parse-media-toc text)))
      (unless entries (user-error "No timestamps found (like 00:02:03 Section 1)"))
      (if file
          (readq--put book :toc-file (abbreviate-file-name (expand-file-name file))
                      :toc-text nil)
        (readq--put book :toc-text text :toc-file nil))
      (when (use-region-p) (deactivate-mark))
      (readq--changed book "\"%s\": table of contents with %d entr%s; choose sections with %s"
                      (readq--get book :title) (length entries)
                      (if (= (length entries) 1) "y" "ies")
                      (substitute-command-keys "\\[readq-add-sections]"))))))

;;;;; Playing

(defun readq--media-playing-p ()
  "Return non-nil when readq is playing something in mpv."
  (and readq--media-session t))

(defun readq--media-resume (item)
  "Return where to start playing ITEM, in seconds."
  (let* ((section (readq--section-p item))
         (start (if section (readq--get item :start) 0))
         (time (readq--get item :time)))
    (if (or (null time)
            (eq (readq--get item :status) 'finished)
            (readq--at-end-p item)
            (and section (or (< time start)
                              (and (readq--get item :end)
                                   (>= time (readq--get item :end))))))
        start
      time)))

(defun readq--open-media (item &optional start peek)
  "Play ITEM (audio, video, or a section of one) in mpv.
Start at START seconds, by default where you left it.  With PEEK, only
look something up: your place in ITEM is not changed.  Return t."
  (let* ((book (readq--item-book item))
         (section (and (readq--section-p item) (not peek)))
         (program (readq--mpv-program)))
    (when (readq--missing-p book)
      (user-error "Missing file: %s" (readq--get book :file)))
    (when (readq--media-playing-p) (readq--media-stop))
    (let* ((from (or start (readq--media-resume item)))
           (wl (make-temp-file "readq-mpv" t))
           (shots (make-temp-file "readq-shots" t))
           (args (append
                  (list "--quiet"         ; no status line on the output
                        (concat "--script=" (readq--mpv-script-file))
                        (format "--script-opts-append=readq-interval=%s" readq-mpv-interval)
                        (format "--script-opts-append=readq-markkey=%s" readq-mpv-mark-key)
                        (format "--script-opts-append=readq-figkey=%s" readq-mpv-figure-key)
                        ;; mpv takes forward slashes on Windows too.
                        (concat "--script-opts-append=readq-shotdir="
                                (replace-regexp-in-string "\\\\" "/" shots))
                        (format "--start=%.3f" from)
                        "--save-position-on-quit" "--resume-playback=no"
                        (concat "--watch-later-dir=" wl))
                  (and section (readq--get item :end)
                       (list (format "--end=%.3f" (readq--get item :end))))
                  (readq--mpv-ytdl-args)
                  readq-mpv-args
                  (list "--" (readq--media-target book))))
           (proc (make-process :name "readq-mpv"
                               :buffer (get-buffer-create " *readq-mpv*")
                               :command (cons program args)
                               :connection-type 'pipe
                               :noquery t
                               :filter #'readq--mpv-filter
                               :sentinel #'readq--mpv-sentinel)))
      (setq readq--mpv-last-command (cons program args)
            readq--media-session
            (list :id (readq--get item :id) :process proc :started (float-time)
                  :from from :time nil :duration nil :reason nil :marks nil
                  :peek peek :wl wl :shots shots :figures nil :partial ""))
      (message "Playing \"%s\" from %s in mpv.  %s marks a moment, %s takes a figure; close mpv when done."
               (readq--get item :title) (readq--format-time from) readq-mpv-mark-key
               readq-mpv-figure-key)
      t)))

(defun readq--mpv-filter (proc string)
  "Read the reports of readq's mpv script from PROC's output STRING."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert string)))
  (let ((session readq--media-session))
    (when (and session (eq (plist-get session :process) proc))
      (let ((text (concat (plist-get session :partial) string)))
        ;; mpv redraws its status line with carriage returns.
        (while (string-match "[\r\n]" text)
          (let ((ev (readq--mpv-parse (substring text 0 (match-beginning 0)))))
            (setq text (substring text (match-end 0)))
            (pcase (plist-get ev :event)
              ((or "loaded" "duration")
               (when (plist-get ev :duration)
                 (plist-put session :duration (plist-get ev :duration))))
              ("pos" (plist-put session :time (plist-get ev :pos)))
              ("mark" (plist-put session :marks
                                 (cons (plist-get ev :pos) (plist-get session :marks))))
              ("figure" (plist-put session :figures
                                   (cons (cons (plist-get ev :pos) (plist-get ev :file))
                                         (plist-get session :figures))))
              ("end" (plist-put session :reason (plist-get ev :reason))
               (when (plist-get ev :pos) (plist-put session :time (plist-get ev :pos)))))))
        (plist-put session :partial text)))))

(defun readq--mpv-sentinel (proc _event)
  "Save the session when the mpv PROC ends."
  (when (and (not (process-live-p proc))
             readq--media-session
             (eq (plist-get readq--media-session :process) proc))
    (readq--media-finish readq--media-session (process-exit-status proc))))

(defun readq--watch-later-time (dir)
  "Return the position mpv saved on quitting in DIR, or nil."
  (when (and dir (file-directory-p dir))
    (cl-some (lambda (f)
               (with-temp-buffer
                 (insert-file-contents f)
                 (goto-char (point-min))
                 (when (re-search-forward "^start=\\([0-9.]+\\)" nil t)
                   (string-to-number (match-string 1)))))
             (directory-files dir t "\\`[^.]"))))

(defun readq--media-progress (item time duration)
  "Return the progress of ITEM at TIME seconds, DURATION being the length."
  (if (readq--section-p item)
      (readq--section-progress item (list :time time))
    (and duration (> duration 0) (max 0.0 (min 1.0 (/ time (float duration)))))))

(defun readq--media-finish (session &optional exit)
  "Save the media SESSION that ended; EXIT is mpv's exit status.
Return the item that was played."
  (setq readq--media-session nil)
  (let* ((item (readq--book-by-id (plist-get session :id)))
         (book (and item (readq--item-book item)))
         (reason (plist-get session :reason))
         (saved (readq--watch-later-time (plist-get session :wl)))
         ;; Without the script's reports, mpv saved no position if it
         ;; played to the end.
         (eof (or (equal reason "eof")
                  (and (null reason) (null saved) (eql exit 0)
                       (null (plist-get session :time)))))
         (time (if reason (plist-get session :time) (or saved (plist-get session :time))))
         (peek (plist-get session :peek))
         (secs (min (round (- (float-time) (plist-get session :started)))
                    (* 60 readq-external-max-session-minutes))))
    (ignore-errors (delete-directory (plist-get session :wl) t))
    (when item
      ;; Streams may first underestimate their duration: keep the largest
      ;; known, and at least the position reached at the end.
      (let* ((duration (let ((known (delq nil (list (plist-get session :duration)
                                                    (readq--get book :total)
                                                    (and eof (plist-get session :time))))))
                         (and known (apply #'max known))))
             (end (if (readq--section-p item) (or (readq--get item :end) duration) duration)))
        (when duration (readq--put book :total (float duration)))
        ;; The last section of a table of contents ends with the file.
        (when (and end (readq--section-p item) (not (readq--get item :end)))
          (readq--put item :end (float end)))
        (unless peek
          (let ((from-time (readq--get item :time))
                (from (or (readq--get item :progress) 0))
                (time (if (and eof end) end time)))
            (when time
              (readq--put item :time time)
              (when-let* ((progress (readq--media-progress item time duration)))
                (readq--put item :progress progress)))
            (readq--add-seconds item secs)
            (when (or eof (>= secs readq-min-session-seconds)
                      (and time (or (null from-time) (> (abs (- time from-time)) 1))))
              (readq--count-session item nil from secs))
            (when (and eof readq-media-finish-at-end)
              (readq--put item :status 'finished :finished-on (readq--today)))))
        ;; Each marked moment becomes an extract.
        (let ((priority (min 100 (max 0 (+ (readq--get item :priority)
                                           readq-extract-priority-offset))))
              (tags (and (readq--section-p item) (readq--get item :tags))))
          (dolist (mark (reverse (plist-get session :marks)))
            (readq--create-extract book "" :page mark :point mark
                                   :priority priority :tags tags))
          ;; And each frame taken, a figure extract.
          (dolist (fig (reverse (plist-get session :figures)))
            (when (file-exists-p (cdr fig))
              (readq--create-figure book (list :file (cdr fig)) :page (car fig)
                                    :point (car fig) :priority priority :tags tags
                                    :time (file-attribute-modification-time
                                           (file-attributes (cdr fig)))))))
        (readq--save)
        (readq--queue-changed)
        (message "%s \"%s\"%s%s"
                 (if peek "Played" "Saved")
                 (readq--get item :title)
                 (cond (peek "")
                       ((eq (readq--get item :status) 'finished) " — finished")
                       (t (format " at %s, comes back %s"
                                  (readq--format-time (readq--get item :time))
                                  (readq--get item :due))))
                 (concat
                  (let ((n (length (plist-get session :marks))))
                    (if (> n 0) (format "; %d mark%s became extracts" n (if (= n 1) "" "s"))
                      ""))
                  (let ((n (length (plist-get session :figures))))
                    (if (> n 0) (format "; %d figure extract%s" n (if (= n 1) "" "s"))
                      ""))))))
    (when-let* ((shots (plist-get session :shots)))
      (ignore-errors (delete-directory shots t)))
    item))

(defun readq--media-stop ()
  "Close mpv and save the session.  Return the item that was playing."
  (let* ((session readq--media-session)
         (proc (plist-get session :process))
         (id (plist-get session :id)))
    (when (process-live-p proc)
      ;; mpv saves its state on SIGTERM; Windows has no signals.
      (if (memq system-type '(windows-nt ms-dos))
          (delete-process proc)
        (signal-process proc 'SIGTERM))
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (when (process-live-p proc) (delete-process proc)))
    (when (eq readq--media-session session)
      (readq--media-finish session (and proc (process-exit-status proc))))
    (readq--book-by-id id)))

(defun readq-media-mark ()
  "Mark the moment playing in mpv, as `readq-mpv-mark-key' does in mpv.
The moment is the last one mpv reported, at most `readq-mpv-interval'
seconds ago."
  (interactive)
  (let ((session readq--media-session))
    (unless session (user-error "Nothing is playing in mpv"))
    (let ((time (plist-get session :time)))
      (unless time (user-error "mpv has not reported a position yet"))
      (plist-put session :marks (cons time (plist-get session :marks)))
      (message "Marked %s" (readq--format-time time)))))

;;;###autoload
(defun readq-add-url (url priority &optional title tags)
  "Add the online video or audio at URL (YouTube...) with PRIORITY.
TITLE defaults to the one mpv finds; TAGS is a list of tags.  mpv
plays it through yt-dlp, which must be installed."
  (interactive
   (let* ((default (or (thing-at-point 'url t)
                       (let ((kill (ignore-errors (current-kill 0 t))))
                         (and kill (readq--url-p (string-trim kill)) (string-trim kill)))))
          (url (string-trim (read-string (format-prompt "URL" default) nil nil default))))
     (unless (readq--url-p url) (user-error "Not a URL: %s" url))
     (when (readq--book-by-file url) (user-error "Already in your queue: %s" url))
     (message "Asking mpv about %s..." url)
     (let ((probe (readq--mpv-probe url)))
       (setq readq--known-probe (cons url probe))
       (list url (readq--read-priority)
             (read-string "Title: " (or (plist-get probe :title) url))
             (and readq-ask-tags (readq--read-tags "Tags (optional): "))))))
  (unless (readq--url-p url) (user-error "Not a URL: %s" url))
  (prog1 (readq-add-book url priority (or title url) tags)
    (setq readq--known-probe nil)))

(defun readq--media-stop-quietly ()
  "Stop mpv if it is playing, without complaining."
  (when (readq--media-playing-p) (ignore-errors (readq--media-stop))))

;; How audio and video are opened, finished and saved with the rest.
(readq--add-opener 20 #'readq--media-p #'readq--open-media)
(readq--add-finisher 30 #'readq--media-playing-p #'readq--media-stop)
(add-hook 'readq-save-all-hook #'readq--media-stop-quietly)

(provide 'readq-media)
;;; readq-media.el ends here
