# readq — notes for Claude

readq is an incremental-reading queue for Emacs (SuperMemo-style): books, PDFs,
EPUBs, comics, media and web pages in one queue, read in short sessions;
passages become **extracts** (Denote notes) that come back for review until they
become flashcards (org-srs or Anki). Elisp, GPL-3.0-or-later, version in
`readq-version` (readq.el). Repo: github.com/n0w1ht/readq, branch `main`.

The user reads with it every day. **Their real data is live:** `~/notes/readq.eld`
(the queue), `~/notes/readq-backups/`, `~/notes/*.org` extracts, silo folders
such as `~/Pathology/notes/`. Never load readq against those from a batch Emacs,
and never edit them by hand unless asked. Tests use temp directories (see below).

## Commands

```sh
make compile     # byte-compile all readq*.el; any warning is an error
make test        # ERT, all test/*-test.el; tests missing a dependency skip
make check       # both (~40 s)
make info        # rebuild doc/readq.texi + readq.info from doc/readq.org (needs makeinfo)
```

- The user's Emacs byte-compiles `readq*.el` into `.elc` files here at
  startup (`my-init-reading.el`). `make compile` deletes them, and the
  Makefile sets `load-prefer-newer`, so an edited `.el` always wins over an
  old `.elc`. If you load readq in some other batch Emacs, set
  `load-prefer-newer` yourself.
- Dependencies are found as siblings in `../` (card-export, readq-comic,
  multi-region, pdf-canvas, kokoro.el…). Packages installed from ELPA live in
  `~/.emacs.d/elpa/` and are *not* found unless passed via `DEPS`, so locally
  ~24 tests skip. To run more of them:
  ```sh
  E=~/.emacs.d/elpa; make test DEPS="$(ls -d $E/nov-2* $E/denote-4* $E/consult-2* \
    $E/dash-2* $E/esxml-* $E/compat-31.1.0.0 $E/org-srs-* $E/fsrs-* $E/pdf-tools-* \
    $E/tablist-* $E/all-the-icons-2* | tr '\n' ' ')"
  ```
- A single file: `emacs -Q --batch -L . -L ../card-export -L ../readq-comic -L test -l test/readq-foo-test.el -f ert-run-tests-batch-and-exit`.
- Local Emacs is 32.0.50 (development). CI (`.github/workflows/ci.yml`) runs
  Emacs 30.1 and snapshot; `Package-Requires` says 27.1. Don't use newer APIs
  without a fallback.
- Before calling a change done: `make check` is clean (no warnings, no failures),
  and `make info` still builds if the manual changed.

## Layout

One package split into modules that form a **linear require chain**. Each file
requires the one below it; `readq.el` requires the top ones:

```
readq-core        data model, DB load/save/backup/upgrade, scheduling, hooks
readq-viewer      viewer table (readq-define-viewer): pdf-tools, doc-view, nov, comics
readq-book        sessions, readq-next/open/suggest, readq-book-mode
readq-sumatra     external SumatraPDF viewer (Windows)
readq-sections    chapters as items, TOC, tags, subsets
readq-media       mpv (audio/video/YouTube); writes ~/.emacs.d/readq-mpv.lua
readq-plan        budget, deadlines, workload, stats
readq-dashboard   the tabulated-list dashboard (C-c r l)
readq-extract     creating extracts/figures, Denote notes, silos
readq-extract-tools  editing, search, merge, import highlights, stale, delete
readq-cards       ready/cloze/export to org-srs or Anki (via card-export)
readq-highlight, -draft (gptel card drafts), -relearn (failed cards), -exam,
readq-kokoro (TTS), -pdf-canvas (viewer example)
readq.el          entry point: readq-mode, readq-command-map, readq-doctor, manual
```

- Calls that go "up" the chain use `declare-function` at the top of the file.
  A missing one is a compile warning, which fails the build. Optional external
  packages are declared as `"ext:pkg"` and loaded lazily.
- The core does not name higher layers. It talks to them through hooks in
  readq-core.el (`readq-queue-changed-hook`, `readq-reading-functions`,
  `readq-rescheduled-functions`, `readq-book-display-hook`,
  `readq-save-all-hook`, `readq-queue-exclude-functions`) and others in plan,
  book and extract. Keep it that way: add a hook, don't add a require.
- Adding a viewer: one `readq-define-viewer` call. `readq-pdf-canvas.el` is
  the model to follow.
- `readq-doctor` (C-c r ?) is built from `readq-doctor-functions`. A new
  external program or package gets a check there.
- Public API for other packages: `readq-add-extract`, `readq-current-book`.
  my-gptel-study (`../my-gptel-study`) uses them. `readq--*` is internal, but the
  CHANGELOG (0.4.0) promises that `readq--create-extract` and
  `readq--buffer-book` keep their signatures for older callers.

## Data model

- Items (books, sections, extracts) are **plists** in `readq--books`, read with
  `readq--get`. The DB is printed `lisp-data` with `:version`, `:books`, `:log`,
  `:focus`, `:subset`, `:tag-deadlines`, `:exams`, `:spread-date`.
- **Changing the stored format:** bump `readq--db-version`, add an upgrade step
  to `readq--db-upgrades` (`readq--upgrade-N-to-N+1`), add a test, and add a
  CHANGELOG entry under "where and how things are stored". The middle version
  number goes up.
- Saves are debounced (`readq-save-delay`) and atomic: write a temp file, read
  it back, rename. A daily backup is taken before the first save of the day.
  Call `readq--save`, never write the file directly. In batch (`noninteractive`)
  saves are immediate.
- readq won't save over a queue file that changed on disk since it last
  read or wrote it (`readq--db-stamp`, `readq--may-save-p`). Anything new
  that writes `readq-db-file` must update the stamp, or reload with
  `readq--load`.
- `readq--index` is valid as long as `readq--generation` hasn't changed. It
  doesn't walk the list. Any new code that adds, removes or relinks items
  (`:id`, `:book`, `:parent`) must go through `readq--add-item`,
  `readq--remove-items` or `readq--put`, or bump the generation itself.
- Priority runs from 0 (most important) to 100. Books come back at a steady
  rhythm set by priority. Extract intervals grow by an A-factor.
- Extracts are Denote-named Org files with no property drawers, found by
  identifier in any silo. Figures go in `readq-figures-directory`.

## Tests

- Each module has `test/readq-<topic>-test.el` with its own short prefix
  (`readq-xtest-`, `readq-mtest-`, `readq-ctest-`…). Base helpers live in
  `test/readq-test.el`: `readq-test--with-db` (fresh DB and extracts dir in a
  temp dir, binding all the `readq--` state vars), `readq-test--touch`,
  `readq-test--now`, `readq-test--note`.
- **When you add a `readq--` state variable, also bind it in
  `readq-test--with-db`.** Otherwise tests leak state into each other.
- Optional tools are guarded with `skip-unless` (mpv, nov+zip, pdf-tools,
  org-srs, 7z/bsdtar, python3, denote). Fakes: `test/fake-ankiconnect.py`,
  `test/fake-sumatra.sh`, mpv lua tests. Fixtures are in `test/fixtures/`
  (see its README).
- Every behavior change or bug fix gets a test.

## Docs: update them with the code

A user-visible change touches all of these in the same commit:
1. `CHANGELOG.md`, under `## Unreleased`: a bold one-line summary, then plain
   prose with the key, command name and option.
2. `doc/readq.org`, the manual (task-based sections). Run `make info` and
   commit the regenerated `readq.texi`/`readq.info`.
3. The docstrings, plus `readq-command-map` and the dashboard keys if a key
   changed.
4. Outside this repo, in `~/.emacs.d/lisp/my-command-menu.el`: the readq
   command list and the transient menu `my/command-menu-readq`. These keep
   the same letters as `C-c r`. Tell the user if this needs updating; it is a
   different git repo (`~/.emacs.d`).

## Style

- Write prose (docstrings, manual, CHANGELOG, commit messages) the way the
  existing text is written: plain short English, second person, about what the
  user sees and does, no jargon. "Your place is saved", not "persists cursor
  state".
- Commit subjects are a plain sentence fragment describing the user-facing
  change, with no `feat:` prefixes. Examples: "Merge: take the extract here, not
  the book", "Denote silos: a book's extracts in a notes folder of their own".
  The body explains what was wrong and what happens now.
- Elisp: `lexical-binding`, `cl-lib`/`subr-x`, `when-let*`, docstrings that
  pass checkdoc (two spaces after a period, argument names in CAPS), sections
  marked with `;;;;`. Match the comment density of the surrounding code.
- Keys: everything lives under `C-c r` (`readq-command-map`). Check for
  collisions in readq.el and on the dashboard before you take a letter.

## Workflow

- Work happens on `main` locally, and on `claude/*` branches with PRs from
  cloud sessions. Commit or push only when the user asks. Check
  `git status`/`git log` first, since a cloud session may have pushed.
- Related repos, siblings in `~/.emacs.d/lisp/`: `card-export` (required),
  `readq-comic` (required), `multi-region`, `pdf-canvas`, `kokoro.el`,
  `my-gptel-study`. Breaking a public symbol they use breaks the user's Emacs.
- The user's config loads readq in `~/.emacs.d/lisp/my-init-reading.el`
  (`(require 'readq) (readq-mode 1)`, `C-c r`). To try a change in their
  running Emacs, `M-x load-file` or eval-buffer. The DB is already loaded
  there, so be careful with anything that rewrites it.
