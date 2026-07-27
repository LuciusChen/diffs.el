EMACS ?= emacs

.PHONY: test compile check

test:
	$(EMACS) -Q --batch -L . -L test -l diffs-tests \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote bytecomp)) \
	    (let ((byte-compile-dest-file-function \
	           (lambda (_file) (make-temp-file "diffs-" nil ".elc")))) \
	      (byte-compile-file "diffs.el")))'

check: test compile
