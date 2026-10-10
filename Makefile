EMACS ?= emacs
EMACSCLIENT ?= emacsclient

PACKAGE_FILES = diffs.el diffs-assets.el diffs-cli.el \
	diffs-diff-hl.el diffs-review-compose.el
LISP_FILES = $(patsubst %,"%",$(PACKAGE_FILES))

.PHONY: test session-cli-test compile checkdoc package-lint lint check \
	benchmark benchmark-complex benchmark-hunk benchmark-large

# The Lisp forms below reach Emacs through the environment.  A backslash-
# newline inside single quotes is dropped by the make 3.81 that ships with
# macOS but passed through by GNU make 4, where the Lisp reader would see it.

# Warnings are errors: AGENTS.md requires zero byte-compiler warnings.
define COMPILE_FORM
(progn
  (require 'bytecomp)
  (setq byte-compile-error-on-warn t
        byte-compile-dest-file-function
        (lambda (_file) (make-temp-file "diffs-" nil ".elc"))
        command-line-args-left '($(LISP_FILES)))
  (batch-byte-compile))
endef

# The verb check is on by default before Emacs 31 and off after it, so
# enable it explicitly to get the same result on every supported version.
define CHECKDOC_FORM
(progn
  (require 'checkdoc)
  (setq checkdoc-verb-check-experimental-flag t)
  (dolist (file '($(LISP_FILES)))
    (checkdoc-file file))
  (when-let* ((buffer (get-buffer "*Warnings*")))
    (with-current-buffer buffer
      (princ (buffer-string)))
    (kill-emacs 1)))
endef

# Needs the package-lint package from MELPA.
define PACKAGE_LINT_FORM
(progn
  (require 'package)
  (package-initialize)
  (unless (require 'package-lint nil t)
    (error "Install package-lint from MELPA to run this check"))
  (setq package-lint-main-file "diffs.el"))
endef

export COMPILE_FORM CHECKDOC_FORM PACKAGE_LINT_FORM

test:
	$(EMACS) -Q --batch -L . -L test -l diffs-tests \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . --eval "$$COMPILE_FORM"

checkdoc:
	$(EMACS) -Q --batch -L . --eval "$$CHECKDOC_FORM"

package-lint:
	$(EMACS) -Q --batch --eval "$$PACKAGE_LINT_FORM" \
	  -f package-lint-batch-and-exit $(PACKAGE_FILES)

lint: checkdoc package-lint

session-cli-test:
	EMACS="$(EMACS)" EMACSCLIENT="$(EMACSCLIENT)" \
	  ./test/run-session-cli.sh

check: test session-cli-test compile lint

benchmark:
	DIFFS_BENCH_PROFILE=volume \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el
	DIFFS_BENCH_PROFILE=complex \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el
	DIFFS_BENCH_PROFILE=hunk \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el

benchmark-complex:
	DIFFS_BENCH_PROFILE=complex \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el

benchmark-hunk:
	DIFFS_BENCH_PROFILE=hunk \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el

benchmark-large:
	DIFFS_BENCH_PROFILE=volume DIFFS_BENCH_FILES=4000 \
	  $(EMACS) -Q --batch -L . -l test/diffs-benchmark.el
