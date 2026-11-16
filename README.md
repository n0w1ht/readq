# readq

**Incremental reading for Emacs.** readq keeps a queue of everything you are reading through (textbooks, papers, lecture recordings, web pages) and tells you what to read next. It remembers where you stopped in each one. The passages you keep become short notes that come back for review until you turn them into flashcards.

It works the way SuperMemo's incremental reading does, with the files and the editor you already use.

## How it feels

1. Press `C-c r n`. readq opens the most important thing due today, at the page where you stopped.
2. Read for a while. When a passage is worth keeping, select it and press `C-c r e`. It becomes an **extract**, a note of its own.
3. Press `C-c r n` again. readq saves your place and opens the next item: another book, a chapter, or an extract to review.
4. Each time an extract comes back, trim it a little. When it holds one clear fact, press `C-c r c` and it becomes an Anki or org-srs card.

Each item has a priority from 0 to 100. Important books come back every day, less important ones once a week, and extracts after longer and longer gaps. A daily budget (90 minutes by default) keeps the queue from burying you.

## What it reads

| | |
|---|---|
| PDF | pdf-tools, pdf-canvas, doc-view, or SumatraPDF on Windows |
| EPUB | nov.el |
| Org, Markdown, text, HTML | any mode, and eww |
| Comics | CBZ, CBR, CB7 |
| Audio, video, YouTube | mpv |

It also does chapters as separate items, deadlines and a plan counted back from an exam, plain highlights, figures as extracts, highlights imported from other PDF viewers, card drafts from a local model, reading aloud with Kokoro, and reading stats.

Extracts are plain Org files named the [Denote](https://protesilaos.com/emacs/denote) way, in one folder (`~/notes/`). Nothing is locked in.

## Install

readq needs Emacs 27.1 or later and two small packages: [card-export](https://github.com/n0w1ht/card-export) and [readq-comic](https://github.com/n0w1ht/readq-comic). Clone all three, then:

```elisp
(use-package readq
  :load-path ("~/src/card-export" "~/src/readq-comic" "~/src/readq")
  :config (readq-mode 1)
  :bind-keymap ("C-c r" . readq-command-map))
```

Then run `C-c r ?`. It checks the programs readq can use (pdf-tools, nov.el, mpv, Anki...) and says what to install for what you read.

## Start

- `C-c r a` add a book, with a priority (0 is most important)
- `C-c r n` read next
- `C-c r e` extract the selected passage
- `C-c r l` see the whole queue

## The manual

The full guide is in Emacs: **`C-h R readq`**, or `C-c r h`. Press `i` there to look up any command or option. The source is [doc/readq.org](doc/readq.org), which GitHub also shows.

What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

## Contributing

`make check` compiles every file (a warning is an error) and runs the tests. The same checks run on GitHub on Emacs 30.1 and the development Emacs. After editing the manual, `make info` rebuilds it (needs `makeinfo`).

## License

GPL-3.0-or-later. See the header of `readq.el`.
