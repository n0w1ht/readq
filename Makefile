# readq: compile and test.
#
#   make compile   byte-compile every file; a warning is an error
#   make test      run all the tests (those missing a dependency are skipped)
#   make check     both
#
# Packages readq needs or can use are looked for next to this folder
# (../card-export, ../readq-comic, ../multi-region, ...) and in the
# folders named in DEPS, separated by spaces.

EMACS ?= emacs
DEPS ?=
# Your Emacs may have left .elc files here; when a .el file is newer
# (you edited it), load that instead.
NEWER := --eval '(setq load-prefer-newer t)'
SIBLINGS := card-export readq-comic multi-region denote nov esxml dash consult compat \
            org-srs fsrs all-the-icons pdf-tools/lisp tablist pdf-canvas kokoro.el
LOAD := -L . $(foreach d,$(SIBLINGS),$(if $(wildcard ../$(d)),-L ../$(d))) \
        $(foreach d,$(DEPS),-L $(d))
SRC := $(wildcard readq*.el)
TESTS := $(sort $(wildcard test/*-test.el))

.PHONY: check compile test clean info

check: compile test

compile: clean
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)
	rm -f *.elc

test:
	$(EMACS) -Q --batch $(NEWER) $(LOAD) -L test \
	  $(foreach t,$(TESTS),--eval "(require '$(basename $(notdir $(t))))") \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc

# The manual: doc/readq.org is the source; readq.texi and readq.info
# are made from it and committed, so that C-h R readq works without
# building anything.
info:
	$(EMACS) -Q --batch $(NEWER) $(LOAD) --eval "(progn (require 'readq) \
	  (let (c v) (mapatoms (lambda (s) (when (and (string-prefix-p \"readq\" (symbol-name s)) \
	    (not (string-match-p \"--\" (symbol-name s)))) \
	    (when (commandp s) (push (symbol-name s) c)) \
	    (when (custom-variable-p s) (push (symbol-name s) v))))) \
	  (with-temp-file \"doc/commands.txt\" (insert (string-join (sort c #'string<) \"\n\"))) \
	  (with-temp-file \"doc/options.txt\" (insert (string-join (sort v #'string<) \"\n\"))) \
	  (with-temp-file \"doc/keys.txt\" (map-keymap (lambda (k c) (when (and (symbolp c) (characterp k)) \
	    (insert (format \"%c %s\\n\" k c)))) readq-command-map))))"
	python3 doc/add-index.py doc/readq.org doc/commands.txt doc/options.txt doc/keys.txt
	rm -f doc/commands.txt doc/options.txt doc/keys.txt
	cd doc && $(EMACS) -Q --batch readq.org \
	  --eval "(progn (require 'ox-texinfo) (org-texinfo-export-to-texinfo))"
	cd doc && makeinfo --no-split readq.texi -o readq.info
	cd doc && rm -f dir && install-info readq.info dir
