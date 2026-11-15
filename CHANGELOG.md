# Changelog

What changed in readq, newest first. Version numbers follow [semantic versioning](https://semver.org/): the middle number goes up when something is added or changes how your files are stored, the last one for fixes.

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
