EMACS ?= emacs
EMACSCLIENT ?= emacsclient

.PHONY: test session-cli-test compile check benchmark benchmark-large

test:
	$(EMACS) -Q --batch -L . -L test -l diffs-tests \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote bytecomp)) \
	    (let ((byte-compile-dest-file-function \
	           (lambda (_file) (make-temp-file "diffs-" nil ".elc")))) \
	      (mapc (function byte-compile-file) \
	            (quote ("diffs.el" "diffs-cli.el" "diffs-assets.el")))))'

session-cli-test:
	EMACS="$(EMACS)" EMACSCLIENT="$(EMACSCLIENT)" \
	  ./test/run-session-cli.sh

check: test session-cli-test compile

benchmark:
	$(EMACS) -Q --batch -L . -l test/diffs-benchmark.el

benchmark-large:
	DIFFS_BENCH_FILES=4000 \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el
