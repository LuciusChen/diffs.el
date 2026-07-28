;;; diffs-cli.el --- Live diffs.el session CLI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.13.0
;; Keywords: vc, tools

;;; Commentary:

;; Connect a command-line coding agent directly to a live diffs.el
;; review through the user's existing Emacs server.

;;; Code:

(require 'json)
(require 'server)
(require 'subr-x)

(defvar diffs-cli--server
  (or (getenv "DIFFS_EMACS_SERVER") "server")
  "Emacs server name used by the diffs CLI.")

(defvar diffs-cli--args
  (if (equal (car command-line-args-left) "--")
      (cdr command-line-args-left)
    command-line-args-left)
  "Unconsumed diffs CLI arguments.")

(defun diffs-cli--fail (format-string &rest arguments)
  "Print FORMAT-STRING with ARGUMENTS and terminate unsuccessfully."
  (princ (concat "diffs: "
                 (apply #'format format-string arguments)
                 "\n")
         'external-debugging-output)
  (kill-emacs 1))

(defun diffs-cli--take ()
  "Return and consume the next CLI argument."
  (or (pop diffs-cli--args)
      (diffs-cli--fail "missing argument")))

(defun diffs-cli--take-value (option)
  "Return the value following OPTION."
  (unless diffs-cli--args
    (diffs-cli--fail "%s requires a value" option))
  (diffs-cli--take))

(defun diffs-cli--selector (current option)
  "Return a session selector after parsing OPTION.
CURRENT is the selector already parsed, if any."
  (when current
    (diffs-cli--fail "use only one of --repo and --session"))
  (pcase option
    ("--repo"
     (file-name-as-directory
      (expand-file-name (diffs-cli--take-value option))))
    ("--session"
     (diffs-cli--take-value option))))

(defun diffs-cli--eval (form)
  "Evaluate FORM in the configured live Emacs server."
  (condition-case error-data
      (let ((result (server-eval-at diffs-cli--server form)))
        ;; `server-eval-at' transports returned strings as raw bytes.
        ;; Review APIs return UTF-8 JSON, so decode that wire value before
        ;; parsing or printing it in this command-line Emacs process.
        (if (and (stringp result)
                 (not (multibyte-string-p result)))
            (decode-coding-string result 'utf-8)
          result))
    (error
     (diffs-cli--fail
      "cannot use Emacs server %s: %s"
      diffs-cli--server
      (error-message-string error-data)))))

(defun diffs-cli--parsed-json (json)
  "Parse JSON into lists and alists."
  (json-parse-string
   json :object-type 'alist :array-type 'list
   :null-object nil :false-object nil))

(defun diffs-cli--json-value (object key)
  "Return KEY from parsed JSON alist OBJECT."
  (or (cdr (assq key object))
      (cdr (assoc (symbol-name key) object))))

(defun diffs-cli--print-json (json compact)
  "Print JSON, preserving compact form when COMPACT is non-nil."
  (if compact
      (princ json)
    (with-temp-buffer
      (insert json)
      (json-pretty-print-buffer)
      (princ (buffer-string))))
  (princ "\n"))

(defun diffs-cli--parse-common (allowed)
  "Parse common options listed in ALLOWED.
Return a plist with selector, json, patch, notes, file, type, focus,
stdin, and yes values."
  (let (selector json patch notes file type focus stdin yes positionals)
    (while diffs-cli--args
      (let ((argument (diffs-cli--take)))
        (pcase argument
          ((or "--repo" "--session")
           (unless (memq 'selector allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq selector
                 (diffs-cli--selector selector argument)))
          ("--json"
           (unless (memq 'json allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq json t))
          ("--include-patch"
           (unless (memq 'patch allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq patch t))
          ("--include-notes"
           (unless (memq 'notes allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq notes t))
          ("--file"
           (unless (memq 'file allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq file (diffs-cli--take-value argument)))
          ("--type"
           (unless (memq 'type allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq type (diffs-cli--take-value argument)))
          ("--focus"
           (unless (memq 'focus allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq focus t))
          ("--stdin"
           (unless (memq 'stdin allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq stdin t))
          ("--yes"
           (unless (memq 'yes allowed)
             (diffs-cli--fail "unexpected option %s" argument))
           (setq yes t))
          ((pred (lambda (value)
                   (string-prefix-p "-" value)))
           (diffs-cli--fail "unknown option %s" argument))
          (_
           (push argument positionals)))))
    (list :selector selector :json json :patch patch :notes notes
          :file file :type type :focus focus :stdin stdin :yes yes
          :positionals (nreverse positionals))))

(defun diffs-cli--print-session-list (json compact)
  "Print session list JSON in COMPACT or human form."
  (if compact
      (diffs-cli--print-json json t)
    (let ((sessions (diffs-cli--parsed-json json)))
      (if (null sessions)
          (princ "No live diffs sessions.\n")
        (dolist (session sessions)
          (princ
           (format "%s  %s  %d files  %d comments\n"
                   (diffs-cli--json-value session 'id)
                   (diffs-cli--json-value session 'repository)
                   (diffs-cli--json-value session 'files)
                   (diffs-cli--json-value session 'annotations))))))))

(defun diffs-cli--session-list ()
  "Run `diffs session list'."
  (let* ((options (diffs-cli--parse-common '(json)))
         (result
          (diffs-cli--eval '(diffs-review-sessions-json))))
    (diffs-cli--print-session-list result (plist-get options :json))))

(defun diffs-cli--session-review ()
  "Run `diffs session review'."
  (let* ((options
          (diffs-cli--parse-common
           '(selector json patch notes)))
         (result
          (diffs-cli--eval
           (list 'diffs-review-json
                 (plist-get options :selector)
                 (plist-get options :patch)
                 (plist-get options :notes)))))
    (diffs-cli--print-json result (plist-get options :json))))

(defun diffs-cli--comment-list ()
  "Run `diffs session comment list'."
  (let* ((options
          (diffs-cli--parse-common
           '(selector json file type)))
         (result
          (diffs-cli--eval
           (list 'diffs-review-comments-json
                 (plist-get options :selector)
                 (plist-get options :type)
                 (plist-get options :file)))))
    (diffs-cli--print-json result (plist-get options :json))))

(defun diffs-cli--stdin ()
  "Read the complete standard input as a string."
  (with-temp-buffer
    (insert-file-contents "/dev/stdin")
    (buffer-string)))

(defun diffs-cli--comment-apply ()
  "Run `diffs session comment apply'."
  (let ((options
         (diffs-cli--parse-common
          '(selector json focus stdin))))
    (unless (plist-get options :stdin)
      (diffs-cli--fail "comment apply requires --stdin"))
    (let* ((payload (diffs-cli--stdin))
           (_
            (condition-case error-data
                (diffs-cli--parsed-json payload)
              (error
               (diffs-cli--fail
                "invalid stdin JSON: %s"
                (error-message-string error-data)))))
           (result
            (diffs-cli--eval
             (list 'diffs-review-apply-comments-json
                   payload
                   (plist-get options :selector)
                   (plist-get options :focus)))))
      (diffs-cli--print-json result (plist-get options :json)))))

(defun diffs-cli--comment-rm ()
  "Run `diffs session comment rm'."
  (let* ((options
          (diffs-cli--parse-common '(selector json)))
         (positionals (plist-get options :positionals)))
    (unless (= (length positionals) 1)
      (diffs-cli--fail "comment rm requires one comment id"))
    (let ((result
           (diffs-cli--eval
            (list 'diffs-review-remove-comment-json
                  (plist-get options :selector)
                  (car positionals)))))
      (diffs-cli--print-json result (plist-get options :json)))))

(defun diffs-cli--comment-clear ()
  "Run `diffs session comment clear'."
  (let ((options
         (diffs-cli--parse-common
          '(selector json file type yes))))
    (unless (plist-get options :yes)
      (diffs-cli--fail "comment clear requires --yes"))
    (let ((result
           (diffs-cli--eval
            (list 'diffs-review-clear-comments-json
                  (plist-get options :selector)
                  (plist-get options :file)
                  (plist-get options :type)))))
      (diffs-cli--print-json result (plist-get options :json)))))

(defun diffs-cli--usage ()
  "Print the diffs live-session CLI usage."
  (princ
   (concat
    "Usage:\n"
    "  diffs [--server NAME] session list [--json]\n"
    "  diffs [--server NAME] session review [--repo PATH | --session ID]\n"
    "        [--include-patch] [--include-notes] [--json]\n"
    "  diffs [--server NAME] session comment list\n"
    "        [--repo PATH | --session ID] [--file PATH]\n"
    "        [--type all|user|agent] [--json]\n"
    "  diffs [--server NAME] session comment apply\n"
    "        [--repo PATH | --session ID] --stdin [--focus] [--json]\n"
    "  diffs [--server NAME] session comment rm\n"
    "        [--repo PATH | --session ID] COMMENT_ID [--json]\n"
    "  diffs [--server NAME] session comment clear\n"
    "        [--repo PATH | --session ID] [--file PATH]\n"
    "        [--type all|user|agent] --yes [--json]\n")))

(defun diffs-cli--main ()
  "Dispatch the diffs live-session CLI."
  (when (equal (car diffs-cli--args) "--server")
    (pop diffs-cli--args)
    (setq diffs-cli--server
          (diffs-cli--take-value "--server")))
  (when (member (car diffs-cli--args) '("-h" "--help"))
    (diffs-cli--usage)
    (kill-emacs 0))
  (unless (equal (diffs-cli--take) "session")
    (diffs-cli--fail "expected the session command"))
  (pcase (diffs-cli--take)
    ("list" (diffs-cli--session-list))
    ("review" (diffs-cli--session-review))
    ("comment"
     (pcase (diffs-cli--take)
       ("list" (diffs-cli--comment-list))
       ("apply" (diffs-cli--comment-apply))
       ("rm" (diffs-cli--comment-rm))
       ("clear" (diffs-cli--comment-clear))
       (command
        (diffs-cli--fail "unknown comment command %s" command))))
    (command
     (diffs-cli--fail "unknown session command %s" command))))

(unless (bound-and-true-p byte-compile-current-file)
  (diffs-cli--main))

(provide 'diffs-cli)
;;; diffs-cli.el ends here
