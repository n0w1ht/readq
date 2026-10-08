# readq — incremental reading for Emacs

readq keeps a **reading queue** of everything you are working through: books, chapters, your own notes, web pages, lectures and videos. It tells you **what to read next**. Each item has a priority. Important items come back almost every day, and less important ones come back less and less often. readq remembers exactly where you stopped in each one.

It works the way SuperMemo's *incremental reading* does:

1. **Read** an item for a while.
2. Press **`C-c r n`** (`readq-next`). readq saves your place and reading time, reschedules the item by its priority, and opens the most important item that is due.
3. **Extract** passages worth keeping. Each extract becomes an item of its own in the queue, which you review, trim and split over time.
4. Once an extract holds just the fact you want to remember, turn it into a **flashcard** for org-drill or Anki.

| What | Read in | Tracked by |
|------|---------|------------|
| **PDF** | pdf-tools (`pdf-view-mode`), `doc-view-mode`, or **SumatraPDF** | page |
| **EPUB** | nov.el (`nov-mode`) | chapter and position in the chapter |
| **Org, Markdown, plain text** (`.org` `.md` `.markdown` `.txt`) | whatever mode they open in | position, found again by the words there |
| **HTML** (`.html` `.htm`) | eww, Emacs' built-in browser | position in the page |
| **Audio and video** (`.mp3` `.m4a` `.m4b` `.aac` `.ogg` `.opus` `.flac` `.wav` `.mp4` `.m4v` `.mkv` `.webm` `.mov` `.avi`) | **mpv** | time |
| **Online video** (YouTube and other sites) | mpv with yt-dlp | time |

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Checking your setup](#checking-your-setup)
- [Quick start](#quick-start)
- [How readq thinks](#how-readq-thinks): items, priorities, sessions
- [Your daily routine](#your-daily-routine)
- [Daily budget](#daily-budget): a limit on how much you read each day
- [Deadlines](#deadlines): finish a book or a tag by a date
- [Books by format](#books-by-format)
- [Reading PDFs in SumatraPDF](#reading-pdfs-in-sumatrapdf)
- [Sections](#sections): chapters as queue items
- [Tags and focus](#tags-and-focus)
- [Extracts](#extracts)
- [Searching extracts](#searching-extracts)
- [Stale extracts](#stale-extracts): extracts you never act on
- [Figures](#figures): diagrams and pictures as extracts
- [Flashcards](#flashcards)
- [Audio and video](#audio-and-video)
- [Org links](#org-links)
- [Reading stats](#reading-stats)
- [The dashboard](#the-dashboard)
- [Key reference](#key-reference)
- [How scheduling works](#how-scheduling-works)
- [Customization](#customization)
- [Backups](#backups)
- [Files readq creates](#files-readq-creates)
- [Windows notes](#windows-notes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Running the tests](#running-the-tests)

---

## Requirements

readq is a single file, `readq.el`, and needs **Emacs 27.1** or later. Everything else is optional. Install only what you use.

| For | You need |
|-----|----------|
| PDFs in Emacs | [pdf-tools](https://github.com/vedang/pdf-tools) (recommended), or the built-in `doc-view-mode` |
| EPUBs | [nov.el](https://depp.brause.cc/nov.el/) |
| Importing highlights from SumatraPDF or other PDF viewers | pdf-tools, whose `epdfinfo` program reads the PDF |
| Reading PDFs in SumatraPDF | [SumatraPDF](https://www.sumatrapdfreader.org/) 3.4 or later (Windows) |
| Live search of your extracts | [consult](https://github.com/minad/consult) and [ripgrep](https://github.com/BurntSushi/ripgrep) (`winget install BurntSushi.ripgrep.MSVC`). Without them, search still works, more slowly. |
| Icons in the dashboard | [all-the-icons](https://github.com/domtronn/all-the-icons.el) and its fonts |
| Markdown files in `markdown-mode` | [markdown-mode](https://jblevins.org/projects/markdown-mode/). Without it they open in `fundamental-mode` and are still tracked. |
| Audio and video | [mpv](https://mpv.io/installation/) |
| Online videos | mpv, plus [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases) |
| Selecting several passages in any book | [multi-region](#with-multi-region), version 0.2 or later |
| Flashcards in org-drill | [org-drill](https://gitlab.com/phillord/org-drill) |
| Flashcards sent straight to Anki | Anki with the [AnkiConnect](https://ankiweb.net/shared/info/2055492159) add-on. Without it, readq writes a file for Anki's import. |

Extracts are stored in Org files, and Org comes with Emacs.

## Installation

```elisp
;; Plain
(add-to-list 'load-path "~/path/to/readq")
(require 'readq)
(readq-mode 1)
(global-set-key (kbd "C-c r") 'readq-command-map)

;; or with use-package
(use-package readq
  :load-path "~/path/to/readq"
  :config (readq-mode 1)
  :bind-keymap ("C-c r" . readq-command-map))
```

This README uses `C-c r` as the prefix. Any other key works too.

**`readq-mode`** is the global mode that does the tracking. When you open a queued book, it jumps back to where you stopped. It also saves your position as you read and counts your reading time, pausing the count while you are idle. Commands such as `readq`, `readq-open` and `readq-next` turn it on if it is off. Buffers of queued books get the minor mode `readq-book-mode`, shown as `RQ:26%` in the mode line.

## Checking your setup

`M-x readq-doctor` (`C-c r ?`) checks everything readq relies on outside Emacs and shows a report:

```
readq setup check
1 problem

ok  Database    ~/.emacs.d/readq.eld: 42 books, 310 extracts
ok  Backups     14 in ~/.emacs.d/readq-backups/, newest 2026-10-08
ok  pdf-tools   epdfinfo works (c:/msys64/mingw64/bin/epdfinfo.exe)
XX  nov.el      cannot find unzip (`nov-unzip-program'); install it, e.g. with scoop install unzip
ok  SumatraPDF  ~/AppData/Local/SumatraPDF/SumatraPDF.exe
ok  mpv         mpv v0.39.0 (c:/Program Files/mpv/mpv.com)
--  Clipboard   PowerShell found; to test figures, copy an image (Ctrl+drag, Ctrl+C in SumatraPDF) and run this again
```

It looks at the database and its backups, books whose files have moved, pdf-tools and `epdfinfo`, nov.el and `unzip`, SumatraPDF and its settings file (including whether *Remember opened files* is on), mpv, yt-dlp, reading images from the clipboard, org-drill, AnkiConnect, ripgrep (for searching extracts), and the dashboard's icon fonts.

`XX` is a problem with something you use, `!!` something that may not work, `ok` is fine, and `--` is a note about something you don't use yet. Press `g` to check again after fixing something. Run it once after installing readq, and again whenever something stops working.

## Quick start

1. **`C-c r a`** adds a book. Pick a file, then give it a **priority from 0 (most important) to 100 (least important)** and, optionally, tags such as `cardio`. **`C-c r A`** adds every book in a folder and its subfolders.
2. **`C-c r n`** opens the book you should read now.
3. Read. To keep a passage, select it and press **`C-c r e`** to make an extract.
4. **`C-c r n`** again when you have read enough. readq saves your place and opens the next item, which may be another book or an extract that is due.
5. **`C-c r l`** (or `M-x readq`) shows the whole queue.

That's the core. The rest of this README covers each part in detail.

## How readq thinks

### Items

Everything in the queue is an **item**, with its own priority, schedule, position, progress and reading time. There are four kinds:

| Item | What it is |
|------|------------|
| **Book** | A file you added: PDF, EPUB, Org, Markdown, text, HTML, audio, video, or an online video. |
| **Section** | A chapter or part of a book, chosen from its table of contents and read as an item of its own. Reading it doesn't move the book's own bookmark. See [Sections](#sections). |
| **Extract** | A passage you kept, stored in an Org file next to the book. A marked moment in a recording is an extract too. See [Extracts](#extracts). |
| **Sub-extract** | An extract made from inside another extract. |

### Priority

**0 is the most important and 100 the least.** Priority decides two things:

- the **order** of items due on the same day (lower number first);
- how fast the **interval** between sessions grows. A priority-5 book comes back every day or two for a long time. A priority-90 book soon comes back only every few weeks.

You can change priorities at any time: `=` in the dashboard sets one, and `+` / `-` change it by `readq-priority-step` (5).

### Sessions

A **session** is one sitting with an item. It ends:

- when you run `readq-next` (`C-c r n`) or `readq-finish-session` (`C-c r f`);
- when you kill the book's buffer;
- when you close mpv, for audio and video.

At the end of a session, readq saves your position and reading time. The session **counts as a review**, which reschedules the item, if you moved forward, or if you read for at least `readq-min-session-seconds` (60). Just glancing at a book doesn't reschedule it.

You don't have to go through `readq-next`. If you open a queued file in any usual way (`C-x C-f`, dired, a bookmark), readq recognises it, restores your place and tracks the session.

## Your daily routine

- **`C-c r n`**: finish what you are reading and open the next due item. If nothing is due, readq offers to read ahead with the item due soonest.
- **`C-c r s`** (`readq-suggest`) lists, in the echo area, what is due today, in order, without opening anything.
- **`C-u C-c r n`** asks for tags and reads next only from those, e.g. "only from #cardio".
- **`C-c r f`**: finish the session without opening anything else.
- **Reaching the end** of a book makes readq offer to mark it **finished**. Finished items are no longer suggested. `f` in the dashboard toggles this.
- **Not today?** `z` (postpone) multiplies the item's interval by `readq-postpone-factor` (1.5). `C-u z` asks for a number of days instead. `r` (reschedule) says "read again in N days".
- **Not for a while?** `x` **pauses** an item. Paused items are never suggested until you resume them with `x` again.
- **Enough for today?** readq keeps to a [daily budget](#daily-budget) of 90 minutes by default. Once it is used up, `C-c r n` asks before opening more.

## Daily budget

Incremental reading queues tend to pile up: every extract and every book comes back, and a few busy days leave more due than you can read. readq plans each day up to a **budget**, so what it asks of you stays doable.

### Setting the budget

```elisp
(setq readq-daily-minutes 90)   ; minutes a day (the default); nil for no limit
(setq readq-daily-items 25)     ; and/or items a day (default nil)
```

With both set, the stricter one wins. To turn the budget off entirely, set both to nil.

### How readq fills a day

- **Time already read today counts.** Every session adds its reading time to today's total, including the time spent reviewing extracts.
- **Each due item has an estimate**: the median length of its last 5 sessions. An item never read yet is assumed to take `readq-default-book-minutes` (15) for a book, section or recording, and `readq-default-extract-minutes` (2) for an extract.
- **Due items fill what is left of the budget, most important first.** An item that starts within the budget may run over it a little; a 2-hour lecture still gets read on a 90-minute day.
- **Important items are always kept.** Items with priority `readq-workload-protected-priority` (10) or lower stay due today even when the budget is used up. They use up the budget like any other item. Set it to -1 to protect nothing.
- **The budget is for all your reading.** A focus on some tags doesn't change it.

### What happens to the rest

`readq-workload-overflow` decides:

- **`spread`** (default): the first time readq looks at the queue each day (the dashboard or `C-c r n`), due items that don't fit get new due dates over the next days. The most important ones get the earliest days, and each day is filled up to its budget, counting what is already due then. Their intervals don't change; only the date moves. Items are moved at most `readq-workload-spread-days` (30) ahead. `M-x readq-spread-overflow` (`S` in the forecast) does it again by hand.
- **`hold`**: due dates stay as they are. Items that don't fit stay due and wait, and the most important ones get the first room the next day. Nothing is moved, but the backlog can keep growing.

### When the budget is used up

With `readq-workload-stop` set to `ask` (the default), `C-c r n` says so and asks whether to keep reading. If you say yes, it doesn't ask again that day. Set it to nil to keep going without asking. Protected items open without asking either way.

### Seeing the load

`L` in the dashboard (or `C-c r L`, `M-x readq-workload`) shows today and the next 14 days:

```
Budget: 90 min per day.  Over budget: spread over the next days.

Today Wed 07      95 min    6 items  ████████████████████  52 min read
Thu 08 Oct        84 min    7 items  ███████████████████░
Fri 09 Oct        30 min    2 items  ███████░░░░░░░░░░░░░
Sat 10 Oct       102 min    8 items  ████████████████████
```

Today shows what you've read plus what is planned. Days over the budget are highlighted. In this buffer `g` refreshes and `S` spreads today's overflow again.

The dashboard's mode line shows today's progress, e.g. `— today 52/90 min`. It is highlighted once the budget is used up.

## Deadlines

A deadline says "finish this by a date": a book before an exam, or everything tagged `#cardio` by 1 December. readq tells you the pace you need and brings the items back often enough to make it.

### Setting a deadline

- **For an item:** press `!` on a book, section or recording in the dashboard, or `C-c r !` while reading it.
- **For a tag:** `C-u !` (or `M-x readq-set-tag-deadline`) and pick the tag. Every book, section and recording with that tag is included, also through a book's tags.

Type the date as `org-read-date` understands it: `1 dec`, `+3w`, `2026-12-01`. An empty answer clears the deadline.

The deadline day itself doesn't count as a reading day: "by 1 December" means finished by the end of 30 November. When an item has its own deadline and a tag's, the earlier one applies.

What counts:

- **Extracts have no deadlines.** You are never "done" with an extract, so they keep their normal schedule.
- **Books read through sections.** A book whose chapters are in the queue as sections is left out of tag deadlines. Its sections count instead, so only the chapters you chose have to be finished. If the book is paused, as readq suggests when you add sections, it doesn't count either.

### Pace

readq measures what is left of each item:

| Item | Measured in |
|------|-------------|
| PDF book or section | pages |
| audio, video, or one of their chapters | minutes |
| EPUB, Org, Markdown, text, HTML | percent |

It divides that by the days left and shows the **daily target**, e.g. `12 p/d`. It also compares where you are with an even pace from the day the deadline began to apply. If you've fallen behind, you see how far, e.g. `-20 p`.

### Scheduling

An item under a deadline comes back often enough to be finished in time. readq knows its pace per session from your last 5 sessions (`readq-deadline-pace-sessions`). It works out how many sessions are left, and shortens the interval when needed. A low-priority book that would wait 3 weeks comes back every 5 days if that's what the deadline needs. Until readq knows your pace, and in the last days, the item comes back daily. Setting a deadline brings a far-off due date forward at once.

With the [daily budget](#daily-budget), **the deadline wins**: due items with a deadline take their place in the budget first, are kept even over it, are never spread to later days, and open without the "keep reading?" question. Set `readq-deadline-overrides-budget` to nil to make the budget win instead. Deadline items then still take their place in the budget first, but they can be spread like the rest.

### Seeing your deadlines

- **Dashboard:** the *Deadline* column shows the date and daily target (`01 Dec 12 p/d`), how far behind you are (`01 Dec -20 p`), `missed`, or `done`. It sorts by date.
- **Forecast:** `L` lists every deadline at the top, soonest first, with each item's progress:

  ```
  Deadlines:
    #cardio by Mon 01 Dec (55 days left)
      Guyton › Heart                         120 p left     2.2 p/day  on track
      Cardiology lecture 4                    40 min left   0.7 min/day  behind by 10 min
  ```

- **After a session:** the message says what is left, e.g. `120 p left of "Guyton › Heart" by 2026-12-01 (#cardio): 2.2 p a day`.

## Books by format

### PDF

- **pdf-tools** (`pdf-view-mode`) is the best way to read PDFs. readq saves your page on every page change. You can make extracts with highlights saved into the PDF, choose chapters from the PDF's outline, and import highlights made in other viewers.
- **doc-view-mode** works for tracking pages. Extracts and highlights need pdf-tools.
- **SumatraPDF**: see [Reading PDFs in SumatraPDF](#reading-pdfs-in-sumatrapdf).

Progress is `page / total pages`, shown as e.g. `p 312/1200`.

### EPUB

EPUBs open in **nov.el**. readq tracks the chapter and your position inside it, and restores both. Progress is `(chapter + fraction of the chapter) / chapters`, shown as `ch 3/12`. nov.el counts the table of contents page of EPUB 2 books as a chapter.

Extracted passages are highlighted when you come back to their chapter (`readq-show-extracts-in-epub`).

### Org, Markdown and plain text

Org files open in `org-mode` and Markdown files in `markdown-mode` (if installed). readq tracks them in whatever mode they open in.

- **They can change.** These are often your own notes, which you edit between sessions. Along with your position, readq stores a few words of the text there, and finds your place again by those words. Adding or removing text above your place, even whole sections, doesn't lose it. Folded Org headings are unfolded to show your place.
- **Position** is the section you're in, counted by headings (`*` in Org, `#` in Markdown), e.g. `§ 3/12`. For a file without headings it is a percentage. **Progress** is how far through the file you are.
- **Extracts** name their section as their source, e.g. `Physiology notes, Systole`, and that name appears on flashcards too.
- If a book is itself an Org file, such as `notes.org`, its extracts go to `notes-extracts.org`.

### HTML

HTML files open formatted in **eww**, each book in its own buffer. Headings `<h1>`–`<h4>` count as sections. Extracts from eww have eww's line breaks removed.

If you follow a link out of an HTML book, readq ends the reading session. When you come back, with eww's back button (`l`) or by opening the book again, it picks up where you were.

### Other formats

`readq-file-extensions` maps file extensions to the way they are read:

```elisp
;; page-based files, read like PDFs (e.g. DjVu in doc-view-mode)
(add-to-list 'readq-file-extensions '("djvu" . pdf))
;; another text format
(add-to-list 'readq-file-extensions '("rst" . text))
```

## Reading PDFs in SumatraPDF

You can read some or all PDFs in [SumatraPDF](https://www.sumatrapdfreader.org/) instead of Emacs. readq **follows your page there by itself**.

- **One book:** press `v` on it in the dashboard (or `C-c r v`) and choose `sumatra`. The dashboard's *Kind* column then shows `sumatra`.
- **All PDFs:** `(setq readq-default-pdf-viewer 'sumatra)`. `v` switches a single book back to `emacs`.

A session in SumatraPDF goes like this:

1. `readq-next` (or `RET` in the dashboard) opens the book in a SumatraPDF window **at your saved page** and starts timing.
2. Read and highlight in SumatraPDF.
3. **Close the document** in SumatraPDF (`Ctrl+W`, or close the window). readq reads the page you stopped at from SumatraPDF, records your progress and reading time, and reschedules the book. Nothing to type. If SumatraPDF asks whether to save your annotations, save them to the PDF, so readq can import your highlights as extracts.
4. `C-c r n` opens the next item.

**How readq knows your page.** SumatraPDF remembers the last page of every document in its settings file, `SumatraPDF-settings.txt`, and writes it when you close a document or quit. readq reads it there. readq looks for that file next to `SumatraPDF.exe` (the portable version) and in `%LOCALAPPDATA%\SumatraPDF\` (the installed one); set `readq-sumatra-settings-file` if yours is elsewhere. Keep SumatraPDF's *Remember opened files* option on, which it is by default.

- **`C-c r n` while the PDF is still open:** SumatraPDF hasn't saved your page yet, so readq asks you to close the document there first, then reads it. Answer `n` to type the page instead.
- **SumatraPDF already open:** if SumatraPDF is set to reuse its window (*ReuseInstance*), the book opens there, and readq watches the settings file until you close it.
- **Reading time** runs from opening the book until you close it, up to `readq-external-max-session-minutes` (120).
- A *section* of a PDF read in SumatraPDF opens at the section's first page, and its progress is tracked within the section.
- **Looking up an extract** (`C-c r g`) shows its page in the SumatraPDF window already open, without starting a session.

Books you had set to Okular before now open in SumatraPDF.

## Sections

Big books are rarely read cover to cover. Sections let you put chosen **chapters or parts into the queue as items of their own**, each with its own priority and schedule. For example, the cardiology chapters of Harrison's could be at priority 5, the renal chapters at 30, and the rest left out.

### Choosing sections

Press `T` on a book in the dashboard, or `C-c r T` (`readq-add-sections`). readq lists the book's table of contents, indented by level, with where each entry is:

```
   Pri  Section                              Where
 *  10  Part 1: The heart                    p 1–4
          Chapter 1: Anatomy                 p 1–2
 *   5    Chapter 2: The cardiac cycle       p 3–4
        Part 2: The vessels                  p 5–8
          Chapter 3: Arteries                p 5–8      in queue
```

| Key | Action |
|-----|--------|
| `m` / `u` | mark / unmark the entry. A marked entry gets the book's priority. |
| `=` | mark the entry with a priority you type |
| `M` | mark every entry at the same level, e.g. all chapters |
| `U` | unmark everything |
| `x` | add the marked entries to the queue |
| `q` | close the list |

After `x`, readq offers to **pause the book itself**, so that only the chosen sections come up. `x` in the dashboard resumes it later.

Where the table of contents comes from:

| Book | Table of contents | A section covers |
|------|-------------------|------------------|
| PDF | the PDF's outline (bookmarks), read with pdf-tools | its page up to the page before the next entry at its level |
| EPUB | the book's table of contents, read with nov.el | its chapter files |
| Org, Markdown | the headings (`*`, `#`) | the heading with everything under it |
| HTML | the `<h1>`–`<h4>` headings | the heading with everything under it |
| Audio, video | the recording's chapters, or [your own table of contents with timestamps](#your-own-table-of-contents) | from its start time to its end time |

**PDFs without an outline**, or without pdf-tools: `M-x readq-add-section` adds a section by its pages. It asks for a title, the first page and the last page.

### Reading a section

`readq-next` (or `RET` in the dashboard) opens a section in its book. It opens where you left the section, or at the section's beginning the first time. While you read it:

- **Your position, progress and time count for the section.** The mode line shows `RQ:§45%`. The **book's own bookmark doesn't move**. The book's *Time* column includes time spent in its sections.
- When you reach the end of the section, readq tells you. The next `C-c r n` offers to mark the section finished.
- **Extracts** you make get the section's priority and its tags.
- To read the book from its own bookmark again, open the book itself (`C-c r o`, or `RET` on it in the dashboard).

**Text books keep their sections.** Sections of Org, Markdown and HTML books are found by their heading each time. Edits to the file, even adding whole sections above, don't lose them.

**In the dashboard**, a section shows as `Book › Chapter`, with *Kind* `section`. Its position is within its range, e.g. `p 7 (5–8)` or `12:40 (10:00–25:00)`.

**Removing and relocating.** Removing a book removes its sections too. Relocating a book (`R`) updates its sections.

## Tags and focus

Tags group items across books: `#cardio`, `#renal`, `#exam`, `#leisure`. Use them to read only from one group for a while.

### Tagging

- **When adding**, readq asks for tags. Leave the answer empty for none, or set `readq-ask-tags` to nil to stop asking. Adding a folder gives all its books the same tags.
- **Afterwards:** `#` in the dashboard or `C-c r #` (`readq-set-tags`), on a book, section or extract.
  - Separate tags with commas or spaces, with or without `#`.
  - Tags you already use are offered as completions.
  - Tags are stored in lower case, with spaces and dashes turned into `_` (`heart failure` becomes `#heart_failure`), so they are valid Org tags.
- **Tags are inherited.** Sections and extracts have their book's tags. A section can add its own tags, and extracts made while reading it get those too. Tagging a book later reaches everything that came from it.

### Reading by tag

- **Once:** `C-u C-c r n` asks for tags and opens the next item that has one of them.
- **For a while:** `C-c r /` (`readq-focus`), or `/` in the dashboard, sets a **focus**. Until you clear it, `readq-next`, `readq-suggest` and the dashboard show only items with those tags. The dashboard's mode line shows `focus: #cardio`. The focus is saved with your queue, so a "cardio week" survives restarting Emacs. Run `C-c r /` again with an empty answer to clear it.
- **Several tags:** items with **any** of them count.
- **Nothing due within the focus:** readq offers to read ahead within those tags, not outside them.

The dashboard has a *Tags* column. Flashcards carry their extract's tags, both as Anki tags and as org-drill heading tags.

## Extracts

An **extract** is a passage you want to come back to. readq stores it in an Org file and puts it in the queue. It starts with its book's priority (plus `readq-extract-priority-offset`) and is first due the next day. From then on, `readq-next` brings extracts up mixed with books, by priority. To stop suggesting extracts, set `readq-queue-extracts` to nil.

### Where extracts are stored

Each book has its own extracts file, **in the same folder as the book**, named after it:

```
C:/Books/Gray's Anatomy.pdf
C:/Books/Gray's Anatomy.org     <- its extracts
```

- **Your own files are never overwritten.** readq never writes into an Org file it didn't create. If `Gray's Anatomy.org` is one of your own files, or two books share a name (`book.pdf` and `book.epub`), the extracts go to `Gray's Anatomy-extracts.org` instead.
- **Read-only folders.** If the book's folder isn't writable, extracts go to `readq-extracts-fallback-directory` (`~/.emacs.d/readq-extracts/`), and readq tells you.
- **All in one place.** To keep every extracts file in one folder, set `readq-extracts-directory`.
- **Moving books.** Relocate a moved book with `R` in the dashboard, and its extracts file comes along. If you moved the whole folder, readq finds the extracts file in its new place. If you moved only the book, readq moves the extracts file next to it.

Each extract is an Org heading. Edit the heading and the text as you like: readq finds the extract by its `READQ_ID` property.

```org
#+READQ_BOOK: Guyton Physiology

* Systole is the phase of contraction of the ventricles, whic…
:PROPERTIES:
:READQ_ID: 6ac2c90a66e3
:END:
Source: [[readq:6ac2c90a66e3][Guyton Physiology, p. 2]]
#+begin_quote
Systole is the phase of contraction of the ventricles, which ejects blood into the aorta
#+end_quote
Note: Key definition
```

The heading starts as the first `readq-extract-title-length` (60) characters of the passage.

### Making extracts

| Where you are | How |
|---|---|
| A PDF in **pdf-tools** | Drag over the text with the mouse, then press `C-c r e`. readq also adds a highlight to the PDF and saves it, so the passage is marked in SumatraPDF too. The highlight color is `readq-extract-highlight-color`; set `readq-extract-add-highlight` to nil for no highlight. |
| An EPUB in **nov.el** | Select the text (`C-SPC` and move), then press `C-c r e`. The passage is highlighted whenever you come back to that chapter. |
| An **Org, Markdown or text** book | Select the text, then press `C-c r e`. The passage is highlighted while you read. |
| A page in **eww** | Select the text, then press `C-c r e`. |
| A PDF in **SumatraPDF** (or another viewer that saves highlights into the PDF) | Highlight as usual, then **save the annotations into the PDF**. See [Importing highlights](#importing-highlights-from-pdfs). |
| A recording in **mpv** | Press `Ctrl+b` in mpv. See [Marking moments](#marking-moments). |
| A **figure** or picture, anywhere | `C-c r P`. See [Figures](#figures). |
| Inside an **extract** | Select part of it and press `C-c r e` to make a **sub-extract**. It becomes a child heading and is scheduled on its own. |

`C-u C-c r e` asks for the extract's priority instead of using the book's.

### Several passages in one extract

Select several separate passages and press `C-c r e`. They become **one extract**, in reading order, each as its own paragraph separated by `readq-extract-separator` (a blank line). Each passage is highlighted in its own place in the book, and in a PDF each one gets its own highlight on its page. The selections are then cleared.

There are two ways to select several passages:

- **In a PDF**, pdf-tools can do it by itself. Drag over the first passage, then `C-drag` (hold Control and drag) over the others, all on the same page.
- **With multi-region**, in any book (see below).

To make **one extract per passage** instead, press `C-u C-u C-c r e`. To make that the default:

```elisp
(setq readq-extract-multiple 'separate)   ; then C-u C-u C-c r e combines
```

### With multi-region

If `multi-region-mode` (version 0.2 or later) is on in the book's buffer, readq uses its selections. multi-region works in:

- PDFs, across pages;
- EPUBs, across chapters;
- Org, Markdown and text books;
- web pages in eww.

Select passages with `C-drag` or `C-c m SPC`, then press `C-c r e`. An active region counts as one more passage. The two packages use different prefixes (`C-c r` and `C-c m`), so their keys don't conflict.

### Importing highlights from PDFs

Highlights saved **inside a PDF** by SumatraPDF or any standards-following viewer become extracts:

- **Automatically**, when you open the dashboard or run `readq-next` and the PDF changed since the last import (`readq-auto-import-highlights`).
- **Right away:** `C-c r i` (or `i` in the dashboard) imports from one book, and `C-c r I` imports from all of them.

The note attached to a highlight becomes the extract's `Note:`. A highlight is imported only once. A deleted extract isn't imported again either, even if its highlight is still in the PDF.

- **Annotation types:** highlights, underlines, squiggly lines and strike-outs are imported (`readq-import-annotation-types`).
- **Partial words:** a highlight that stops in the middle of a word imports the whole word (`readq-highlight-selection-style`: `word`; also `glyph` or `line`).

### Highlight colors

Colors can carry meaning. For example, red for important passages, green for passages you don't want imported, and the book's priority for every other color:

```elisp
(setq readq-highlight-color-rules '(("red" . 5) ("green" . skip)))
```

The color names are `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`, `black` and `white`. readq maps any shade to the nearest of them. Use `t` as the color for a rule that covers every color not listed.

### Reviewing extracts

When `readq-next` brings up an extract, it opens the extract's Org file, narrowed to that extract (`readq-narrow-to-extract`). The mode line shows `RQ:extract`. While reviewing you can:

- **Edit, shorten or rewrite** the text. This is the point of incremental reading: each review boils the extract down a little.
- **Make a sub-extract:** select part of the text and press `C-c r e`.
- **See it in context:** `C-c r g`, or click the *Source* link. A PDF opens at the page (in pdf-tools or SumatraPDF), an EPUB or text book at the passage itself, and a recording plays the moment. This **doesn't move your bookmark** in the book; `C-c r o` takes you back to where you were reading.
- **Move on:** `C-c r n`. The extract is rescheduled by its priority, like a book, and the next item opens.
- **Dismiss it:** `C-c r d`. The extract leaves the queue for good, but its text stays in the Org file.
- **Mark it ready for a flashcard:** `C-c r c` (see [Flashcards](#flashcards)).

`C-c r E` (or `e` in the dashboard) opens a book's whole extracts file.

### Searching extracts

Your extracts are spread over many Org files, one next to each book. Two commands search them all at once:

| Key | Command | Finds |
|-----|---------|-------|
| `C-c r S` | `readq-search` | text anywhere in your extracts, your notes included |
| `C-c r j` | `readq-find-extract` | an extract by its title, text or tags, from a list |

**`readq-search`** runs [consult](https://github.com/minad/consult)'s `consult-ripgrep` on your extracts files only. Results appear as you type, and moving through them previews each one; RET takes you to it. Without ripgrep it uses `consult-grep`. Without consult, or with neither program installed, it asks for a regexp and shows the matches with `multi-occur`.

**`readq-find-extract`** lists every extract, grouped by book, with the start of its text, its tags, its source, priority and due date. Type any part of these to filter. With consult, the extract under the cursor is previewed, and narrowing keys filter the list: `d` due, `f` figures, `p` paused or finished. Type the key and a space at the start of the input, or press it after your `consult-narrow-key`; backspace widens again. Without consult it's an ordinary completion list, which vertico or the default completion shows grouped.

Both take you to the extract's heading in its Org file, where `C-c r g` (go to source), `C-c r c` (ready for a card), `C-c r k` (cloze) and the rest work as usual. Showing an extract this way doesn't review it or change its schedule; `C-c r o` does.

- **Focus.** Both search only extracts in the current [focus](#reading-by-tag), and show the tags in the prompt. With `C-u`, they ask for tags instead; an empty answer searches everything.
- **Dismissed extracts** are found too: `readq-find-extract` lists them (narrow with `p`), and their text is still in the Org files for `readq-search`.
- **Tags in `readq-search`** pick the extracts files to search: a book's file is searched if one of its extracts has the tags, and then all of that file is searched.
- **ripgrep on Windows:** `winget install BurntSushi.ripgrep.MSVC`, then restart Emacs. `readq-doctor` tells you if Emacs can't find it.
- **Many books:** Windows limits how long a command can be. If your extracts files don't fit (`readq-search-max-command-length`), `readq-search` searches the folders that hold them instead, which may include other Org files there.

### Stale extracts

An extract is meant to be worked on: turned into a card, split into sub-extracts, merged with a related one, or dismissed. One that keeps coming back and never gets any of these is **stale**. It costs a review every time and teaches you nothing new.

An extract is stale when it is still in the queue, isn't ready for a card, has no sub-extracts, and either

- has been reviewed `readq-stale-reviews` (5) times, or
- was made `readq-stale-days` (60) days ago and reviewed at least twice.

The dashboard's mode line counts them (`3 stale`). **`C-c r X`** (`readq-stale-extracts`) goes through them, most reviewed first. It shows each in its Org file and asks:

| Key | Does |
|-----|------|
| `c` | **card**: mark it ready for a flashcard |
| `m` | **merge** it into another extract (see below) |
| `d` | **dismiss** it: out of the queue, its text stays in the Org file |
| `D` | **delete** it, with its highlight in the book |
| `l` | **lower** its priority by `readq-stale-priority-step` (20), so it comes back less often, and keep it |
| `k` | **keep** it as it is; it isn't called stale again until as many more reviews or days have passed |
| `e` | **edit**: stop here to write a cloze, make sub-extracts or rewrite it; `C-c r X` again goes on |
| `s` | skip it this time |
| `q` | stop |

Like the searches, it follows your focus, and `C-u` asks for tags instead.

**Merging.** `m`, or `M-x readq-merge-extract` on any extract, appends one extract's text, note and source link to another's, under a `Merged from:` line. It then removes the merged extract from its Org file and the queue. The other extract keeps its schedule. The source link is rewritten to point to the page in the book, so it still works. Extracts of the same book are offered first. An extract with sub-extracts can't be merged.

### Deleting an extract

To get rid of an extract completely, put point on its highlighted passage in the book and press `C-c r D` (`readq-delete-extract`). After you confirm, readq deletes three things:

- **The highlight** in the book. For a PDF, the highlight annotation is removed from the PDF file itself, so it is gone in SumatraPDF too. Other highlights and notes in the PDF are left alone.
- **The note:** the extract's entry in its Org file, with any sub-extracts. The text goes to the kill ring, so `C-y` brings it back if you change your mind.
- **The item** in the queue.

Other places it works:

- **In a PDF**, where there is no point, `C-c r D` takes the extract highlighted on the page shown, or asks which one if there are several.
- **In the extract's Org entry**, `C-c r D` deletes it the same way.
- **In the dashboard**, `D` on an extract.
- **An extract made of several passages** is deleted as a whole, with all its highlights.

To take an extract out of the queue **but keep its note**, dismiss it (`C-c r d`) instead.

If readq can't delete a PDF highlight, for example without pdf-tools or with the PDF locked by another program, it still remembers the extract was deleted, so the highlight isn't imported again.

## Figures

A **figure extract** is an image instead of a passage: a diagram cropped from a PDF page, a picture in an EPUB or web page, a frame of a lecture video, or anything you copy in SumatraPDF. You review it, tag it, schedule it and turn it into a flashcard like any other extract.

### Taking a figure

`C-c r P` (`readq-extract-figure`) takes the figure from wherever you are reading:

| Where you are | What it takes |
|---|---|
| A PDF in pdf-tools | the area you select with **`M-drag`** (a rectangle), cropped from the page at `readq-figure-dpi` (200). A text selection works too; its box is taken. With no selection, readq offers the whole page. |
| An EPUB in nov.el | the image at point |
| A web page in eww, or an HTML book | the image at point |
| An Org or Markdown book | an image link such as `[[file:img/heart.png]]` or `![](img/heart.png)` at point or on the current line, or a displayed image at point |
| A video playing in mpv | the frame mpv last reported (within `readq-mpv-interval` seconds) |
| SumatraPDF, or anywhere else | the image on the clipboard, see below |

If point isn't on an image, readq also looks in the region and on the current line.

readq asks for a **caption**, which becomes the extract's heading, e.g. "Wiggers diagram". Leave it empty for a heading like "Figure: Guyton Physiology, p. 112". To never be asked, set `readq-ask-figure-caption` to nil. With `C-u`, readq also asks for the priority.

### In mpv

Press **`Ctrl+f` in mpv** (`readq-mpv-figure-key`) to save the frame on screen. mpv shows "readq: figure at 23:41". When mpv closes, each frame becomes a figure extract, "Figure: Lecture 4 at 23:41", next to the extracts made from your marks. Its *Source* link plays the moment again. Audio has no picture, and mpv says so.

### In SumatraPDF

The figure goes through the clipboard:

1. Hold `Ctrl` and drag a rectangle over the figure, then press `Ctrl+C` to copy it as an image.
2. In Emacs, press `C-c r y` (`readq-extract-figure-from-clipboard`), or `C-c r P` while the SumatraPDF session is on.
3. readq takes the book you are reading in SumatraPDF, and asks for the page so the *Source* link opens the right one.

This works with any program that copies images: a screenshot tool, a browser, PowerPoint.

### Where figures are stored

All images go in **one folder**, `readq-figures-directory` (`~/.emacs.d/readq-figures/`). Each name gives the book, then the date and time you took it, then the place, so the folder groups figures by book and sorts each book's by date:

```
cardio-lecture-4_2026-10-08_090512_23m41s.png
guyton-physiology_2026-10-07_221346_p112.png
guyton-physiology_2026-10-09_184501_p57.png
robbins-pathology_2026-10-07_223010_ch4.png
```

The place is `p112` for a PDF page, `ch4` for an EPUB chapter, `s3` for a section of an Org, Markdown or web page, and `23m41s` for a moment in a recording. Two figures taken in the same second get `b`, `c`, … after the time, which keeps them in order.

To keep the folder somewhere else, for example in a synced folder:

```elisp
(setq readq-figures-directory "~/Documents/Med school/Figures/")
```

The extract's entry links the image by its full path:

```org
* Wiggers diagram
:PROPERTIES:
:READQ_ID: 9b1f3c20aa71
:END:
Source: [[readq:9b1f3c20aa71][Guyton Physiology, p. 112]]
[[file:~/.emacs.d/readq-figures/guyton-physiology_2026-10-07_221346_p112.png]]
```

- **Moving the folder:** set `readq-figures-directory` to the new place. readq finds the images there for cards and deletion, but the links already in your extracts files still name the old folder, so search and replace it in those files.
- **Reviewing** shows the image inline, `readq-figure-display-width` (600) pixels wide. Write what you need to remember under it.
- **Deleting** the extract (`C-c r D` in its entry, or `D` in the dashboard) deletes the image too.
- **Figures don't change your books.** Nothing is drawn into the PDF.

### Figures in flashcards

A figure extract makes a question/answer card: the caption is the question and the image is the answer. Edit the heading to ask what you want, e.g. "Name the waves of the ECG", and mark it ready with `C-c r c`. You can also write a cloze under the image.

- **org-drill:** the card links the image by its full path, so it shows wherever the cards file is. Turn on inline images in the cards file (`C-c C-x C-v`) to see it while drilling.
- **Anki with AnkiConnect:** readq sends the image to Anki's media folder with the card, under its own name with `readq-` in front.
- **Anki with an import file:** the import file can't carry images. Set `readq-anki-media-directory` to your profile's `collection.media` folder, e.g. `~/AppData/Roaming/Anki2/User 1/collection.media/` on Windows, and readq copies them there. If it is not set, readq lists the images to copy.

## Flashcards

Over several reviews you trim an extract down to the fact you want to remember. Then readq turns it into a flashcard for **org-drill** or **Anki**.

### 1. Shape the extract into a card

The extract's shape decides the card type:

- **Cloze card.** Select the words to hide and press `C-c r k` (`readq-cloze`), which wraps them as `{{words}}`. `C-u C-c r k` adds a hint: `{{words::hint}}`. In Anki each cloze becomes a separate card, and in org-drill each is hidden in turn. To hide several words together, number them the Anki way: `{{c1::first}} … {{c1::second}}`.
  ```org
  #+begin_quote
  The {{mitral}} valve has {{two::number}} cusps.
  #+end_quote
  ```
- **Question/answer card.** With no clozes, the extract's **heading is the question** and its **text is the answer**. Rewrite the heading as a question:
  ```org
  * What is systole?
  ...
  #+begin_quote
  Systole is the phase of contraction of the ventricles.
  #+end_quote
  ```
  If a card's heading is still the beginning of its text, readq warns you when exporting, since that question would give away the answer.

`Note:` lines go on the back of the card. Every card also shows its source (book and page, section or time).

### 2. Mark it ready

Press `C-c r c` (`readq-mark-ready`) while reviewing the extract, or `c` on it in the dashboard. This does three things:

- tags the extract `:ready:` in the Org file (`readq-card-ready-tag`);
- takes it out of the reading queue;
- makes `readq-next` move on.

You can also add the tag by hand. `C-c r c` again unmarks it.

### 3. Export

`C-c r C` (`readq-export-cards`, or `C` in the dashboard) turns **all ready extracts** into cards.

- **After export**, the extracts are tagged `:exported:` (`readq-card-exported-tag`) and leave the reading queue, since the card has taken over. To keep them in the queue, set `readq-dismiss-after-export` to nil.
- **No duplicates:** an extract is never exported twice unless you mark it ready again.

readq asks which program to use each time, unless you choose one:

```elisp
(setq readq-flashcard-backend 'anki)        ; or 'org-drill
```

#### org-drill

Cards are added to an Org file next to the book's extracts, e.g. `Gray's Anatomy-cards.org`, in the format org-drill expects:

- Question/answer cards get an *Answer* subheading.
- Cloze cards use org-drill's `[hidden||hint]` syntax. Cards with several clozes use the `hide1cloze` card type.
- In cloze cards, other square brackets become parentheses, so org-drill doesn't hide them.

To drill, open the cards file and run `M-x org-drill`. To drill all the books in a folder at once, set `org-drill-scope` to `directory`. To collect every card in one file, set `readq-drill-file`.

#### Anki

- **Directly (recommended).** Install the [AnkiConnect](https://ankiweb.net/shared/info/2055492159) add-on: in Anki, choose *Tools → Add-ons → Get Add-ons* and enter code `2055492159`. Keep Anki open while exporting.
  - **Decks and tags:** cards go into the deck `readq::<book title>` (`readq-anki-deck`, `readq-anki-subdeck-per-book`), tagged `readq` (`readq-anki-tags`), plus `readq-<book>` and the extract's tags.
  - **Note types:** readq uses Anki's standard *Basic* and *Cloze* note types, with Org formatting turned into HTML. If your Anki uses other names, for example in another language, set `readq-anki-basic-model` and `readq-anki-cloze-model`.
  - **Duplicates:** cards Anki already has are skipped.
- **Through a file.** If Anki or AnkiConnect can't be reached, readq offers to write the cards to `~/readq-anki-import.txt` (`readq-anki-export-file`).
  - Import it with *File → Import* in Anki; the note type, deck and tags are already set in the file.
  - Delete the file after importing; the next export starts a new one.
  - To always use a file, set `readq-anki-method` to `file`.

## Audio and video

Lectures, podcasts, audiobooks and videos go in the same queue as your books, with priorities, schedules, tags, sections, extracts and flashcards. They play in **mpv**, which readq starts and listens to.

### Setup

- **mpv.** Install it from [mpv.io](https://mpv.io/installation/).
  - readq looks for it on your `PATH`. On Windows it also looks in `C:/Program Files/mpv/` and in Scoop's folder.
  - On Windows readq prefers **`mpv.com`**, which comes with mpv, because its output reaches Emacs and `mpv.exe`'s may not.
  - If mpv is somewhere else, set `readq-mpv-program`.
- **yt-dlp**, for online videos. mpv uses it to play YouTube and similar sites.
  - Install it from [its releases page](https://github.com/yt-dlp/yt-dlp/releases) into a folder on your `PATH`. On Windows, the mpv folder works.
  - Set `readq-mpv-ytdl-path` if mpv doesn't find it.
  - Keep yt-dlp up to date, because YouTube changes often.

### Adding

- **Files:** like books, with `C-c r a`, or a whole folder with `C-c r A`. readq asks mpv for each file's duration.
- **Online videos:** `C-c r u` (`readq-add-url`, or `U` in the dashboard). Paste or confirm the URL. readq asks mpv for the video's title and offers it, which takes a few seconds.
- **Picture quality:** to choose the quality of online videos, set `readq-mpv-ytdl-format`, e.g. `"bestvideo[height<=?720]+bestaudio/best"`, or `"bestaudio"` to only listen.

In the dashboard, the *Kind* column shows media as `audio`, `video` or `online`, and the position as e.g. `12:34 / 1:02:10`.

### Playing

`readq-next` (or `RET` in the dashboard) opens mpv **where you stopped**. Pause, seek and change speed in mpv as usual.

When you're done, **close mpv** (`q`, or close its window). readq then saves your position, adds the listening time, and reschedules the item by its priority, like a book.

- **Played to the end**, the item is marked finished. To have it rescheduled instead, set `readq-media-finish-at-end` to nil.
- **`C-c r n` while mpv is playing** closes mpv, saves, and opens the next item.
- **`C-c r f`** closes and saves without opening anything.

mpv opens a window even for audio (`readq-mpv-args` is `("--force-window=yes")`), so you can always see and control it.

### Marking moments

Press **`Ctrl+b` in mpv** (`readq-mpv-mark-key`) at anything worth keeping. mpv shows "readq: marked 23:41".

When mpv closes, each mark becomes an **extract**, such as "Lecture 4 at 23:41", in the item's extracts file. Review it like any extract: write down what was said, shorten it, turn it into a flashcard.

- **Replaying a moment:** the extract's *Source* link (or `C-c r g`) plays the moment again. Playback starts `readq-mpv-mark-lead` (10) seconds before the mark, and your place in the recording doesn't move.
- **Marking from Emacs:** `C-c r m` (`readq-media-mark`) marks the current moment, accurate to within `readq-mpv-interval` (5) seconds.

### Chapters as sections

Many audiobooks, podcasts and lecture recordings have chapters stored in the file. Press `T` on one in the dashboard to choose chapters as **sections**, each with its own priority and schedule. A section plays from its start and stops at its end.

### Your own table of contents

When a recording has no chapters, or you want different ones, give it a text file with one timestamp per section:

```
00:02:03 Section 1
00:04:55 Section 2
```

Headings (`*` in Org style, `#` in Markdown style) group the timestamps under them into sub-sections:

```
* Section 1
00:01:04 Sub-section 1

00:03:24 Sub-section 2

* Section 2
00:11:04 Sub-section 1

00:33:24 Sub-section 2
```

**How sections end:**

- **A heading** starts at its first timestamp and runs until the next heading at its level. Here *Section 1* runs from 1:04 to 11:04, where *Section 2* starts.
- **A sub-section** ends at the next timestamp.
- **The last entry** ends with the recording.

**Choosing and naming:**

- In the section picker (`T`), sub-sections are indented under their headings, with their times, e.g. `Sub-section 2  3:24–11:04`.
- In the queue, a sub-section is named with its heading too, e.g. *Lecture › Section 1 › Sub-section 1*, so sub-sections with the same name can be told apart.

**Where readq finds the file.**

- **Next to the recording, automatically:** give it the same name with one of these extensions: `lecture.toc`, `lecture.chapters`, `lecture.chapters.txt`, `lecture.txt`, `lecture.org` or `lecture.md`, for `lecture.mp3`. readq uses the first of these that contains timestamps. The list is `readq-media-toc-names`. These files aren't added as books when you add the folder.
- **Anywhere else, or for an online video:** press `M` in the dashboard (or `C-c r M`, `readq-set-media-toc`) and choose the file.

**From a YouTube description.** Paste the chapter list into any buffer, select it, and press `C-c r M`. readq keeps the text itself, so no file is needed. Lines without a timestamp, such as "Chapters:" or "Thanks for watching!", are ignored.

**Formats it understands:**

- **Timestamps:** `h:mm:ss`, `mm:ss` or `m:ss`, optionally with fractions of a second (`00:01:04.5`).
- **Timestamp before the title:** `00:01:04 Title`, `0:00 - Intro`, `[1:04] Title`, `- 1:04 Title`, `3. 01:04 Title`.
- **Timestamp after the title:** `Title - 1:04`, `Title (1:04)`.
- **Headings:** a heading can carry its own timestamp (`* Section 1 00:01:04`). An untimed heading starts at the first timestamp under it.

**Precedence.** A table of contents you give comes before the chapters stored in the recording. `C-u C-c r M` forgets the file or text you chose. readq then goes back to a file next to the recording, or to the recording's own chapters. Sections already in the queue keep their times.

### How progress is tracked

readq gives mpv a small script, `~/.emacs.d/readq-mpv.lua`, which readq writes itself. The script reports three things back to Emacs: the position, every `readq-mpv-interval` seconds; the marks; and how playback ended.

- **Closing mpv normally** saves the exact final position.
- **If mpv crashes**, readq keeps the last reported position, at most a few seconds old.
- **If mpv's reports don't reach Emacs at all**, readq falls back on the position mpv saves when it quits. This is mostly a safeguard for `mpv.exe` on Windows, so prefer `mpv.com` there.
- **Stopping from Emacs:** `C-c r n` or `C-c r f` while playing stops mpv for you. On Windows that ends mpv immediately, so the position saved is the last reported one. Close mpv yourself for the exact spot.

## Org links

`org-store-link` (`C-c l`) in a queued book stores a `readq:` link to the exact place:

- a PDF page;
- an EPUB position;
- a spot in a Markdown, text or web page.

Paste it into any note with `C-c C-l`. Following the link opens the book there, without moving your reading position.

In Org books, `C-c l` still makes Org's own links. `readq-org-store-links` turns readq's links off. Every extract's *Source* line is a `readq:` link too, and for a marked moment it plays the recording there.

## Reading stats

`C-c r =` (`readq-stats`) shows what you've done over the last 30 days:

```
Reading, last 30 days

  Today        35m, 2 sessions
  Streak       4 days in a row (longest 7)
  Time         19h12m, on 26 of 30 days (+12% on the 30 days before)
  Average      38m a day
  Sessions     71 (+5% on the 30 days before)
  PDF pages    642
  Extracts     48 made (6 figures) (-10% on the 30 days before)
  Cards        31 exported
  Finished     "Guyton Physiology, Unit IV"

Minutes read

  Mon 10-05 █████████████▍ 29m
  Tue 10-06 ██████████████████▉ 41m
  ...

By book
                                           Time Sessions  Pages Extracts  Progress
  Guyton Physiology                       6h46m       11    132        9  42%
  ...

By tag
  #cardio          ██████████████████████████████ 6h46m
  ...
```

In the stats buffer, `w`, `m` and `y` switch to the last week, month or year, and `g` refreshes. A year shows a bar per month. `C-u 90 C-c r =` shows any number of days.

- **Time** includes reading and extract reviews. The percentages compare with the same number of days just before.
- **Streak** counts days with at least a minute of reading. Today counts once you've read; until then, the streak runs to yesterday.
- **PDF pages** are pages moved forward in PDF books. Other formats count time only.
- **By book** puts the time spent on a book's sections and extracts under the book.
- **Finished** lists books marked finished in the period. Books finished before this version have no date and appear only in the totals.

readq keeps a year of daily totals in the database. Older days, and days from before this version, are rebuilt from each item's session history.

## The dashboard

`M-x readq` or `C-c r l`. Without icons it looks like this:

```
 Pri Kind     Title                                    Tags             Progress           Position    Ext Due        Deadline           Time
  10 pdf      ▾ Gray's Anatomy                         #anatomy         ███░░░░░░░░░  26%  p 312/1200    2 today      07 Nov 30 p/d      2h02m
  10 extract    ▾ The first heart sound is caused by … #anatomy                            p 2               today
  10 extract        Closure of the AV valves           #anatomy                            p 2               in 3d
  15 section      Heart                                #anatomy         ██████░░░░░░  50%  p 214 (2…       tomorrow                      40m
  20 audio    ▸ Cardiology lecture 4                   #cardio          ██░░░░░░░░░░  20%  12:34 / 1:02:10   2d late                       0m
  40 epub     ▸ Being Mortal                           #leisure         ██░░░░░░░░░░  16%  ch 3/12           tomorrow                      0m
```

Rows are in the order you should read them. The mode line sums up the queue, e.g. `3 due (1 extracts), 4 in queue — focus: #cardio — today 52/90 min`.

### Books, sections and extracts

Everything is listed under what it came from:

- a book's **sections** and **extracts** under the book;
- **sub-extracts** under the extract they were made from.

A `▸` before a title means there is more under it; press **`TAB`** on the line, or click the `▸`, to show it (`▾`) and again to hide it. `TAB` on an item with nothing under it hides its parent's list. **`S-TAB`** shows everything, or hides everything if something is shown.

- **What's open:** a book with something due under it opens by itself, so you see today's extracts. Once you open or close one with `TAB`, it stays that way until you close the dashboard.
- **Order:** books come in the order of their most urgent item, and so does everything under them. A book whose extract is due today comes before a book due tomorrow.
- **Parents are always listed.** A finished book is hidden, but if one of its extracts is still in the queue, the book is listed too, dimmed, with the extract under it.
- **Sorting** by a column (click its header, or `S`) sorts items within each level, so they stay under their parents.
- **`E`** hides extracts altogether, and shows them again.

### Icons

With the [all-the-icons](https://github.com/domtronn/all-the-icons.el) package, the *Kind* column becomes an icon, and the *Due* column gets one too:

| Kind | Icon | | Due | Icon |
|------|------|-|-----|------|
| PDF, Org, Markdown, text | the file type's own icon | | late | red exclamation mark |
| PDF read in SumatraPDF | orange PDF | | today | orange clock |
| EPUB | book | | tomorrow | calendar |
| web page | globe | | paused | pause sign |
| audio | headphones | | finished, exported | green check |
| video | film | | ready for a flashcard | graduation cap |
| online video | YouTube logo | | missing file | red question mark |
| section | bookmark | | | |
| extract | quotation mark | | | |
| figure extract | picture | | | |

Hover over an icon to see the kind in words. To set it up:

1. Install all-the-icons, e.g. `M-x package-install RET all-the-icons`, or `(use-package all-the-icons :ensure t)`.
2. Run `M-x all-the-icons-install-fonts`. On Windows this only downloads the fonts: open each `.ttf` file it saved and click *Install*, then restart Emacs.

readq uses icons whenever all-the-icons is installed and Emacs runs in a window; in a terminal it shows words. To always show words, set `readq-dashboard-icons` to nil.

### Columns

| Column | Meaning |
|--------|---------|
| *Pri* | priority, 0 most important |
| *Kind* | an icon, or `pdf`, `sumatra`, `epub`, `org`, `md`, `txt`, `html`, `audio`, `video`, `online`, `section`, `extract` or `figure` |
| *Title* | the book, `Book › Chapter` for a section, or the start of an extract |
| *Tags* | the item's tags, including inherited ones; shown once something has tags |
| *Progress* | how far through you are |
| *Position* | where you are: page, chapter, section, percentage or time |
| *Ext* | number of active extracts from the book |
| *Due* | `today`, `2d late`, `tomorrow`, `in 5d`, `paused`, `finished`… |
| *Deadline* | the [deadline](#deadlines) and the pages, minutes or percent a day it needs; `-20 p` when behind. Shown once something has a deadline. |
| *Time* | total reading or listening time |

Two more columns are available: *Ivl* (`interval`, the current interval in days) and *Last read* (`last-read`, the date of the last session). Choose the columns and their order with `readq-dashboard-columns`, e.g.:

```elisp
(setq readq-dashboard-columns
      '(priority kind title tags progress due deadline interval last-read))
```

Finished items are hidden until you press `F`. To sort by a column, click its header or press `S` on it.

| Key | Action |
|-----|--------|
| `RET` `o` | open the item at your saved position |
| `N` | read the next suggested item |
| `a` / `A` | add a book / add a folder |
| `U` | add an online video (URL) |
| `=` | set priority |
| `+` / `-` | more / less important, by `readq-priority-step` |
| `r` | reschedule: read again in N days |
| `z` | postpone: interval × `readq-postpone-factor`; `C-u z` asks for days |
| `f` | mark finished / not finished |
| `x` | pause / resume. Paused items are never suggested. |
| `t` | edit the title |
| `R` | relocate a book whose file moved |
| `D` | remove a book from the queue (the file is not touched), or delete an extract with its highlight and note |
| `#` | set tags |
| `/` | focus on tags (empty answer to clear) |
| `T` | choose sections from the table of contents, or chapters of a recording |
| `M` | give a recording a table of contents with timestamps |
| `e` | open the book's extracts file |
| `s` | show an extract's source in its book |
| `i` | import highlights from the PDF |
| `v` | read this PDF in Emacs or in SumatraPDF |
| `c` | mark an extract ready for a flashcard, or unmark it |
| `C` | export all ready extracts as flashcards |
| `TAB` | show / hide what is under the item (click the `▸` too) |
| `S-TAB` | show / hide everything under every item |
| `E` | show / hide extracts |
| `F` | show / hide finished items |
| `L` | the [daily budget](#daily-budget), the load of the next days, and [deadlines](#deadlines) |
| `!` | set a deadline; `C-u !` for a tag |
| `g` | refresh |

## Key reference

### Prefix map (`C-c r …`)

| Key | Command | What it does |
|-----|---------|--------------|
| `l` | `readq` | the dashboard |
| `n` | `readq-next` | finish the session and open the next item (`C-u`: only from some tags) |
| `f` | `readq-finish-session` | finish the session, open nothing |
| `o` | `readq-open` | open an item you choose |
| `s` | `readq-suggest` | show what is due, in order |
| `a` | `readq-add-book` | add a file |
| `A` | `readq-add-directory` | add every book in a folder |
| `u` | `readq-add-url` | add an online video |
| `p` | `readq-set-priority` | set priority |
| `+` / `-` | `readq-priority-up` / `-down` | change priority by `readq-priority-step` |
| `r` | `readq-reschedule` | read again in N days |
| `z` | `readq-postpone` | postpone |
| `F` | `readq-toggle-finished` | mark finished / not finished |
| `x` | `readq-toggle-pause` | pause / resume |
| `#` | `readq-set-tags` | set tags |
| `/` | `readq-focus` | focus on tags |
| `L` | `readq-workload` | today's budget, the load of the next days, and deadlines |
| `!` | `readq-set-deadline` | finish an item by a date (`C-u`: a tag, `readq-set-tag-deadline`) |
| `T` | `readq-add-sections` | choose sections |
| `M` | `readq-set-media-toc` | table of contents for a recording (`C-u`: forget it) |
| `e` | `readq-extract` | extract the selection (`C-u`: ask priority; `C-u C-u`: one extract per passage) |
| `P` | `readq-extract-figure` | make the figure here an extract (`C-u`: ask priority); see [Figures](#figures) |
| `y` | `readq-extract-figure-from-clipboard` | make the image on the clipboard a figure extract (SumatraPDF) |
| `?` | `readq-doctor` | check your setup; see [Checking your setup](#checking-your-setup) |
| `S` | `readq-search` | search the text of your extracts; see [Searching extracts](#searching-extracts) |
| `j` | `readq-find-extract` | pick an extract from a list and show it |
| `=` | `readq-stats` | reading stats for the last 30 days (`w`/`m`/`y` week, month, year); see [Reading stats](#reading-stats) |
| `X` | `readq-stale-extracts` | go through stale extracts: card, merge, dismiss or keep each; see [Stale extracts](#stale-extracts) |
| `B` | `readq-restore-backup` | restore the database from a daily backup; see [Backups](#backups) |
| `D` | `readq-delete-extract` | delete an extract with its highlight and note |
| `d` | `readq-dismiss` | take an extract out of the queue, keeping its note |
| `g` | `readq-goto-source` | show an extract's source |
| `E` | `readq-visit-extracts` | open a book's extracts file |
| `i` | `readq-import-highlights` | import a PDF's highlights |
| `I` | `readq-import-all-highlights` | import highlights from all PDFs |
| `v` | `readq-set-viewer` | read a PDF in Emacs or in SumatraPDF |
| `m` | `readq-media-mark` | mark the current moment of the recording playing |
| `k` | `readq-cloze` | make the selection a cloze (`C-u`: with a hint) |
| `c` | `readq-mark-ready` | mark an extract ready for a flashcard |
| `C` | `readq-export-cards` | export ready extracts as flashcards |

Commands that act on an item pick it in this order:

1. the item at point in the dashboard;
2. the extract at point in an Org file;
3. the book in the current buffer.

Otherwise they ask you to choose one.

Not in the prefix map: `readq-add-section` (a PDF section by page numbers, `M-x` only), `readq-merge-extract` (`M-x`, or `m` in `C-c r X`), `readq-spread-overflow` (`S` in the forecast), and `readq-edit-title`, `readq-relocate` and `readq-remove-book`, which are `t`, `R` and `D` in the dashboard.

### In mpv

| Key | Action |
|-----|--------|
| `Ctrl+b` | mark this moment as an extract (`readq-mpv-mark-key`) |
| `Ctrl+f` | save the frame on screen as a figure extract (`readq-mpv-figure-key`) |
| `q` | quit; readq saves your position |

### Mode line

| Shows | Meaning |
|-------|---------|
| `RQ:26%` | reading a queued book, 26% through |
| `RQ:§45%` | reading a section, 45% through it |
| `RQ:extract` | reviewing an extract |

## How scheduling works

- **Intervals.** Every item has an **interval** in days and a **due date**. A new book starts with an interval of `readq-initial-interval` (1) and is due today. A new extract starts with `readq-extract-initial-interval` (1) and is due tomorrow.
- **Growth by priority.** When a session counts as a review, the interval is multiplied by a factor that depends on priority. The factor runs linearly from `readq-min-afactor` (1.2) at priority 0 to `readq-max-afactor` (2.5) at priority 100. The interval stays between `readq-min-interval` and `readq-max-interval` (1–60 days).

  Starting from a 1-day interval, items come back this many days apart:

  | Priority | Gaps between sessions (days) |
  |---------:|------------------------------|
  | 0 | 1, 1, 2, 2, 2, 3, 4 … |
  | 50 | 2, 3, 6, 12, 22, 40, 60 |
  | 100 | 2, 6, 16, 39, 60 |

- **What `readq-next` picks:**
  1. items due today or overdue, by priority, then by how overdue they are;
  2. if none are due, after asking, the item due soonest.

  Paused, finished and missing items are skipped, and so are items outside the focus if one is set. Once the [daily budget](#daily-budget) is used up, readq asks before opening more.
- **Randomness.** Set `readq-randomization` (e.g. 0.2) to shift priorities a little at random each time `readq-next` picks, so lower-priority items get a turn now and then. At 1, priorities move by up to ±50 points.
- **Deadlines.** An item with a [deadline](#deadlines) gets a shorter interval when it needs one to be finished in time.
- **Your own schedule.** `r` (reschedule) and `z` (postpone) override the schedule whenever you like.

## Customization

`M-x customize-group RET readq` shows every option. They are grouped into `readq` (general), `readq-workload`, `readq-deadlines`, `readq-extracts`, `readq-flashcards` and `readq-media`.

### General

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-db-file` | `~/.emacs.d/readq.eld` | where your queue is stored. It is a plain Lisp data file, so you can sync it. |
| `readq-file-extensions` | pdf, epub, org, md, markdown, txt, html, htm, and audio/video types | which files are books, and how each is read |
| `readq-default-priority` | 50 | priority offered when adding |
| `readq-priority-step` | 5 | change made by `+` / `-` |
| `readq-ask-tags` | t | ask for tags when adding |
| `readq-restore-position` | t | jump to your saved position when a book opens |
| `readq-kill-buffer-after-session` | nil | kill the previous book's buffer on `readq-next` |
| `readq-finished-threshold` | 0.99 | progress at which a book counts as read to the end |
| `readq-min-session-seconds` | 60 | reading time a session needs to count, if you didn't move forward |
| `readq-idle-threshold` | 300 | seconds idle after which reading time stops counting |
| `readq-tick-interval` | 15 | seconds between automatic position saves, outside pdf-tools |

### Scheduling

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-initial-interval` | 1 | first interval of a new book, in days |
| `readq-min-afactor` / `readq-max-afactor` | 1.2 / 2.5 | interval growth at priority 0 / 100 |
| `readq-min-interval` / `readq-max-interval` | 1 / 60 | shortest / longest interval, in days |
| `readq-postpone-factor` | 1.5 | interval multiplier for `z` |
| `readq-randomization` | 0.0 | randomness when `readq-next` picks |
| `readq-queue-extracts` | t | suggest extracts along with books |

### Daily budget

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-daily-minutes` | 90 | minutes of reading planned per day; nil for no limit |
| `readq-daily-items` | nil | items planned per day; nil for no limit |
| `readq-workload-protected-priority` | 10 | items at or below this priority are always kept for today |
| `readq-workload-overflow` | `spread` | `spread` moves what doesn't fit to the next days; `hold` leaves due dates alone |
| `readq-workload-stop` | `ask` | ask before reading past the budget; nil to keep going |
| `readq-default-book-minutes` | 15 | estimate for a book, section or recording never read yet |
| `readq-default-extract-minutes` | 2 | estimate for an extract never reviewed yet |
| `readq-workload-estimate-sessions` | 5 | recent sessions an item's estimate is based on |
| `readq-workload-spread-days` | 30 | how far ahead items over the budget may be moved |
| `readq-stats-days` | 30 | days `readq-stats` looks back over |
| `readq-stats-bar-width` | 30 | width of the longest bar in `readq-stats` |
| `readq-workload-forecast-days` | 14 | days shown by `readq-workload` |

### Deadlines

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-deadline-overrides-budget` | t | items with a deadline are kept over the daily budget and never spread |
| `readq-deadline-pace-sessions` | 5 | recent sessions an item's pace is based on |
| `readq-deadline-width` | 18 | width of the dashboard's *Deadline* column |

### Dashboard

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-title-width` | 40 | width of the *Title* column |
| `readq-tags-width` | 16 | width of the *Tags* column |
| `readq-progress-bar-width` | 12 | width of the progress bar |
| `readq-progress-bar-chars` | `█` / `░` | characters of the progress bar: (done . remaining) |
| `readq-dashboard-columns` | priority, kind, title, tags, progress, position, extracts, due, deadline, time | the dashboard's columns, in order; also `interval` and `last-read` |
| `readq-dashboard-icons` | t | icons from all-the-icons in the *Kind* and *Due* columns, when installed |

### Extracts and highlights

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-extracts-directory` | nil (next to each book) | a folder for all extracts files |
| `readq-extracts-fallback-directory` | `~/.emacs.d/readq-extracts/` | used when a book's folder isn't writable |
| `readq-stale-reviews` | 5 | reviews after which an extract nobody acted on is stale; nil to ignore |
| `readq-stale-days` | 60 | days after which an extract reviewed twice is stale; nil to ignore |
| `readq-stale-priority-step` | 20 | what "lower" adds to a stale extract's priority |
| `readq-search-max-command-length` | 24000 | longest list of extracts files `readq-search` passes to grep; beyond it, it searches their folders |
| `readq-extract-initial-interval` | 1 | days until a new extract is first due |
| `readq-extract-priority-offset` | 0 | added to the book's priority for new extracts; negative makes them more important |
| `readq-extract-multiple` | `combine` | several selected passages make one extract; `separate` for one each |
| `readq-extract-separator` | blank line | text between the passages of a combined extract |
| `readq-extract-title-length` | 60 | characters of the passage used as the extract's heading |
| `readq-extract-add-highlight` | t | highlight the passage in the PDF when extracting in pdf-tools |
| `readq-extract-highlight-color` | `"#ffff00"` | color of that highlight |
| `readq-show-extracts-in-epub` | t | highlight extracted passages in EPUB, text and web books |
| `readq-narrow-to-extract` | t | narrow the Org buffer to the extract under review |
| `readq-auto-import-highlights` | t | import highlights when a PDF has changed |
| `readq-import-annotation-types` | highlight, underline, squiggly, strike-out | PDF annotations that become extracts |
| `readq-highlight-color-rules` | nil | priorities by highlight color; see [Highlight colors](#highlight-colors) |
| `readq-highlight-selection-style` | `word` | how text under a highlight is read: `glyph`, `word` or `line` |
| `readq-org-store-links` | t | `org-store-link` in a book stores a `readq:` link |
| `readq-default-pdf-viewer` | `emacs` | `sumatra` to read every PDF in SumatraPDF |
| `readq-sumatra-program` | nil (find it) | path to `SumatraPDF.exe` |
| `readq-sumatra-settings-file` | nil (find it) | SumatraPDF's `SumatraPDF-settings.txt`, where it remembers your page |
| `readq-sumatra-poll-interval` | 5 | seconds between looks at that file while SumatraPDF is open |
| `readq-external-max-session-minutes` | 120 | longest reading time counted for a session in SumatraPDF |
| `readq-figures-directory` | `~/.emacs.d/readq-figures/` | the one folder for all figure images |
| `readq-figure-dpi` | 200 | resolution of figures cropped from PDFs |
| `readq-ask-figure-caption` | t | ask for a caption when taking a figure |
| `readq-figure-display-width` | 600 | width in pixels of figures shown while reviewing; nil to leave it to Org |

### Flashcards

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-flashcard-backend` | `ask` | `anki` or `org-drill` to stop asking |
| `readq-card-ready-tag` | `"ready"` | Org tag of extracts ready to become cards |
| `readq-card-exported-tag` | `"exported"` | Org tag of exported extracts |
| `readq-dismiss-after-export` | t | exported extracts leave the reading queue |
| `readq-drill-file` | nil (one per book) | one Org file for all org-drill cards |
| `readq-anki-method` | `ankiconnect` | `file` to always write an import file |
| `readq-anki-connect-url` | `http://127.0.0.1:8765` | address of AnkiConnect |
| `readq-anki-deck` | `"readq"` | Anki deck |
| `readq-anki-subdeck-per-book` | t | a subdeck per book: `readq::Gray's Anatomy` |
| `readq-anki-tags` | `("readq")` | tags given to every note, in addition to the book's and extract's |
| `readq-anki-basic-model` | `("Basic" "Front" "Back")` | note type and fields of question/answer cards |
| `readq-anki-cloze-model` | `("Cloze" "Text" "Back Extra")` | note type and fields of cloze cards |
| `readq-anki-export-file` | `~/readq-anki-import.txt` | the import file |
| `readq-anki-media-directory` | nil | Anki's `collection.media` folder, where figures are copied when exporting by file |

### Audio and video

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-mpv-program` | nil (find it) | path to mpv (`mpv.com` on Windows) |
| `readq-mpv-args` | `("--force-window=yes")` | extra mpv arguments; the window lets you control audio too |
| `readq-mpv-mark-key` | `"Ctrl+b"` | key in mpv that marks a moment |
| `readq-mpv-figure-key` | `"Ctrl+f"` | key in mpv that saves the frame as a figure |
| `readq-mpv-mark-lead` | 10 | seconds before a mark that playing it back starts |
| `readq-mpv-interval` | 5 | seconds between position reports from mpv |
| `readq-media-finish-at-end` | t | played to the end means finished |
| `readq-media-toc-names` | `("%s.toc" "%s.chapters" "%s.chapters.txt" "%s.txt" "%s.org" "%s.md")` | files next to a recording that can be its table of contents; `%s` is its name without extension |
| `readq-mpv-ytdl-format` | nil | quality of online videos, e.g. `"bestvideo[height<=?720]+bestaudio/best"` or `"bestaudio"` |
| `readq-mpv-ytdl-path` | nil | path to yt-dlp, if mpv doesn't find it |

### Hooks

- `readq-mode-hook`, `readq-book-mode-hook`, `readq-review-mode-hook`: run when those modes turn on or off.
- `readq-before-suggest-hook`: run before readq picks or lists what to read; this is where highlights are imported.

### Example configuration

```elisp
(use-package readq
  :load-path "~/path/to/readq"
  :config
  (readq-mode 1)
  (setq readq-default-priority 40
        readq-randomization 0.1
        readq-kill-buffer-after-session t
        readq-highlight-color-rules '(("red" . 5) ("green" . skip))
        readq-flashcard-backend 'anki
        readq-mpv-ytdl-format "bestvideo[height<=?720]+bestaudio/best")
  :bind-keymap ("C-c r" . readq-command-map))
```

## Backups

All your scheduling lives in one file, `readq-db-file`. readq protects it in two ways:

- **Safe saves.** readq writes the new database to `readq.eld.tmp`, reads it back to check it, and only then puts it in place of the old one. A crash, a full disk or a sync program in the middle of a save leaves the old database as it was.
- **Daily backups.** On the first save of each day, readq copies the database as it was to `readq-backups/readq-YYYY-MM-DD.eld`, next to the database. It keeps the last `readq-backup-count` (14) days and deletes older ones.

To go back to a backup, run `M-x readq-restore-backup` (`C-c r B`) and pick a day; each is shown with its number of books and extracts. The database you had is kept as `readq-before-restore-<date>_<time>.eld` in the same folder and is offered by `readq-restore-backup` too, so a restore can be undone.

If the database can't be read when readq starts, readq stops with an error pointing to `readq-restore-backup` rather than starting with an empty queue. If the database is missing but backups exist, readq warns you; restore a backup before adding anything.

Backups cover the database only. Your extracts (Org files) and figures are ordinary files: include them in whatever backs up your documents.

| Option | Default | Meaning |
|--------|---------|---------|
| `readq-backup-count` | 14 | days of backups to keep; 0 or nil turns them off |
| `readq-backup-directory` | nil | where backups go; nil means `readq-backups/` next to the database |

## Files readq creates

| File | What |
|------|------|
| `~/.emacs.d/readq.eld` (`readq-db-file`) | your queue: items, positions, schedules, tags, focus, deadlines, and minutes read per day for the last year. readq keeps daily copies of it, see [Backups](#backups). |
| `readq-backups/` next to the database (`readq-backup-directory`) | daily backups of the database |
| `<book>.org` next to each book | the book's extracts (or `<book>-extracts.org`; see [Where extracts are stored](#where-extracts-are-stored)) |
| `~/.emacs.d/readq-figures/` (`readq-figures-directory`) | the images of all figure extracts. **Back this up too.** |
| `<book>-cards.org` | org-drill cards, unless `readq-drill-file` is set |
| `~/.emacs.d/readq-extracts/` | extracts of books in read-only folders |
| `~/readq-anki-import.txt` | Anki import file, only when exporting by file |
| `~/.emacs.d/readq-mpv.lua` | the script readq gives mpv; rewritten when needed |

readq writes into PDFs only to add the highlights of extracts made in pdf-tools, and to delete them when you delete an extract. It never writes into your books otherwise, and never into Org files it didn't create.

## Windows notes

- **SumatraPDF:** readq looks for `SumatraPDF` on your `PATH`, then in `%LOCALAPPDATA%\SumatraPDF\` (the default install), `C:/Program Files/SumatraPDF/` and Scoop's folder. If it is somewhere else, for example the portable version:
  ```elisp
  (setq readq-sumatra-program "C:/Tools/SumatraPDF/SumatraPDF.exe")
  ```
- **SumatraPDF and annotations:** only highlights saved inside the PDF can be imported. When SumatraPDF asks about unsaved annotations, save them to the existing PDF.
- **pdf-tools:** works on Windows, but its `epdfinfo` program has to be built, usually with MSYS2 (see pdf-tools' README). readq reopens the PDF on every import, because `epdfinfo` would otherwise keep using its cached copy and miss highlights SumatraPDF saved since. It closes the file afterwards so SumatraPDF can still save it.
- **The same PDF open in both:** if you highlight in pdf-tools while the PDF is open in SumatraPDF, Windows may refuse to save it. readq then keeps the extract and tells you the highlight wasn't saved.
- **mpv:** use `mpv.com` (readq prefers it when it finds mpv itself). If mpv is installed with Scoop or in `C:/Program Files/mpv/`, readq finds it.
- **Figures from the clipboard:** Emacs on Windows can't read images from the clipboard itself, so readq asks PowerShell (which comes with Windows) to save it. This takes a second or two.
- **File names** are compared case-insensitively, so `C:/Books/Gray.pdf` and `c:/books/gray.pdf` are the same book.
- **Synced folders** (OneDrive, Dropbox): extracts files are synced along with their books. Books in write-protected folders such as `C:/Program Files` use the fallback folder.

## Troubleshooting

Start with `M-x readq-doctor` (`C-c r ?`): it finds most setup problems and says how to fix them.

**readq doesn't restore my place / doesn't track a book.**
- Make sure `readq-mode` is on.
- Open the file it was added from. If the file has moved, use `R` (relocate) in the dashboard.
- If nov.el's or pdf-tools' own save-place features are on, readq's position takes over when you open the book through readq.

**SumatraPDF doesn't save my page.**
- Close the document in SumatraPDF; it writes your page only then.
- Check that `readq-sumatra-settings-file` (or the file readq finds) is the one SumatraPDF writes: its *Settings → Advanced options* opens it.
- Keep *Remember opened files* on in SumatraPDF's options.

**Highlights from SumatraPDF aren't imported.**
- Save the annotations into the PDF in SumatraPDF.
- Check that pdf-tools works (`M-x pdf-tools-install`).
- Run `C-c r i` on the book.
- Highlights of a type not in `readq-import-annotation-types`, or with a color set to `skip` in `readq-highlight-color-rules`, aren't imported.

**A highlight imports a few words too few or too many.** Try another `readq-highlight-selection-style` (`glyph`, `word` or `line`).

**mpv doesn't start.**
- Check that `mpv` runs in a terminal.
- If it isn't on your `PATH`, set `readq-mpv-program`.
- For online videos, mpv also needs yt-dlp. Update yt-dlp first if YouTube stops working.

**My position in a recording is a few seconds off.** It was saved from the last report rather than from mpv closing normally. Close mpv with `q` rather than from Emacs. On Windows, use `mpv.com`.

**Anki export fails.** Keep Anki open, with AnkiConnect installed. If your note types have other names, set `readq-anki-basic-model` and `readq-anki-cloze-model`. You can always export by file with `readq-anki-method` set to `file`.

**A figure extract shows a link, not the image.** Your Emacs can't show that kind of image, or inline images are off: press `C-c C-x C-v` in the Org buffer. In a terminal Emacs, open the link with `C-c C-o`.

**`C-c r P` says there is no image.** In nov.el and eww, images show only in a graphical Emacs, and eww may not have loaded them yet (`shr-inhibit-images`). In a PDF, select the area with `M-drag` first.

**I deleted an extract by mistake.** The text is in the kill ring: open the extracts file and press `C-y`. The queue item and the highlight can't be restored that way. Make a new extract from the passage if you need them.

## Limitations

- Highlight import and SumatraPDF are for PDFs only.
- readq learns your page in SumatraPDF when you close the document there, not while you read.
- With pdf-tools, readq saves your position on every page change. In other modes it saves every `readq-tick-interval` seconds, when you kill the buffer, and when you quit Emacs.
- Progress of text and HTML books is the position in the file, or in the page as eww shows it.
- The Windows-specific behaviour (`mpv.com`, case-insensitive file names, SumatraPDF, figures from the clipboard) is written for Windows but tested only on Linux, SumatraPDF with a stand-in that writes its settings file.
- A figure is a picture: its text can't be searched, and a figure in a PDF has no highlight.

## Running the tests

```sh
emacs -Q --batch -L . -L test -l test/readq-test.el -l test/readq-extract-test.el \
      -l test/readq-cards-test.el -l test/readq-formats-test.el \
      -l test/readq-multi-region-test.el -l test/readq-sections-test.el \
      -l test/readq-tags-test.el -l test/readq-media-test.el \
      -l test/readq-media-toc-test.el \
      -l test/readq-highlight-test.el -l test/readq-delete-test.el \
      -l test/readq-workload-test.el -l test/readq-deadline-test.el \
      -l test/readq-figure-test.el -l test/readq-sumatra-test.el \
      -l test/readq-dashboard-test.el -l test/readq-backup-test.el \
      -l test/readq-search-test.el -l test/readq-stale-test.el \
      -l test/readq-stats-test.el \
      -f ert-run-tests-batch-and-exit
```

Tests whose dependencies are missing are skipped:

| Tests | Need |
|-------|------|
| EPUB | `-L /path/to/nov -L /path/to/esxml -L /path/to/dash` |
| PDF highlights | `-L /path/to/pdf-tools/lisp -L /path/to/tablist`, and the environment variable `READQ_EPDFINFO` set to the `epdfinfo` program |
| Media | mpv on the `PATH`. Playback runs fast, with no sound or picture. The URL test also needs `python3` for a local web server. |
| Figures from PDFs | pdf-tools, as for PDF highlights |
| multi-region | the folder of `multi-region.el` (0.2 or later) on the load path |
| org-drill | org-drill and its dependencies (`persist`, `compat`) on the load path |
| AnkiConnect | `python3`, which runs `test/fake-ankiconnect.py`, a stand-in for the add-on |
| Dashboard icons | all-the-icons on the load path |
| SumatraPDF | a POSIX `sh`, which runs `test/fake-sumatra.sh`, a stand-in that writes SumatraPDF's settings file |

`test/fixtures/` holds the test files:

- PDFs with highlights saved the standard way, as SumatraPDF and Okular save them;
- a PDF with an outline;
- a short lecture recording with chapters, in two formats.

## License

GPL-3.0-or-later. See the header of `readq.el`.
