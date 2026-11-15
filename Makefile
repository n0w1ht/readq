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
SIBLINGS := card-export readq-comic multi-region denote nov esxml dash consult compat \
            org-srs fsrs all-the-icons pdf-tools/lisp tablist pdf-canvas kokoro.el
LOAD := -L . $(foreach d,$(SIBLINGS),$(if $(wildcard ../$(d)),-L ../$(d))) \
        $(foreach d,$(DEPS),-L $(d))
SRC := $(wildcard readq*.el)
TESTS := $(sort $(wildcard test/*-test.el))

.PHONY: check compile test clean

check: compile test

compile: clean
	$(EMACS) -Q --batch $(LOAD) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)
	rm -f *.elc

test:
	$(EMACS) -Q --batch $(LOAD) -L test \
	  $(foreach t,$(TESTS),--eval "(require '$(basename $(notdir $(t))))") \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
