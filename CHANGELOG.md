# Changelog

What changed in readq, newest first. Version numbers follow [semantic versioning](https://semver.org/): the middle number goes up when something is added or changes how your files are stored, the last one for fixes.

## 0.3.0 (2026-11-16)

- **Three things to do with a passage.** `C-c r H` (`readq-highlight`) only highlights it: in a PDF the highlight is saved into the file, in green (`readq-highlight-color`); in an EPUB, a text or a web page readq remembers it and shows it again. `C-c r K` (`readq-extract-keep`) makes an extract that is kept as a note but never comes up. `C-c r e` makes an extract for review, as before. On a highlight with nothing selected, `C-c r e` or `C-c r K` makes it an extract; `C-c r J` (`readq-find-highlight`) jumps to a highlight; `C-u C-c r H` removes one.
- **Card drafts from a model.** `C-c r Q` (`readq-draft-cards`) asks the model gptel is set up with for a few cloze and question drafts of an extract. The one you choose is written into the note for you to correct. Needs the gptel package; nothing is exported by itself.
- **Failed cards send you back to the source.** When the card of an extract has failed `readq-card-lapse-threshold` times (3), the extract is due again today and opens with its place in the book beside it. org-srs failures are counted as you rate; Anki is asked once a day while it is running, or with `M-x readq-check-failed-cards`.
- **Exam mode.** `C-c r t` (`readq-exam`) takes a name, a date and tags, and plans back: reading with a deadline, then days for extracts only, then days for cards only, with the daily budget growing over the last two weeks. `C-c r L` shows the plan.
- **A manual in Emacs.** `C-h R readq`, or `C-c r h` (`readq-manual`), opens readq's Info manual: a practical guide by task, with an index of every command and option (`i`). Its source is `doc/readq.org`; `make info` rebuilds it.
- The README is now a short introduction; the details moved to the manual.

## 0.2.0 (2026-11-15)

### Changed: where and how things are stored

- **Extracts are Denote notes.** Each extract is one Org file in one flat folder (`~/notes/`), named and written the way Denote does it, with no property drawers. Extracts made before are turned into notes with `M-x readq-convert-extracts`; the old files are kept.
- **Figures live in `~/notes/figures/`**, with the same file names as before.
- **The queue file has a version number.** An older file is brought up to date step by step when it is read, and the daily backup made before that keeps the old one.
- Removed: `readq-group-extracts`, `readq-narrow-to-extract`, `readq-extracts-fallback-directory`.

### Changed: scheduling

- Books come back at a steady rhythm set by their priority, from every day to once a week (`readq-book-schedule`, `readq-book-min-interval`, `readq-book-max-interval`). Extracts still drift apart.
- An extract reviewed late gets credit for the wait (`readq-late-credit`).
- A short session moves an item less far than a full one (`readq-session-weight-floor`).
- New dates avoid days that are already full (`readq-schedule-fuzz`).
- An item pushed past the daily budget again and again waits longer each time, low priority first (`readq-overflow-stretch`, `readq-overflow-stretch-after`).

### Faster

- The dashboard is redrawn once after a command, and only while it is on screen; a hidden one is redrawn when you come back to it.
- The queue is written to disk a moment after the last change (`readq-save-delay`), not at every change. It is still written at once when Emacs closes.
- Whether a book's file is still there is checked every 30 seconds at most (`readq-file-check-seconds`), not at every look at the queue.
- Each item keeps the sessions of its last 400 days, and at least its last 20 (`readq-history-days`, `readq-history-length`), so the queue file stops growing. Reading stats look back a year at most and do not change.
- Looking up an item, a book's extracts or an extract's children no longer walks the whole queue.

### Inside

- **Viewers are a table.** What readq needs from pdf-tools, doc-view, nov.el or readq-comic (where am I, go there, what is selected) is declared with `readq-define-viewer`. Everything readq knows about pdf-canvas is now one file, `readq-pdf-canvas.el`, which is the example to follow for another viewer.
- **The files hear from each other through hooks**: `readq-queue-changed-hook`, `readq-reading-functions`, `readq-rescheduled-functions`, `readq-book-display-hook`, `readq-save-all-hook`. The core no longer names the dashboard, mpv, extracts or deadlines.
- **The setup check is made of small checks** listed in `readq-doctor-functions`, so an add-on can add its own.
- **Checks run on GitHub** for every change, on Emacs 30.1 and on the development version of Emacs: every file must compile without a warning, and the tests run with nov.el, consult, Denote, org-srs, multi-region, mpv and ripgrep installed.
- `make check` compiles and tests on your machine.
- `readq-version` holds the version number.

## 0.1.0 (2026-10-07 to 2026-11-15)

Everything before version numbers were kept: the queue with priorities, PDF, EPUB, comic, text, HTML, audio and video books, SumatraPDF, sections, tags and focus, the daily budget, deadlines, extracts and figures, flashcards for org-srs and Anki, extract search, stale extracts, reading stats, subset review, chapters in the dashboard, reading aloud with Kokoro, backups and the setup check.
