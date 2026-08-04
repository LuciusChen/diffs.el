;;; diffs-tests.el --- Tests for diffs.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'diffs)

(defconst diffs-tests--diff-hl-adapter-was-lazy
  (and (autoloadp (symbol-function 'diffs-diff-hl-show-hunk))
       (autoloadp (symbol-function 'diffs-diff-hl-mode))
       (not (featurep 'diffs-diff-hl)))
  "Non-nil when the core installed lazy diff-hl adapter entry points.")

(defconst diffs-tests--review-composer-was-lazy
  (not (featurep 'diffs-review-compose))
  "Non-nil when loading diffs.el left its comment composer unloaded.")

(require 'diffs-diff-hl)
(require 'vc-git)
(require 'xref)

(defvar diff-hl-show-staged-changes)
(defvar diff-hl-reference-revision)
(defvar diff-hl-reference-revision-projects-cache)
(defvar diff-hl-show-hunk-function)
(defvar diff-hl-show-hunk-inline-smart-lines t)

(cl-defmethod xref-backend-identifier-at-point
  ((_backend (eql diffs-tests)))
  (thing-at-point 'symbol t))

(cl-defmethod xref-backend-definitions
  ((_backend (eql diffs-tests)) identifier)
  (list
   (xref-make
    identifier
    (xref-make-buffer-location (current-buffer) (point)))))

(defconst diffs-tests--normal
  (concat
   "diff --git a/foo.el b/foo.el\n"
   "index 1111111..2222222 100644\n"
   "--- a/foo.el\n"
   "+++ b/foo.el\n"
   "@@ -1,2 +1,3 @@\n"
   " (message \"same\")\n"
   "-(message \"old\")\n"
   "+(message \"new\")\n"
   "+(message \"extra\")\n"))

(defconst diffs-tests--png
  (base64-decode-string
   "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
  "A valid one-pixel PNG used by review attachment tests.")

(defconst diffs-tests--rename
  (concat
   "diff --git a/old.el b/new.el\n"
   "similarity index 100%\n"
   "rename from old.el\n"
   "rename to new.el\n"))

(defconst diffs-tests--two-files
  (concat
   diffs-tests--normal
   "diff --git a/bar.el b/bar.el\n"
   "index 3333333..4444444 100644\n"
   "--- a/bar.el\n"
   "+++ b/bar.el\n"
   "@@ -10 +10 @@ bar-function\n"
   "-old bar\n"
   "+new bar\n"))

(defconst diffs-tests--hidden-context
  (concat
   "diff --git a/context.el b/context.el\n"
   "--- a/context.el\n"
   "+++ b/context.el\n"
   "@@ -5 +5 @@ context-function\n"
   "-old five\n"
   "+new five\n"))

(defconst diffs-tests--directional-context
  (concat
   "diff --git a/context.el b/context.el\n"
   "--- a/context.el\n"
   "+++ b/context.el\n"
   "@@ -3 +3 @@ first\n"
   "-old three\n"
   "+new three\n"
   "@@ -8 +8 @@ second\n"
   "-old eight\n"
   "+new eight\n"))

(defconst diffs-tests--two-change-blocks
  (concat
   "diff --git a/two.el b/two.el\n"
   "--- a/two.el\n"
   "+++ b/two.el\n"
   "@@ -1,5 +1,5 @@\n"
   " same\n"
   "-old one\n"
   "+new one\n"
   " middle\n"
   "-old two\n"
   "+new two\n"
   " tail\n"))

(defconst diffs-tests--addition-before-change
  (concat
   "diff --git a/shift.el b/shift.el\n"
   "--- a/shift.el\n"
   "+++ b/shift.el\n"
   "@@ -1,4 +1,5 @@\n"
   " same\n"
   "+inserted\n"
   " middle\n"
   "-old value\n"
   "+new value\n"
   " tail\n"))

(defconst diffs-tests--deletion-before-change
  (concat
   "diff --git a/shift.el b/shift.el\n"
   "--- a/shift.el\n"
   "+++ b/shift.el\n"
   "@@ -1,5 +1,4 @@\n"
   " same\n"
   "-removed\n"
   " middle\n"
   "-old value\n"
   "+new value\n"
   " tail\n"))

(defconst diffs-tests--unequal-replacement-before-change
  (concat
   "diff --git a/unequal.el b/unequal.el\n"
   "--- a/unequal.el\n"
   "+++ b/unequal.el\n"
   "@@ -9,6 +9,5 @@\n"
   " same\n"
   "-old first\n"
   "-old second\n"
   "+new combined\n"
   " middle\n"
   "-old later\n"
   "+new later\n"
   " tail\n"))

(defconst diffs-tests--complex-replacement
  (let ((payload (make-string 160 ?x)))
    (concat
     "diff --git a/complex.el b/complex.el\n"
     "--- a/complex.el\n"
     "+++ b/complex.el\n"
     "@@ -1,4 +1,4 @@\n"
     (mapconcat
      (lambda (index)
        (format "-(setq record-%d \"%s old\")\n" index payload))
      (number-sequence 0 3) "")
     (mapconcat
      (lambda (index)
        (format "+(setq record-%d \"%s new\")\n" index payload))
      (number-sequence 0 3) "")))
  "Small replacement whose content is expensive to pair and refine.")

(defconst diffs-tests--context-zero-deletion
  (concat
   "diff --git a/pure.el b/pure.el\n"
   "--- a/pure.el\n"
   "+++ b/pure.el\n"
   "@@ -2 +1,0 @@\n"
   "-removed\n"))

(defconst diffs-tests--foo-context-zero-deletion
  (concat
   "diff --git a/foo.el b/foo.el\n"
   "--- a/foo.el\n"
   "+++ b/foo.el\n"
   "@@ -2 +1,0 @@\n"
   "-(message \"old\")\n"))

(defconst diffs-tests--zero-count-addition
  (concat
   "diff --git a/added.el b/added.el\n"
   "--- /dev/null\n"
   "+++ b/added.el\n"
   "@@ -0,0 +1 @@\n"
   "+added\n"))

(defconst diffs-tests--two-source-files
  (concat
   "diff --git a/bar.el b/bar.el\n"
   "--- a/bar.el\n"
   "+++ b/bar.el\n"
   "@@ -1 +1 @@\n"
   "-old bar\n"
   "+new bar\n"
   "diff --git a/foo.el b/foo.el\n"
   "--- a/foo.el\n"
   "+++ b/foo.el\n"
   "@@ -1 +1 @@\n"
   "-old foo\n"
   "+new foo\n"))

(defconst diffs-tests--two-conflicts
  (concat
   "(message \"before\")\n"
   "<<<<<<< HEAD\n"
   "(message \"current one\")\n"
   "=======\n"
   "(message \"incoming one\")\n"
   "(message \"incoming extra\")\n"
   ">>>>>>> feature/one\n"
   "(message \"middle\")\n"
   "<<<<<<< HEAD\n"
   "(message \"current two a\")\n"
   "(message \"current two b\")\n"
   "=======\n"
   "(message \"incoming two\")\n"
   ">>>>>>> feature/two\n"
   "(message \"after\")\n"))

(defconst diffs-tests--diff3-conflict
  (concat
   "(setq value\n"
   "<<<<<<< HEAD\n"
   "      'current)\n"
   "||||||| base-revision\n"
   "      'base)\n"
   "=======\n"
   "      'incoming)\n"
   ">>>>>>> feature/value\n"))

(defmacro diffs-tests--with-conflict-source (text &rest body)
  (declare (indent 1) (debug t))
  `(let* ((directory (make-temp-file "diffs-conflict-" t))
          (file (expand-file-name "source.el" directory))
          source-buffer)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert ,text))
           (setq source-buffer (find-file-noselect file))
           (with-current-buffer source-buffer
             (emacs-lisp-mode)
             (buffer-disable-undo)
             (buffer-enable-undo)
             (set-buffer-modified-p nil)
             ,@body))
       (when (buffer-live-p source-buffer)
         (with-current-buffer source-buffer
           (when diffs-conflict-mode
             (diffs-conflict-mode -1))
           (when (bound-and-true-p smerge-mode)
             (smerge-mode -1))
           (setq buffer-read-only nil)
           (widen)
           (set-buffer-modified-p nil))
         (kill-buffer source-buffer))
       (delete-directory directory t))))

(defmacro diffs-tests--with-diff (text &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (diff-mode)
     ,@body))

(defun diffs-tests--face-includes-p (value face)
  "Return non-nil when face VALUE includes FACE."
  (or (eq value face)
      (and (listp value) (memq face value))))

(defun diffs-tests--review-annotation-projection (summary)
  "Return (DISPLAY . PREFIX-PIXELS) for projected annotation SUMMARY."
  (let ((overlay
         (cl-find-if
          (lambda (candidate)
            (when-let* ((display (overlay-get candidate 'after-string)))
              (string-match-p (regexp-quote summary) display)))
          (overlays-in (point-min) (point-max)))))
    (unless overlay
      (ert-fail (format "No projected review annotation contains %S" summary)))
    (save-excursion
      (goto-char (overlay-start overlay))
      (cons (overlay-get overlay 'after-string)
            (diffs--review-line-prefix-pixel-width
             (line-beginning-position))))))

(defun diffs-tests--review-annotation-align-position (display)
  "Return the absolute pixel alignment encoded in annotation DISPLAY."
  (when-let* ((position
               (text-property-not-all 0 (length display)
                                      'display nil display))
              (space (get-text-property position 'display display))
              (align (plist-get (cdr space) :align-to))
              ((and (consp align)
                    (numberp (car align))
                    (null (cdr align)))))
    (car align)))

(defun diffs-tests--assert-file-comparison-side-header
    (header label own-suffix peer-suffix)
  "Assert HEADER uses LABEL and OWN-SUFFIX, but not PEER-SUFFIX."
  (should
   (string-match-p
    (format "\\`%s · .*%s" label (regexp-quote own-suffix))
    header))
  (should-not
   (string-match-p (regexp-quote peer-suffix) header)))

(defun diffs-tests--review-annotation-expected-right-edge (display prefix)
  "Return expected right-border pixels for DISPLAY after PREFIX."
  (let ((corner (string-match "╮" display)))
    (unless corner
      (ert-fail "Projected review annotation has no top-right corner"))
    (+ prefix
       (string-pixel-width (substring display 1 corner)
                           (current-buffer)))))

(defun diffs-tests--split-insert-row
    (string number source kind file width role)
  "Insert and decorate one split test row."
  (let ((begin (point)))
    (insert string "\n")
    (diffs--split-decorate-row
     begin (point)
     (list string number source kind file nil nil nil)
     width role)))

(defun diffs-tests--many-file-patch (count)
  "Return a simple Git patch containing COUNT changed files."
  (with-temp-buffer
    (dotimes (file count)
      (insert
       (format
        (concat
         "diff --git a/f%02d.el b/f%02d.el\n"
         "--- a/f%02d.el\n"
         "+++ b/f%02d.el\n"
         "@@ -1,3 +1,3 @@\n"
         " (message \"context\")\n"
         "-(message \"old-%02d\")\n"
         "+(message \"new-%02d\")\n"
         " (message \"tail\")\n")
        file file file file file file)))
    (buffer-string)))

(defun diffs-tests--changed-texts (old new)
  "Return changed OLD and NEW substrings under the current options."
  (pcase-let ((`(,old-ranges . ,new-ranges)
               (diffs--intraline-ranges old new)))
    (cons
     (mapcar (lambda (range)
               (substring old (car range) (cdr range)))
             old-ranges)
     (mapcar (lambda (range)
               (substring new (car range) (cdr range)))
             new-ranges))))

(defun diffs-tests--minimal-token-edit-distance (old new)
  "Return the minimum insertion/deletion distance from OLD to NEW."
  (let* ((old-count (length old))
         (new-count (length new))
         (previous (vconcat (number-sequence 0 new-count))))
    (dotimes (old-index old-count)
      (let ((current (make-vector (1+ new-count) 0)))
        (aset current 0 (1+ old-index))
        (dotimes (new-index new-count)
          (aset current (1+ new-index)
                (if (equal (aref old old-index)
                           (aref new new-index))
                    (aref previous new-index)
                  (min (1+ (aref previous (1+ new-index)))
                       (1+ (aref current new-index))))))
        (setq previous current)))
    (aref previous new-count)))

(ert-deftest diffs-defaults-to-diffs-com-style-word-alt ()
  (should (eq (default-value 'diffs-line-diff-type) 'word-alt))
  (should (= (default-value 'diffs-max-line-diff-length) 1000))
  (should (= (default-value 'diffs-line-pair-threshold) 0.6))
  (should (eq (default-value 'diffs-refine-whitespace) 'show)))

(ert-deftest diffs-word-tokenization-is-syntax-table-independent ()
  (let* ((tokens (diffs--word-tokens "foo.bar"))
         (texts (mapcar (lambda (token) (aref token 0))
                        (append tokens nil))))
    (should (equal texts '("foo" "." "bar")))))

(ert-deftest diffs-word-tokenization-matches-diffs-com-for-cjk ()
  (let ((diffs-line-diff-type 'word-alt))
    (should
     (equal (diffs--intraline-ranges "你好世界" "你好朋友")
            '(((2 . 4)) (2 . 4))))))

(ert-deftest diffs-intraline-matches-diffs-com-conformance-corpus ()
  (dolist
      (fixture
       '((js-value word-alt
          "const value = oldValue;" "const value = newValue;"
          ("oldValue") ("newValue"))
         (elisp-symbol word-alt
          "(setq old-value source)" "(setq new-value source)"
          ("old") ("new"))
         (tiny-separator word-alt
          "foo.bar" "baz.qux"
          ("foo.bar") ("baz.qux"))
         (one-sided-edit-boundary word-alt
          "old.,tail" "new.extra,tail"
          ("old.") ("new.extra"))
         (exact-separator word
          "foo.bar" "baz.qux"
          ("foo" "bar") ("baz" "qux"))
         (repeated-token word-alt
          "a + a + b" "a + b + b"
          ("a") ("b"))
         (repeated-property word-alt
          "{ old: old, keep: true }" "{ new: old, keep: true }"
          ("old") ("new"))
         (camel-case word-alt
          "getUserName()" "setUserName()"
          ("getUserName") ("setUserName"))
         (snake-case word-alt
          "snake_case" "snake_value"
          ("snake_case") ("snake_value"))
         (cjk word-alt
          "你好世界" "你好朋友"
          ("世界") ("朋友"))
         (japanese word-alt
          "設定を読み込む" "設定を保存する"
          ("読み込む") ("保存する"))
         (korean word-alt
          "설정을 읽는다" "설정을 저장한다"
          ("읽는") ("저장한"))
         (arabic-terminal-neutral word-alt
          "مرحبا بالعالم" "مرحبا بالجميع"
          ("عالم") ("جميع"))
         (devanagari word-alt
          "नमस्ते दुनिया" "नमस्ते विश्व"
          ("दुनिया") ("विश्व"))
         (latin-diacritic word-alt
          "café noir" "cafe noir"
          ("café") ("cafe"))
         (canonical-form word-alt
          "éclair" "éclair"
          ("éclair") ("éclair"))
         (nbsp word-alt
          "x = 1" "x = 1"
          (" = ") (" = "))
         (tabs word-alt
          "foo\tbar" "foo  bar"
          ("\t") ("  "))
         (indentation word-alt
          "  return value;" "    return value;"
          ("  ") ("    "))
         (punctuation-delete word-alt
          "call(a, b, c)" "call(a, c)"
          ("b, ") nil)
         (operator word-alt
          "total += value" "total ??= value"
          ("+") ("??"))
         (string-quote word-alt
          "name = \"old\"" "name = \"new\""
          ("old") ("new"))
         (url word-alt
          "https://example.com/old" "https://example.com/new"
          ("old") ("new"))
         (path word-alt
          "src/old/file.el" "src/new/file.el"
          ("old") ("new"))
         (emoji-person word-alt
          "👩‍💻 works" "👨‍💻 works"
          ("👩") ("👨"))
         (emoji-modifier word-alt
          "👍🏽 approved" "👍🏻 approved"
          ("🏽") ("🏻"))
         (trailing-neutral word-alt
          "old;" "new;"
          ("old") ("new"))
         (leading-neutral word-alt
          ".old" ".new"
          ("old") ("new"))
         (suffix-insert word-alt
          "value)" "value, extra)"
          nil (", extra"))
         (prefix-delete word-alt
          "async function run" "function run"
          ("async ") nil)
         (empty-add word-alt
          "" "new value"
          nil ("new value"))
         (empty-delete word-alt
          "old value" ""
          ("old value") nil)
         (cr-change word-alt
          "value\r" "other\r"
          ("value") ("other"))
         (formatter-object word-alt
          "return { foo: old, bar: old };"
          "return { foo: new, bar: new };"
          ("old" "old") ("new" "new"))
         (comment word-alt
          "// return old value" "// return new value"
          ("old") ("new"))
         (char-ascii char
          "foo bar" "foo baz"
          ("r") ("z"))
         (char-emoji char
          "👩‍💻 works" "👨‍💻 works"
          ("👩") ("👨"))
         (char-combining char
          "éclair" "éclair"
          ("é") ("é"))))
    (pcase-let ((`(,name ,type ,old ,new
                         ,old-changes ,new-changes)
                 fixture))
      (ert-info ((format "conformance fixture %s" name))
        (let ((diffs-line-diff-type type)
              (diffs-refine-whitespace 'show)
              (diffs--intraline-cache nil))
          (should
           (equal (diffs-tests--changed-texts old new)
                  (cons old-changes new-changes))))))))

(ert-deftest diffs-word-alt-visually-groups-a-tiny-separator ()
  (let ((diffs-line-diff-type 'word-alt))
    (should
     (equal (diffs--intraline-ranges "foo.bar" "baz.qux")
            '(((0 . 7)) (0 . 7)))))
  (let ((diffs-line-diff-type 'word))
    (should
     (equal (diffs--intraline-ranges "foo.bar" "baz.qux")
            '(((0 . 3) (4 . 7)) (0 . 3) (4 . 7))))))

(ert-deftest diffs-character-refinement-is-finer-than-word-refinement ()
  (let ((diffs-line-diff-type 'char))
    (should
     (equal (diffs--intraline-ranges "foo bar" "foo baz")
            '(((6 . 7)) (6 . 7))))))

(ert-deftest diffs-myers-flags-form-a-minimum-edit-script ()
  (let ((seed #x5eed1234)
        (alphabet ["a" "b" "." " " "你" "م"]))
    (cl-labels
        ((next-random
          ()
          (setq seed
                (logand #xffffffff
                        (+ (* seed 1664525) 1013904223))))
         (random-token-vector
          ()
          (let ((tokens
                 (make-vector (mod (next-random) 9) nil)))
            (dotimes (index (length tokens))
              (aset tokens index
                    (aref alphabet
                          (mod (next-random)
                               (length alphabet)))))
            tokens))
         (records
          (tokens)
          (vconcat
           (cl-loop for text across tokens
                    for index from 0
                    collect (vector text index (1+ index)))))
         (kept
          (tokens changed)
          (cl-loop for text across tokens
                   for index from 0
                   unless (aref changed index)
                   collect text)))
      (dotimes (_ 500)
        (let* ((old (random-token-vector))
               (new (random-token-vector))
               (changed
                (diffs--myers-changed-tokens
                 (records old) (records new)))
               (old-changed (car changed))
               (new-changed (cdr changed)))
          (should
           (= (+ (cl-count t old-changed)
                 (cl-count t new-changed))
              (diffs-tests--minimal-token-edit-distance old new)))
          (should
           (equal (kept old old-changed)
                  (kept new new-changed))))))))

(ert-deftest diffs-refinement-whitespace-is-configurable ()
  (let ((diffs-line-diff-type 'word)
        (diffs-refine-whitespace 'show))
    (should
     (equal (diffs--intraline-ranges "foo bar" "foo  bar")
            '(((3 . 4)) (3 . 5)))))
  (let ((diffs-line-diff-type 'word)
        (diffs-refine-whitespace 'ignore))
    (should-not
     (car (diffs--intraline-ranges "foo bar" "foo  bar")))
    (should-not
     (cdr (diffs--intraline-ranges "foo bar" "foo  bar")))))

(ert-deftest diffs-refinement-can-ignore-unicode-whitespace ()
  (let ((diffs-line-diff-type 'word)
        (diffs-refine-whitespace 'ignore))
    (should
     (equal (diffs--intraline-ranges "x = 1" "x = 1")
            '(nil)))))

(ert-deftest diffs-long-lines-skip-within-line-comparison ()
  (let ((diffs-max-line-diff-length 3))
    (should (equal (diffs--intraline-ranges "older" "newer")
                   '(nil)))))

(ert-deftest diffs-line-alignment-finds-shifted-homologs ()
  (let ((old ["alpha" "beta old"])
        (new ["inserted" "alpha" "beta new"]))
    (should
     (equal (diffs--align-lines old new)
            '((nil . 0) (0 . 1) (1 . 2)))))
  (should
   (equal (diffs--align-lines ["cat"] ["dog"])
          '((0) (nil . 0)))))

(ert-deftest diffs-line-alignment-handles-blank-and-content-shifts ()
  (dolist
      (fixture
       '((["const value = old;"]
          ["" "const value = new;"]
          ((nil . 0) (0 . 1)))
         (["" "const value = old;"]
          ["const value = new;"]
          ((0) (1 . 0)))
         (["const value = old;"]
          ["const value = new;" "log();"]
          ((0 . 0) (nil . 1)))
         (["same" "old value" "tail"]
          ["inserted" "same" "new value" "tail"]
          ((nil . 0) (0 . 1) (1 . 2) (2 . 3)))))
    (pcase-let ((`(,old ,new ,expected) fixture))
      (should (equal (diffs--align-lines old new) expected)))))

(ert-deftest diffs-unified-and-split-share-intraline-ranges ()
  (let ((patch
         (concat
          "diff --git a/sample.js b/sample.js\n"
          "--- a/sample.js\n"
          "+++ b/sample.js\n"
          "@@ -1,2 +1,3 @@\n"
          "-const value = oldValue;\n"
          "-const second = keepOld;\n"
          "+const inserted = true;\n"
          "+const value = newValue;\n"
          "+const second = keepNew;\n")))
    (diffs-tests--with-diff patch
      (diffs-minor-mode 1)
      (font-lock-ensure)
      (goto-char (point-min))
      (re-search-forward "oldValue")
      (should
       (cl-some (lambda (overlay)
                  (eq (overlay-get overlay 'face)
                      'diff-refine-removed))
                (overlays-at (1- (point)))))
      (goto-char (point-min))
      (re-search-forward "newValue")
      (should
       (cl-some (lambda (overlay)
                  (eq (overlay-get overlay 'face)
                      'diff-refine-added))
                (overlays-at (1- (point)))))
      (pcase-let ((`(,old-rows ,new-rows . ,_)
                   (diffs--split-collect)))
        (let* ((old-row
                (cl-find-if
                 (lambda (row) (string-match-p "oldValue" (car row)))
                 old-rows))
               (new-row
                (cl-find-if
                 (lambda (row) (string-match-p "newValue" (car row)))
                 new-rows))
               (inserted-index
                (cl-position-if
                 (lambda (row) (string-match-p "inserted" (car row)))
                 new-rows)))
          (should old-row)
          (should new-row)
          (should (vectorp (nth 7 old-row)))
          (should (eq (nth 7 old-row) (nth 7 new-row)))
          (should
           (equal
            (with-current-buffer (current-buffer)
              (diffs--intraline-ranges
               (aref (nth 7 old-row) 0)
               (aref (nth 7 new-row) 1)))
            (cons
             (list (cons (string-match "oldValue"
                                       (aref (nth 7 old-row) 0))
                         (+ (string-match "oldValue"
                                          (aref (nth 7 old-row) 0))
                            (length "oldValue"))))
             (list (cons (string-match "newValue"
                                       (aref (nth 7 new-row) 1))
                         (+ (string-match "newValue"
                                          (aref (nth 7 new-row) 1))
                            (length "newValue")))))))
          (should (eq (nth 3 (nth inserted-index old-rows))
                      'filler))))
      (diffs-minor-mode -1))))

(ert-deftest diffs-split-virtualizes-visuals-without-hiding-text ()
  (let ((buf (generate-new-buffer " *diffs virtual split test*"))
        (diffs-split-virtualization 'complete)
        (diffs-split-overscan 2)
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert
           "diff --git a/sample.el b/sample.el\n"
           "--- a/sample.el\n"
           "+++ b/sample.el\n"
           "@@ -1,140 +1,140 @@\n")
          (dotimes (index 140)
            (insert (format "-(defun old-function-%03d () nil)\n" index)))
          (dotimes (index 140)
            (insert (format "+(defun new-function-%03d () nil)\n" index)))
          (diff-mode)
          (diffs-minor-mode 1)
          (setq buffer-read-only t)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (let* ((count (length diffs--split-rows))
                 (deep-index (- count 8))
                 (deep-position
                  (diffs--split-row-position deep-index))
                 (window (get-buffer-window new-buf)))
            (should (> count 100))
            (should
             (< (cl-count t diffs--split-decorated) count))
            (should-not (aref diffs--split-decorated deep-index))
            (with-current-buffer old-buf
              (should-not (aref diffs--split-decorated deep-index)))
            (goto-char deep-position)
            (should (looking-at "(defun new-function-"))
            (should
             (equal (diffs--split-property-at
                     'diffs-file deep-position)
                    "sample.el"))
            (should
             (eq (diffs--split-property-at
                  'diffs-kind deep-position)
                 'add))
            (set-window-start window deep-position)
            (diffs--split-materialize-window window)
            (should (aref diffs--split-decorated deep-index))
            (with-current-buffer old-buf
              (should (aref diffs--split-decorated deep-index)))
            (let ((syntax-faces
                   (get-text-property (1+ deep-position) 'face))
                  (line-faces
                   (get-text-property deep-position 'face)))
              (should
               (diffs-tests--face-includes-p
                syntax-faces 'font-lock-keyword-face))
              (should
               (diffs-tests--face-includes-p
                line-faces 'diffs-split-added-line)))
            (re-search-forward "new-function")
            (should
             (diffs-tests--face-includes-p
              (get-text-property (1+ (match-beginning 0)) 'face)
              'diff-refine-added))
            (should
             (get-text-property deep-position 'line-prefix)))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-paged-split-materializes-and-evicts-cold-chunks ()
  (let ((buffer (generate-new-buffer " *diffs paged split test*"))
        (diffs-split-virtualization 'paged)
        (diffs-split-overscan 0)
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert (diffs-tests--many-file-patch 30))
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (should diffs--split-paged-p)
          (should
           (< (cl-count t diffs--split-materialized-chunks)
              (length diffs--split-chunks)))
          (should-not (string-search "new-29" (buffer-string)))
          (let* ((deep-index (- (length diffs--split-rows) 2))
                 (window (get-buffer-window new-buffer)))
            (should-not (aref diffs--split-rows deep-index))
            (set-window-start
             window (diffs--split-row-position deep-index))
            (diffs--split-materialize-window window)
            (let ((position
                   (diffs--split-row-position deep-index)))
              (goto-char position)
              (should (looking-at "(message \"new-29\")"))
              (should
               (equal
                (diffs--split-property-at 'diffs-file position)
                "f29.el"))
              (should
               (eq (diffs--split-property-at 'diffs-kind position)
                   'add)))
            (with-current-buffer old-buffer
              (goto-char (point-min))
              (should (search-forward "old-29" nil t)))
            (should-not (string-search "new-00" (buffer-string)))
            (let ((copy
                   (filter-buffer-substring
                    (point-min) (point-max) nil)))
              (should (string-search "new-00" copy))
              (should (string-search "new-29" copy)))
            (should diffs--split-paged-pinned)
            (should
             (= (cl-count t diffs--split-materialized-chunks)
                (length diffs--split-chunks)))
            (should
             (= (length diffs--split-materialized-indexes)
                (length diffs--split-chunks)))
            (with-current-buffer old-buffer
              (should diffs--split-paged-pinned)
              (should (string-search "old-00" (buffer-string)))))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-paged-split-corrects-inexact-chunk-heights ()
  (let* ((patch
          (concat
           (diffs-tests--many-file-patch 30)
           diffs-tests--unequal-replacement-before-change))
         (buffer
          (generate-new-buffer " *diffs paged height test*"))
         (diffs-split-virtualization 'paged)
         (diffs-split-overscan 0)
         expected-count expected-old expected-new
         old-buffer new-buffer)
    (with-temp-buffer
      (insert patch)
      (diff-mode)
      (diffs-minor-mode 1)
      (pcase-let* ((`(,old ,new . ,_) (diffs--split-collect))
                    (`(,old-physical ,new-physical . ,_)
                     (diffs--split-physical-rows old new 80 nil)))
        (setq expected-count (length old-physical)
              expected-old
              (mapconcat
               (lambda (row) (concat (car row) "\n"))
               (append old-physical nil) "")
              expected-new
              (mapconcat
               (lambda (row) (concat (car row) "\n"))
               (append new-physical nil) "")))
      (diffs-minor-mode -1))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert patch)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (should (< (length diffs--split-rows) expected-count))
          (let* ((estimated-count (length diffs--split-rows))
                 (deep-index (- estimated-count 2))
                 (window (get-buffer-window new-buffer)))
            (set-window-start
             window (diffs--split-row-position deep-index))
            (diffs--split-materialize-window window)
            (should (= (length diffs--split-rows) expected-count))
            (should
             (equal
              (diffs--split-row-source-file
               (diffs--split-row-at-position
                (window-start window)))
              "unequal.el"))
            (goto-char (point-min))
            (should (search-forward "new combined" nil t))
            (beginning-of-line)
            (let ((copy
                   (filter-buffer-substring
                    (point-min) (point-max) nil)))
              (should (equal (substring-no-properties copy) expected-new))
              (should (looking-at "new combined")))
            (with-current-buffer old-buffer
              (should (= (length diffs--split-rows) expected-count))
              (should
               (equal
                (buffer-substring-no-properties
                 (point-min) (point-max))
                expected-old)))))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate)))))

(ert-deftest diffs-paged-full-materialization-rolls-back-pinned-state ()
  (let ((buffer
         (generate-new-buffer " *diffs paged rollback test*"))
        (diffs-split-virtualization 'paged)
        (diffs-split-overscan 0)
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert (diffs-tests--many-file-patch 30))
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (let* ((target-index
                  (cl-position
                   nil diffs--split-materialized-chunks
                   :from-end t))
                 (target
                  (aref diffs--split-chunks target-index))
                 (old-function
                  (symbol-function
                   'diffs--split-paged-chunk-rows))
                 (new-range diffs--split-paged-retained-range)
                 (old-range
                  (buffer-local-value
                   'diffs--split-paged-retained-range old-buffer))
                 (new-text (buffer-string))
                 (old-text
                  (with-current-buffer old-buffer
                    (buffer-string))))
            (cl-letf
                (((symbol-function
                   'diffs--split-paged-chunk-rows)
                  (lambda (chunk)
                    (if (eq chunk target)
                        (error "Synthetic paged materialization failure")
                      (funcall old-function chunk)))))
              (should-error
               (diffs--split-paged-materialize-all)
               :type 'error))
            (should-not diffs--split-paged-pinned)
            (should (equal diffs--split-paged-retained-range new-range))
            (should (equal (buffer-string) new-text))
            (with-current-buffer old-buffer
              (should-not diffs--split-paged-pinned)
              (should (equal diffs--split-paged-retained-range old-range))
              (should (equal (buffer-string) old-text)))
            (should
             (equal
              (append diffs--split-materialized-chunks nil)
              (append
               (buffer-local-value
                'diffs--split-materialized-chunks old-buffer)
               nil)))
            (dolist (candidate (list new-buffer old-buffer))
              (with-current-buffer candidate
                (should
                 (equal
                  (sort
                   (copy-sequence
                    diffs--split-materialized-indexes)
                   #'<)
                  (cl-loop
                   for flag across diffs--split-materialized-chunks
                   for index from 0
                   when flag collect index))))))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-split-auto-selects-model-at-row-threshold ()
  (let ((buffer
         (generate-new-buffer " *diffs automatic split test*"))
        (diffs-split-virtualization 'auto)
        (diffs-split-virtualization-threshold most-positive-fixnum)
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert (diffs-tests--many-file-patch 30))
          (diff-mode)
          (diffs-minor-mode 1)
          (let ((estimate (diffs--split-estimated-row-count)))
            (should (> estimate 0))
            (setq diffs-split-virtualization-threshold
                  (1+ estimate))
            (diffs-toggle-split)
            (setq new-buffer (current-buffer)
                  old-buffer diffs--split-other)
            (should-not diffs--split-paged-p)
            (should-not
             (buffer-local-value
              'diffs--split-paged-p old-buffer))
            (diffs-split-quit)
            (with-current-buffer buffer
              (setq diffs-split-virtualization-threshold
                    estimate)
              (diffs-toggle-split))
            (set-buffer new-buffer)
            (should diffs--split-paged-p)
            (should
             (buffer-local-value
              'diffs--split-paged-p old-buffer))
            (should (eq diffs-split-virtualization 'auto)))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-complex-change-selects-lazy-stacked-rendering ()
  (let ((diffs-lazy-threshold 50))
    (diffs-tests--with-diff diffs-tests--complex-replacement
      (font-lock-mode -1)
      (diffs-minor-mode 1)
      (should (< (count-lines (point-min) (point-max))
                 diffs-lazy-threshold))
      (should (>= (diffs--estimated-change-work)
                  diffs-lazy-threshold))
      (should (memq #'diffs--jit-decorate jit-lock-functions))
      (diffs-minor-mode -1)))
  (let ((diffs-lazy-threshold most-positive-fixnum))
    (diffs-tests--with-diff diffs-tests--complex-replacement
      (font-lock-mode -1)
      (diffs-minor-mode 1)
      (should-not (memq #'diffs--jit-decorate jit-lock-functions))
      (diffs-minor-mode -1)))
  (diffs-tests--with-diff diffs-tests--normal
    (let ((diffs-lazy-threshold
           (count-lines (point-min) (point-max)))
          (diffs-line-diff-type 'none))
      (font-lock-mode -1)
      (diffs-minor-mode 1)
      (should (memq #'diffs--jit-decorate jit-lock-functions))
      (diffs-minor-mode -1))))

(ert-deftest diffs-scan-change-work-keeps-replacement-boundaries ()
  (let* ((old (make-string 80 ?o))
         (new (make-string 80 ?n))
         (patch
          (concat
           "diff --git a/work.el b/work.el\n"
           "--- a/work.el\n"
           "+++ b/work.el\n"
           "@@ -1,3 +1,3 @@\n"
           "-" old "\n+" new "\n"
           " context\n"
           "-" old "\n+" new "\n")))
    (diffs-tests--with-diff patch
      (diffs--scan)
      (should (= (plist-get (car diffs--sections) :adds) 2))
      (should (= (plist-get (car diffs--sections) :dels) 2))
      ;; Each 80-by-80 replacement costs one unit.  Context must keep
      ;; the two blocks separate; treating the hunk as one block costs 4.
      (should (= (diffs--estimated-change-work) 2))))
  (let* ((old (make-string 80 ?o))
         (new (make-string 80 ?n))
         (patch
          (concat
           "diff --git a/eof.el b/eof.el\n"
           "--- a/eof.el\n"
           "+++ b/eof.el\n"
           "@@ -1 +1 @@\n"
           "-" old "\n"
           "\\ No newline at end of file\n"
           "+" new "\n"
           "\\ No newline at end of file\n")))
    (diffs-tests--with-diff patch
      (diffs--scan)
      ;; The marker belongs to the adjacent replacement and must not turn
      ;; it into unrelated pure deletion/addition blocks with zero work.
      (should (= (diffs--estimated-change-work) 1)))))

(ert-deftest diffs-split-auto-selects-paged-for-complex-change ()
  (let ((buffer
         (generate-new-buffer " *diffs complex split test*"))
        (diffs-split-virtualization 'auto)
        (diffs-split-virtualization-threshold 50)
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert diffs-tests--complex-replacement)
          (diff-mode)
          (diffs-minor-mode 1)
          (should (< (diffs--split-estimated-row-count)
                     diffs-split-virtualization-threshold))
          (should (>= (diffs--estimated-change-work)
                      diffs-split-virtualization-threshold))
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (should diffs--split-paged-p)
          (should
           (buffer-local-value 'diffs--split-paged-p old-buffer))
          (diffs-split-quit)
          (with-current-buffer buffer
            (let ((diffs-split-virtualization 'complete))
              (diffs-toggle-split)))
          (should-not diffs--split-paged-p)
          (should-not
           (buffer-local-value 'diffs--split-paged-p old-buffer))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-split-auto-respects-ineligible-view-state ()
  (let ((diffs-split-virtualization-threshold 0))
    (diffs-tests--with-diff diffs-tests--normal
      (diffs-minor-mode 1)
      (should
       (diffs--split-use-paged-p
        'auto nil diffs-split-virtualization-threshold))
      (should-not
       (diffs--split-use-paged-p
        'complete nil diffs-split-virtualization-threshold))
      (should
       (diffs--split-use-paged-p
        'paged nil most-positive-fixnum))
      (should-not
       (diffs--split-use-paged-p
        'auto t diffs-split-virtualization-threshold))
      (let ((diffs--review-selection '(selection)))
        (should-not
         (diffs--split-use-paged-p
          'auto nil diffs-split-virtualization-threshold)))
      (let ((diffs--review-annotations '(annotation)))
        (should-not
         (diffs--split-use-paged-p
          'auto nil diffs-split-virtualization-threshold)))
      (let ((diffs--review-decisions '(decision)))
        (should-not
         (diffs--split-use-paged-p
          'auto nil diffs-split-virtualization-threshold)))
      (let ((diffs--review-source-actions '(action)))
        (should-not
         (diffs--split-use-paged-p
          'auto nil diffs-split-virtualization-threshold)))
      (diffs-minor-mode -1))))

(ert-deftest diffs-paged-index-matches-complete-physical-row-count ()
  (dolist (patch
           (list diffs-tests--normal
                 diffs-tests--rename
                 diffs-tests--two-files
                 diffs-tests--hidden-context
                 diffs-tests--two-change-blocks
                 diffs-tests--context-zero-deletion
                 diffs-tests--zero-count-addition))
    (with-temp-buffer
      (insert patch)
      (diff-mode)
      (diffs-minor-mode 1)
      (pcase-let* ((`(,old ,new . ,_) (diffs--split-collect))
                    (`(,old-physical ,new-physical . ,_)
                     (diffs--split-physical-rows old new 80 nil))
                    (`(,_chunks ,_anchors ,count)
                     (diffs--split-paged-index)))
        (should (= (length old-physical) (length new-physical)))
        (should (= count (length old-physical))))
      (diffs-minor-mode -1))))

(ert-deftest diffs-large-stacked-rendering-stays-lazy-without-font-lock ()
  (let ((diffs-lazy-threshold 1))
    (diffs-tests--with-diff diffs-tests--normal
      (font-lock-mode -1)
      (diffs-minor-mode 1)
      (should-not font-lock-mode)
      (should (memq #'diffs--jit-decorate jit-lock-functions))
      (goto-char (point-min))
      (re-search-forward "(message \"same\")")
      (let ((begin (line-beginning-position))
            (end (min (point-max) (1+ (line-end-position)))))
        (should-not (get-text-property begin 'diffs-kind))
        (diffs--jit-decorate begin end)
        (should (eq (get-text-property begin 'diffs-kind) 'ctx)))
      (diffs-minor-mode -1))))

(ert-deftest diffs-minor-mode-restores-emacs-refinement-setting ()
  (let ((diff-refine 'navigation))
    (diffs-tests--with-diff diffs-tests--normal
      (diffs-minor-mode 1)
      (should-not diff-refine)
      (should
       (cl-some (lambda (overlay)
                  (overlay-get overlay 'diffs-intraline))
                (overlays-in (point-min) (point-max))))
      (diffs-minor-mode -1)
      (should (eq diff-refine 'navigation))
      (should-not
       (cl-some (lambda (overlay)
                  (overlay-get overlay 'diffs-intraline))
                (overlays-in (point-min) (point-max)))))))

(ert-deftest diffs-minor-mode-restores-external-buffer-state ()
  (diffs-tests--with-diff diffs-tests--normal
    (outline-minor-mode 1)
    (setq-local header-line-format '("External header"))
    (setq-local diff-refine 'navigation)
    (setq-local diff-font-lock-syntax t)
    (setq-local font-lock-extra-managed-props
                '(face display diffs-tests-property))
    (setq-local imenu-create-index-function #'ignore)
    (setq-local outline-minor-mode-cycle 'external-cycle)
    (setq-local outline-minor-mode-highlight 'external-highlight)
    (let ((prettify-local
           (local-variable-p 'diff-font-lock-prettify)))
      (diffs-minor-mode 1)
      (should (bound-and-true-p outline-minor-mode))
      (should-not header-line-format)
      (should-not diff-refine)
      (should (eq diff-font-lock-syntax 'hunk-also))
      (should
       (eq imenu-create-index-function #'diffs--imenu-create-index))
      (should-not
       (memq 'display font-lock-extra-managed-props))
      (diffs-minor-mode 1)
      (diffs-minor-mode -1)
      (should (bound-and-true-p outline-minor-mode))
      (should (equal header-line-format '("External header")))
      (should (eq diff-refine 'navigation))
      (should (eq diff-font-lock-syntax t))
      (should
       (equal font-lock-extra-managed-props
              '(face display diffs-tests-property)))
      (should (eq imenu-create-index-function #'ignore))
      (should (eq outline-minor-mode-cycle 'external-cycle))
      (should
       (eq outline-minor-mode-highlight 'external-highlight))
      (should
       (eq (local-variable-p 'diff-font-lock-prettify)
           prettify-local)))
    (outline-minor-mode -1)))

(ert-deftest diffs-expanded-context-keeps-source-syntax-faces ()
  (let* ((result
          (diffs--fontified-lines-result
           "(defun highlighted-function ()\n  (message \"hello\"))\n"
           "sample.el"))
         (lines (car result))
         (source (aref lines 0))
         (context (diffs--context-text source)))
    (should (cdr result))
    (should (eq (get-text-property 1 'face source)
                'font-lock-keyword-face))
    (let ((faces (get-text-property 1 'face context)))
      (should (diffs-tests--face-includes-p
               faces 'font-lock-keyword-face))
      (should (diffs-tests--face-includes-p faces 'diff-context)))))

(ert-deftest diffs-source-fontification-sanitizes-its-temp-buffer ()
  (let ((original-kill-buffer (symbol-function 'kill-buffer))
        cleanup-state
        seen-file)
    (cl-letf
        (((symbol-function 'set-auto-mode)
          (lambda (&rest _)
            (setq seen-file buffer-file-name
                  buffer-offer-save t)
            (setq-local diffs-tests--synthetic-source t)
            (setq-local kill-buffer-query-functions '(ignore))
            (set-buffer-modified-p t)))
         ((symbol-function 'kill-buffer)
          (lambda (&optional buffer-or-name)
            (let ((target
                   (if (bufferp buffer-or-name)
                       buffer-or-name
                     (get-buffer (or buffer-or-name (current-buffer))))))
              (when (and target
                         (with-current-buffer target
                           (bound-and-true-p
                            diffs-tests--synthetic-source)))
                (with-current-buffer target
                  (setq cleanup-state
                        (list buffer-file-name
                              buffer-offer-save
                              (buffer-modified-p)
                              kill-buffer-query-functions))))
              (funcall original-kill-buffer buffer-or-name)))))
      (let ((result
             (diffs--fontified-lines-result
              "const answer = 42;\n" "sample.internal")))
        (should (cdr result))
        (should (equal (car result) ["const answer = 42;"]))))
    (should (equal (file-name-nondirectory seen-file) "sample.internal"))
    (should (equal cleanup-state '(nil nil nil nil)))))

(ert-deftest diffs-source-fontification-sanitizes-temp-buffer-on-error ()
  (let ((original-kill-buffer (symbol-function 'kill-buffer))
        cleanup-state)
    (cl-letf
        (((symbol-function 'set-auto-mode)
          (lambda (&rest _)
            (setq buffer-offer-save t)
            (setq-local diffs-tests--synthetic-source t)
            (setq-local kill-buffer-query-functions '(ignore))
            (set-buffer-modified-p t)
            (error "Synthetic source-mode failure")))
         ((symbol-function 'kill-buffer)
          (lambda (&optional buffer-or-name)
            (let ((target
                   (if (bufferp buffer-or-name)
                       buffer-or-name
                     (get-buffer (or buffer-or-name (current-buffer))))))
              (when (and target
                         (with-current-buffer target
                           (bound-and-true-p
                            diffs-tests--synthetic-source)))
                (with-current-buffer target
                  (setq cleanup-state
                        (list buffer-file-name
                              buffer-offer-save
                              (buffer-modified-p)
                              kill-buffer-query-functions))))
              (funcall original-kill-buffer buffer-or-name)))))
      (let ((result
             (diffs--fontified-lines-result
              "plain source\n" "sample.fail")))
        (should-not (cdr result))
        (should (equal (car result) ["plain source"]))))
    (should (equal cleanup-state '(nil nil nil nil)))))

(ert-deftest diffs-source-syntax-renders-from-the-idle-queue ()
  (let ((diffs--render-cache (make-hash-table :test #'equal))
        (diffs--render-cache-order nil)
        (diffs--render-jobs (make-hash-table :test #'equal))
        (diffs--render-queue nil)
        (diffs--render-idle-timer nil)
        scheduled)
    (diffs-tests--with-diff diffs-tests--normal
      (diffs--scan)
      (setq diffs--revision "HEAD")
      (let ((section (car diffs--sections))
            (raw ["(defun cached-source () nil)"]))
        (cl-letf
            (((symbol-function 'diffs--revision-lines)
              (lambda (_file _revision) raw))
             ((symbol-function 'run-with-idle-timer)
              (lambda (_seconds _repeat function &rest arguments)
                (setq scheduled (cons function arguments))
                'diffs-tests-idle-timer)))
          (let ((immediate (diffs--section-lines section 'old)))
            (should (eq immediate raw))
            (should-not
             (get-text-property 1 'face (aref immediate 0)))
            (should scheduled)
            (apply (car scheduled) (cdr scheduled))
            (let ((rendered
                   (gethash section diffs--old-content-cache)))
              (should (vectorp rendered))
              (should-not (eq rendered raw))
              (should
               (diffs-tests--face-includes-p
                (get-text-property 1 'face (aref rendered 0))
                'font-lock-keyword-face))
              (should (eq (diffs--section-lines section 'old)
                          rendered)))))))))

(ert-deftest diffs-context-expansion-repaints-after-source-render ()
  (let ((diffs--render-cache (make-hash-table :test #'equal))
        (diffs--render-cache-order nil)
        (diffs--render-jobs (make-hash-table :test #'equal))
        (diffs--render-queue nil)
        (diffs--render-idle-timer nil)
        scheduled)
    (diffs-tests--with-diff diffs-tests--hidden-context
      (diffs-minor-mode 1)
      (setq diffs--revision "HEAD")
      (let* ((section (car diffs--sections))
             (gap (car diffs--context-gaps))
             (raw ["(message \"one\")"
                   "(message \"two\")"
                   "(defun context-three () nil)"
                   "(setq context-four t)"
                   "new five"]))
        (cl-letf
            (((symbol-function 'diffs--revision-lines)
              (lambda (_file _revision) raw))
             ((symbol-function 'diffs--worktree-lines)
              (lambda (_file) raw))
             ((symbol-function 'run-with-idle-timer)
              (lambda (_seconds _repeat function &rest arguments)
                (setq scheduled (cons function arguments))
                'diffs-tests-idle-timer)))
          (diffs--set-context-visible gap 2)
          (let* ((before
                  (overlay-get
                   (plist-get gap :overlay) 'before-string))
                 (keyword (string-match "defun" before)))
            (should keyword)
            (should-not
             (diffs-tests--face-includes-p
              (get-text-property keyword 'face before)
              'font-lock-keyword-face)))
          (should scheduled)
          (apply (car scheduled) (cdr scheduled))
          (let* ((after
                  (overlay-get
                   (plist-get gap :overlay) 'before-string))
                 (keyword (string-match "defun" after)))
            (should keyword)
            (should
             (diffs-tests--face-includes-p
              (get-text-property keyword 'face after)
              'font-lock-keyword-face))))
        (diffs-minor-mode -1)))))

(ert-deftest diffs-source-render-publishes-into-read-only-split ()
  (let ((diffs--render-cache (make-hash-table :test #'equal))
        (diffs--render-cache-order nil)
        (diffs--render-jobs (make-hash-table :test #'equal))
        (diffs--render-queue nil)
        (diffs--render-idle-timer nil)
        (owner (generate-new-buffer " *diffs async split test*"))
        scheduled)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer owner)
          (insert diffs-tests--hidden-context)
          (diff-mode)
          (cl-letf
              (((symbol-function 'diffs--revision-lines)
                (lambda (_file _revision)
                  ["(message \"one\")"
                   "(message \"two\")"
                   "(defun context-three () nil)"
                   "(setq context-four t)"
                   "old five"]))
               ((symbol-function 'diffs--worktree-lines)
                (lambda (_file)
                  ["(message \"one\")"
                   "(message \"two\")"
                   "(defun context-three () nil)"
                   "(setq context-four t)"
                   "new five"]))
               ((symbol-function 'run-with-idle-timer)
                (lambda (_seconds _repeat function &rest arguments)
                  (setq scheduled (cons function arguments))
                  'diffs-tests-idle-timer)))
            (diffs-minor-mode 1)
            (setq diffs--revision "HEAD")
            (diffs--set-context-visible
             (car diffs--context-gaps) 2)
            (setq buffer-read-only t)
            (diffs-toggle-split)
            (let ((new (current-buffer))
                  (old diffs--split-other)
                  modified-states)
              (dolist (buffer (list old new))
                (with-current-buffer buffer
                  (should buffer-read-only)
                  (push
                   (cons buffer (buffer-modified-p))
                   modified-states)))
              (while scheduled
                (let ((callback scheduled))
                  (setq scheduled nil)
                  (apply (car callback) (cdr callback))))
              (dolist (buffer (list old new))
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (search-forward "defun")
                  (should
                   (diffs-tests--face-includes-p
                    (get-text-property
                     (match-beginning 0) 'face)
                    'font-lock-keyword-face))
                  (should buffer-read-only)
                  (should
                   (eq (buffer-modified-p)
                       (cdr (assq buffer modified-states)))))))))
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (diffs--split-cache-clear)
          (when diffs-minor-mode
            (diffs-minor-mode -1))
          (setq buffer-read-only nil))
        (kill-buffer owner)))))

(ert-deftest diffs-source-render-failure-does-not-poison-cache ()
  (let* ((diffs--render-cache (make-hash-table :test #'equal))
         (diffs--render-cache-order nil)
         (diffs--render-jobs (make-hash-table :test #'equal))
         (diffs--render-idle-timer nil)
         (key '(:render failed)))
    (puthash
     key
     (list :text "(defun retry-after-failure () nil)"
           :file "sample.fail"
           :waiters nil)
     diffs--render-jobs)
    (let ((diffs--render-queue (list key)))
      (cl-letf (((symbol-function 'set-auto-mode)
                 (lambda (&rest _)
                   (error "Synthetic mode failure"))))
        (diffs--render-run-next)))
    (should-not (gethash key diffs--render-cache))
    (should-not (member key diffs--render-cache-order))))

(ert-deftest diffs-source-lines-retry-a-stale-raw-render ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs--scan)
    (let* ((section (car diffs--sections))
           (raw ["(defun stale-source () nil)"])
           scheduled)
      (puthash section raw diffs--old-raw-content-cache)
      (puthash section raw diffs--old-content-cache)
      (diffs--set-source-render-identity
       section 'old '(:renderer 0))
      (cl-letf (((symbol-function 'diffs--schedule-source-render)
                 (lambda (candidate side lines)
                   (setq scheduled (list candidate side lines))
                   nil)))
        (should (eq (diffs--section-lines section 'old) raw)))
      (should (equal scheduled (list section 'old raw))))))

(ert-deftest diffs-source-render-cache-keys-all-render-inputs ()
  (let ((diffs--render-theme-generation 7)
        (root "/tmp/repository/")
        (lines ["(defun key-test () nil)"]))
    (let ((base
           (diffs--source-render-key
            root "sample.el" 'old "rev-a" lines 'emacs-lisp-mode)))
      (should
       (= (plist-get base :renderer)
          diffs--source-render-version))
      (should
       (equal
        base
        (diffs--source-render-key
         root "sample.el" 'old "rev-a" lines 'emacs-lisp-mode)))
      (should-not
       (equal
        base
        (diffs--source-render-key
         root "sample.el" 'old "rev-b" lines 'emacs-lisp-mode)))
      (should-not
       (equal
        base
        (diffs--source-render-key
         root "sample.el" 'old "rev-a" lines 'fundamental-mode)))
      (let ((diffs--render-theme-generation 8))
        (should-not
         (equal
          base
          (diffs--source-render-key
           root "sample.el" 'old "rev-a" lines
           'emacs-lisp-mode))))
      (should-not
       (equal
        base
       (diffs--source-render-key
         root "sample.el" 'old "rev-a"
         ["(defun changed-content () nil)"]
         'emacs-lisp-mode)))))
  (let ((diffs-render-cache-limit 0)
        (diffs--render-cache (make-hash-table :test #'equal))
        (diffs--render-cache-order '((old-key))))
    (puthash '(old-key) ["old"] diffs--render-cache)
    (should-not (diffs--render-cache-get '(old-key)))
    (should (zerop (hash-table-count diffs--render-cache)))
    (should-not diffs--render-cache-order)
    (diffs--render-cache-put '(new-key) ["new"])
    (should (zerop (hash-table-count diffs--render-cache)))))

(ert-deftest diffs-theme-change-invalidates-render-not-raw-source ()
  (let ((diffs--render-cache (make-hash-table :test #'equal))
        (diffs--render-cache-order nil)
        (diffs--render-theme-generation 4))
    (puthash '(render-key) ["rendered"] diffs--render-cache)
    (setq diffs--render-cache-order '((render-key)))
    (diffs--render-theme-changed)
    (should (= diffs--render-theme-generation 5))
    (should (= (hash-table-count diffs--render-cache) 0))
    (should-not diffs--render-cache-order))
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (let (refreshed)
      (cl-letf (((symbol-function 'diffs--review-refresh-overlays)
                 (lambda (owner &optional _views)
                   (push owner refreshed))))
        (diffs--render-theme-changed))
      (should (memq (current-buffer) refreshed)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-mixed-items-share-one-searchable-owner-model ()
  (let ((diffs-default-view 'stacked)
        (diffs-fullscreen nil)
        (buffer-name
         (generate-new-buffer-name " *diffs mixed items test*"))
        owner)
    (unwind-protect
        (save-window-excursion
          (setq owner
                (diffs-items
                 (list
                  (list :type 'file
                        :id "guide"
                        :file "guide.el"
                        :version "worktree-7"
                        :content
                        "(defun guide-entry () t)\n(message \"guide\")\n")
                  (list :type 'diff
                        :id "change"
                        :patch diffs-tests--normal))
                 (list :directory default-directory
                       :buffer-name buffer-name)))
          (with-current-buffer owner
            (should (equal (buffer-name) buffer-name))
            (should (= (length diffs--sections) 2))
            (should
             (equal
              (mapcar
               (lambda (section)
                 (list (plist-get section :item-type)
                       (plist-get section :item-id)))
               diffs--sections)
              '((file "guide") (diff "change"))))
            (goto-char (point-min))
            (should (search-forward "guide-entry" nil t))
            (goto-char (1- (plist-get (car diffs--sections) :end)))
            (diff-file-next)
            (should
             (eq (diffs--section-at-pos (point))
                 (cadr diffs--sections)))
            (let* ((file-section (car diffs--sections))
                   (lines
                    (diffs--section-raw-lines
                     file-section 'new)))
              (should
               (equal lines
                      ["(defun guide-entry () t)"
                       "(message \"guide\")"])))
            (pcase-let ((`(,old ,new . ,_)
                         (diffs--split-collect)))
              (should
               (cl-some
                (lambda (row)
                  (string-match-p "guide-entry" (car row)))
                old))
              (should
               (cl-some
                (lambda (row)
                  (string-match-p "guide-entry" (car row)))
                new)))
            (diffs-refresh)
            (should (equal (buffer-name) buffer-name))
            (should
             (equal
              (mapcar
               (lambda (section)
                 (list (plist-get section :item-type)
                       (plist-get section :item-id)))
               diffs--sections)
              '((file "guide") (diff "change"))))))
      (when (buffer-live-p owner)
        (with-current-buffer owner
          (diffs--split-cache-clear)
          (when diffs-minor-mode
            (diffs-minor-mode -1)))
        (kill-buffer owner)))))

(ert-deftest diffs-imenu-indexes-stacked-files-and-hunks ()
  (diffs-tests--with-diff diffs-tests--two-files
    (diffs-minor-mode 1)
    (should
     (eq imenu-create-index-function #'diffs--imenu-create-index))
    (let* ((index (funcall imenu-create-index-function))
           (bar (assoc "bar.el" index))
           (entries (cdr bar))
           (hunk-item (cadr entries))
           (section (cadr diffs--sections))
           (hunk (car (plist-get section :hunks))))
      (should (equal (mapcar #'car index) '("foo.el" "bar.el")))
      (should (equal (caar entries) "File"))
      (should
       (string-match-p
        (regexp-quote "Hunk 1 · -10 +10 · bar-function")
        (car hunk-item)))
      (goto-char (point-min))
      (imenu hunk-item)
      (should (eq (diffs--section-at-pos (point)) section))
      (should (= (point) (car hunk))))
    (diffs-minor-mode -1)))

(ert-deftest diffs-imenu-keeps-duplicate-mixed-items-exact-in-split ()
  (dolist (virtualization '(complete paged))
    (let ((diffs-default-view 'stacked)
          (diffs-fullscreen nil)
          (diffs-split-virtualization virtualization)
          (buffer-name
           (generate-new-buffer-name
            " *diffs duplicate imenu test*"))
          owner split-buffer)
      (unwind-protect
          (save-window-excursion
            (setq owner
                  (diffs-items
                   (list
                    (list :type 'diff :id "first"
                          :patch diffs-tests--normal)
                    (list :type 'diff :id "second"
                          :patch diffs-tests--normal))
                   (list :directory default-directory
                         :buffer-name buffer-name)))
            (setq split-buffer
                  (with-current-buffer owner
                    (diffs-toggle-split)
                    (current-buffer)))
            (set-buffer split-buffer)
            (let* ((index (funcall imenu-create-index-function))
                   (first (assoc "foo.el [first]" index))
                   (second (assoc "foo.el [second]" index))
                   (stale-file-item (car (cdr first)))
                   (file-item (car (cdr second)))
                   (hunk-item (cadr (cdr second))))
              (should first)
              (should second)
              (should
               (eq imenu-create-index-function
                   #'diffs--imenu-create-index))
              (imenu file-item)
              (should (derived-mode-p 'diffs-split-mode))
              (should
               (equal
                (plist-get
                 (diffs--split-section-at-position (point))
                 :item-id)
                "second"))
              (imenu hunk-item)
              (should
               (equal
                (plist-get
                 (diffs--split-section-at-position (point))
                 :item-id)
                "second"))
              (should
               (eq
                (nth 5 (diffs--split-row-at-position (point)))
                (car
                 (plist-get
                  (cadr
                   (buffer-local-value
                    'diffs--sections owner))
                  :hunks))))
              (let ((sections
                     (buffer-local-value 'diffs--sections owner)))
                (unwind-protect
                    (progn
                      (with-current-buffer owner
                        (setq diffs--sections (cdr sections)))
                      (should-error
                       (imenu stale-file-item) :type 'user-error))
                  (with-current-buffer owner
                    (setq diffs--sections sections)))))
            (diffs-split-quit))
        (when (buffer-live-p owner)
          (with-current-buffer owner
            (diffs--split-cache-clear)
            (when diffs-minor-mode
              (diffs-minor-mode -1)))
          (kill-buffer owner))))))

(ert-deftest diffs-imenu-stale-hunks-do-not-fall-through-by-ordinal ()
  (diffs-tests--with-diff diffs-tests--directional-context
    (diffs-minor-mode 1)
    (let* ((section (car diffs--sections))
           (hunks (plist-get section :hunks))
           (first-hunk-item
            (cadr (cdar (funcall imenu-create-index-function)))))
      (unwind-protect
          (progn
            (setf (plist-get section :hunks) (cdr hunks))
            (should-error
             (imenu first-hunk-item) :type 'user-error))
        (setf (plist-get section :hunks) hunks)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-token-coordinates-cover-unicode-and-whitespace ()
  (let ((patch
         (concat
          "diff --git a/unicode.ts b/unicode.ts\n"
          "--- a/unicode.ts\n"
          "+++ b/unicode.ts\n"
          "@@ -4 +4 @@\n"
          "-const title = \"旧值\";\n"
          "+const title = \"新值🙂\";\n")))
    (diffs-tests--with-diff patch
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (search-forward "新值")
      (backward-char 1)
      (let ((token (diffs-token-at-point)))
        (should (equal (plist-get token :text) "值"))
        (should (= (plist-get token :line) 4))
        (should (= (plist-get token :start-column)
                   (string-match "值" "const title = \"新值🙂\";")))
        (should (= (plist-get token :end-column)
                   (1+ (plist-get token :start-column)))))
      (goto-char (point-min))
      (search-forward "+const")
      (should-not (diffs-token-at-point))
      (setq-local diffs-token-interactions-on-whitespace t)
      (let ((token (diffs-token-at-point)))
        (should (equal (plist-get token :text) " "))
        (should (= (plist-get token :column) 5)))
      (diffs-minor-mode -1))))

(ert-deftest diffs-public-layout-functions-cover-stacked-and-split ()
  (let (header-contexts gutter-contexts separator-contexts)
    (let ((diffs-file-header-function
           (lambda (context)
             (push context header-contexts)
             (format "HEADER:%s:%s"
                     (plist-get context :view)
                     (plist-get context :file))))
          (diffs-gutter-function
           (lambda (context)
             (push context gutter-contexts)
             (format "G:%s:%s:%s "
                     (plist-get context :view)
                     (or (plist-get context :old-line) "-")
                     (or (plist-get context :new-line) "-"))))
          (diffs-hunk-separator-function
           (lambda (context)
             (push context separator-contexts)
             (format "SEP:%s" (plist-get context :view)))))
      (diffs-tests--with-diff diffs-tests--normal
        (diffs-minor-mode 1)
        (let* ((section (car diffs--sections))
               (hunk (car (plist-get section :hunks))))
          (goto-char (plist-get section :beg))
          (should
           (string-match-p
            "HEADER:stacked:foo.el"
            (get-text-property (point) 'display)))
          (goto-char (car hunk))
          (should
           (equal (get-text-property (point) 'display)
                  "SEP:stacked"))
          (forward-line 1)
          (should
           (string-match-p
            "G:stacked:"
            (get-text-property (point) 'line-prefix)))
          (pcase-let ((`(,old ,_new . ,_)
                       (diffs--split-collect)))
            (should
             (string-match-p "HEADER:split:foo.el"
                             (caar old)))
            (should
             (string-match-p "SEP:split"
                             (car (nth 1 old))))))
        (diffs-minor-mode -1)))
    (should
     (cl-some
      (lambda (context)
        (eq (plist-get context :view) 'stacked))
      header-contexts))
    (should
     (cl-some
      (lambda (context)
        (eq (plist-get context :view) 'split))
      separator-contexts))
    (should
     (cl-some
      (lambda (context)
        (and (eq (plist-get context :view) 'stacked)
             (eq (plist-get context :kind) 'ctx)))
      gutter-contexts))))

(ert-deftest diffs-token-coordinates-cover-stacked-old-and-new-lines ()
  (let ((patch
         (concat
          "diff --git a/token.ts b/token.ts\n"
          "--- a/token.ts\n"
          "+++ b/token.ts\n"
          "@@ -7 +7 @@\n"
          "-const displayName = oldValue;\n"
          "+const displayName = newValue;\n")))
    (diffs-tests--with-diff patch
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (search-forward "oldValue")
      (backward-char 2)
      (let ((token (diffs-token-at-point)))
        (should (equal (plist-get token :file) "token.ts"))
        (should (eq (plist-get token :side) 'old))
        (should (= (plist-get token :line) 7))
        (should (= (plist-get token :column) 26))
        (should (= (plist-get token :start-column) 20))
        (should (= (plist-get token :end-column) 28))
        (should (equal (plist-get token :text) "oldValue")))
      (goto-char (point-min))
      (search-forward "newValue")
      (backward-char 4)
      (let ((token (diffs-token-at-point)))
        (should (eq (plist-get token :side) 'new))
        (should (= (plist-get token :line) 7))
        (should (equal (plist-get token :text) "newValue")))
      (diffs-minor-mode -1))))

(ert-deftest diffs-token-coordinates-preserve-wrapped-split-columns ()
  (let* ((prefix (make-string 90 ?x))
         (new-line (concat "const " prefix " targetToken = 2;"))
         (patch
          (concat
           "diff --git a/token.ts b/token.ts\n"
           "--- a/token.ts\n"
           "+++ b/token.ts\n"
           "@@ -3 +3 @@\n"
           "-const oldToken = 1;\n"
           "+" new-line "\n"))
         (buffer (generate-new-buffer " *diffs token split test*"))
         (diffs-split-wrap-lines t)
         old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert patch)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (goto-char (point-min))
          (search-forward "targetToken")
          (backward-char 5)
          (let ((token (diffs-token-at-point)))
            (should (eq (plist-get token :side) 'new))
            (should (= (plist-get token :line) 3))
            (should (= (plist-get token :column)
                       (+ (string-match "targetToken" new-line) 6)))
            (should (equal (plist-get token :text) "targetToken"))))
      (dolist (item (list old-buffer new-buffer buffer))
        (when (buffer-live-p item)
          (kill-buffer item))))))

(ert-deftest diffs-token-language-hooks-delegate-to-the-source-buffer ()
  (let* ((directory (make-temp-file "diffs-token-source-" t))
         (file (expand-file-name "foo.el" directory))
         source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(message \"same\")\n"
                    "(message \"new\")\n"
                    "(message \"extra\")\n"))
          (setq source-buffer (find-file-noselect file))
          (with-current-buffer source-buffer
            (emacs-lisp-mode)
            (setq-local eldoc-documentation-functions
                        (list
                         (lambda (_callback)
                           (format "source:%s:%d"
                                   (thing-at-point 'symbol t)
                                   (line-number-at-pos)))))
            (setq-local xref-backend-functions
                        (list (lambda () 'diffs-tests))))
          (diffs-tests--with-diff diffs-tests--normal
            (setq default-directory directory)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (search-forward "\"new\"")
            (backward-char 3)
            (let* ((token (diffs-token-at-point))
                   (source (diffs-token-source-position token)))
              (should (eq (car source) source-buffer))
              (with-current-buffer (car source)
                (should (= (line-number-at-pos (cdr source)) 2))
                (should (= (save-excursion
                             (goto-char (cdr source))
                             (current-column))
                           (plist-get token :column)))))
            (should (equal (diffs-eldoc-function #'ignore)
                           "source:new:2"))
            (should (eq (diffs-xref-backend) 'diffs))
            (let* ((identifier
                    (xref-backend-identifier-at-point 'diffs))
                   (definitions
                    (xref-backend-definitions 'diffs identifier))
                   (location (xref-item-location (car definitions))))
              (should (equal identifier "new"))
              (should (eq (xref-buffer-location-buffer location)
                          source-buffer)))
            (diffs-minor-mode -1)))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-scan-counts-files-and-lines ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs--scan)
    (should (equal diffs--stats '(1 2 1)))
    (should (equal (plist-get (car diffs--sections) :file) "foo.el"))
    (let* ((section (car diffs--sections))
           (hunks (plist-get section :hunks)))
      (should (= (length hunks) 1))
      (should (= (nth 3 (car hunks)) (plist-get section :end)))
      (should (equal (nth 4 (car hunks)) ""))
      (should (= (nth 5 (car hunks)) 2))
      (should (= (nth 6 (car hunks)) 3)))))

(ert-deftest diffs-context-expansion-preserves-patch-and-feeds-split ()
  (diffs-tests--with-diff diffs-tests--hidden-context
    (diffs--scan)
    (let* ((text (buffer-string))
           (section (car diffs--sections))
           (hunk (car (plist-get section :hunks)))
           (gap (diffs--gap-for-hunk hunk))
           (old-lines ["old one" "old two" "old three" "old four"
                       "old five"])
           (new-lines ["new one" "new two" "new three" "new four"
                       "new five"]))
      (should (= (plist-get gap :count) 4))
      (puthash section old-lines diffs--old-content-cache)
      (puthash section new-lines diffs--new-content-cache)
      (goto-char (car hunk))
      (should
       (string-search
        "[e] +4"
        (diffs--hunk-separator section hunk 'stacked)))
      (diffs--set-context-visible gap 2)
      (should (equal (buffer-string) text))
      (let ((display (overlay-get (plist-get gap :overlay)
                                  'before-string)))
        (should (string-match-p "new three" display))
        (should (string-match-p "new four" display))
        (should-not (string-match-p "new two" display))
        (should (string-search "[e] +2" display)))
      (pcase-let ((`(,old ,new . ,_) (diffs--split-collect)))
        (should (equal (mapcar (lambda (row) (nth 3 row))
                              (seq-take old 4))
                       '(header sep ctx ctx)))
        (should (equal (mapcar #'car (seq-subseq new 2 4))
                       '("new three" "new four"))))
      (diffs--set-context-visible gap 4)
      (let ((display (overlay-get (plist-get gap :overlay)
                                  'before-string)))
        (should (string-match-p "new one" display))
        (should (string-match-p "new four" display))
        (should-not (string-match-p "unmodified lines" display))
        (should-not (string-prefix-p "⋯" display)))
      (pcase-let* ((`(,old ,new . ,_) (diffs--split-collect))
                   (`(,old-physical ,_ ,anchors)
                    (diffs--split-physical-rows old new 80 nil)))
        ;; The semantic separator remains for resolution bookkeeping, but
        ;; complete context makes it empty and removes its physical row.
        (should (eq (nth 3 (nth 1 old)) 'sep))
        (should (string-empty-p (car (nth 1 old))))
        (should
         (equal
          (mapcar (lambda (row) (nth 3 row))
                  (append (seq-take old-physical 5) nil))
          '(header ctx ctx ctx ctx)))
        (should (equal anchors '(1))))
      (should (equal (buffer-string) text)))))

(ert-deftest diffs-context-separators-show-direction-and-key-hint ()
  (let ((diffs--nerd-icons-state 'available))
    (cl-letf (((symbol-function 'nerd-icons-icon-for-file)
               (lambda (&rest _) "file"))
              ((symbol-function 'nerd-icons-octicon)
               (lambda (name &rest _)
                 (pcase name
                   ("nf-oct-chevron_up" "UP")
                   ("nf-oct-chevron_down" "DOWN")))))
      (diffs-tests--with-diff diffs-tests--directional-context
        (diffs-minor-mode 1)
        (let* ((section (car diffs--sections))
               (hunks (plist-get section :hunks))
               (first (car hunks))
               (second (cadr hunks))
               (first-context
                (diffs--hunk-separator-context section first 'stacked))
               (second-context
                (diffs--hunk-separator-context section second 'stacked))
               (first-label
                (diffs--hunk-separator section first 'stacked))
               (second-label
                (diffs--hunk-separator section second 'stacked))
               (key-start (string-match "\\[e\\]" first-label)))
          (should (eq (plist-get first-context :direction) 'up))
          (should (eq (plist-get second-context :direction) 'down))
          (should (string-prefix-p "UP " first-label))
          (should (string-prefix-p "DOWN " second-label))
          (should (string-search "press [e] +2" first-label))
          (should (string-search "press [e] +4" second-label))
          (should key-start)
          (should-not (get-text-property key-start 'face first-label))
          (goto-char (car first))
          (let* ((display (get-text-property (point) 'display))
                 (display-key (string-match "\\[e\\]" display))
                 (faces (ensure-list
                         (get-text-property display-key 'face display))))
            (should display-key)
            (should (memq 'diffs-hunk-separator faces))
            (should-not (memq 'diffs-key-hint faces)))
          (pcase-let ((`(,old ,_new . ,_) (diffs--split-collect)))
            (let* ((labels
                    (mapcar
                     #'car
                     (seq-filter
                      (lambda (row) (eq (nth 3 row) 'sep))
                      old)))
                   (split-key (string-match "\\[e\\]" (car labels)))
                   (faces
                    (ensure-list
                     (get-text-property
                      split-key 'face (car labels)))))
              (should (string-prefix-p "UP " (car labels)))
              (should (string-prefix-p "DOWN " (cadr labels)))
              (should (memq 'diffs-hunk-separator faces))
              (should-not (memq 'diffs-key-hint faces)))))
        (diffs-minor-mode -1)))))

(ert-deftest diffs-context-separator-icons-have-text-fallbacks ()
  (let ((diffs--nerd-icons-state 'missing))
    (dolist (spec '((up . "↑ ") (down . "↓ ")))
      (let ((label
             (diffs-default-hunk-separator
              (list :item-type 'diff
                    :direction (car spec)
                    :count 12
                    :visible 0
                    :hidden 12
                    :context-step 10))))
        (should (string-prefix-p (cdr spec) label))
        (should (string-search "press [e] +10" label))))))

(ert-deftest diffs-context-bindings-expand-in-steps ()
  (should (eq (keymap-lookup diffs-minor-mode-map "e")
              #'diffs-expand-context))
  (should (eq (keymap-lookup diffs-split-mode-map "e")
              #'diffs-split-expand-context))
  (dolist (key '("c" "TAB" "<backtab>" "E"))
    (should-not (keymap-lookup diffs-minor-mode-map key))
    (should-not (keymap-lookup diffs-split-mode-map key)))
  (diffs-tests--with-diff diffs-tests--hidden-context
    (diffs-minor-mode 1)
    (goto-char (point-min))
    (re-search-forward "^@@")
    (beginning-of-line)
    (should (eq (key-binding (kbd "TAB")) #'outline-cycle)))
  (let ((diffs-context-step 2))
    (diffs-tests--with-diff diffs-tests--hidden-context
      (diffs--scan)
      (let* ((section (car diffs--sections))
             (hunk (car (plist-get section :hunks)))
             (gap (diffs--gap-for-hunk hunk)))
        (puthash section
                 ["old one" "old two" "old three" "old four" "old five"]
                 diffs--old-content-cache)
        (puthash section
                 ["new one" "new two" "new three" "new four" "new five"]
                 diffs--new-content-cache)
        (goto-char (car hunk))
        (diffs-expand-context)
        (diffs-expand-context)
        (should (= (plist-get gap :visible) 4))
        (should-error (diffs-expand-context) :type 'user-error)))))

(ert-deftest diffs-context-loads-from-stable-review-root ()
  (let ((repository (make-temp-file "diffs-context-root-" t))
        (other-directory (make-temp-file "diffs-context-other-" t)))
    (unwind-protect
        (let ((default-directory repository))
          (with-temp-file (expand-file-name "context.el" repository)
            (insert "one\ntwo\nthree\nfour\nnew five\n"))
          (diffs-tests--with-diff diffs-tests--hidden-context
            (setq default-directory repository)
            (diffs-minor-mode 1)
            (should
             (equal diffs--review-repository
                    (file-name-as-directory repository)))
            (let ((section (car diffs--sections)))
              (puthash section (make-symbol "old-missing-content")
                       diffs--old-content-cache)
              (puthash section (make-symbol "old-missing-content")
                       diffs--new-content-cache))
            ;; Context belongs to the review's captured repository even if
            ;; another command later changes the buffer's working directory.
            ;; A negative cache from code loaded before the review also gets
            ;; one retry instead of poisoning the live buffer permanently.
            (setq default-directory other-directory)
            (goto-char (point-min))
            (re-search-forward "^@@")
            (beginning-of-line)
            (diffs-expand-context)
            (should (string-match-p "four" (diffs--context-before-string
                                             (car diffs--context-gaps))))))
      (delete-directory repository t)
      (delete-directory other-directory t))))

(ert-deftest diffs-native-stacked-mode-uses-a-read-only-major-map ()
  (let ((buffer (generate-new-buffer " *diffs native stacked test*"))
        (diffs-default-view 'stacked))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert diffs-tests--hidden-context)
          (diffs--present buffer nil nil)
          (should (eq major-mode 'diffs-mode))
          (should (derived-mode-p 'diff-mode))
          (should buffer-read-only)
          (should diffs-minor-mode)
          (dolist
              (binding
               '(("e" . diffs-expand-context)
                 ("g" . diffs-refresh)
                 ("q" . diffs-quit)
                 ("RET" . diff-goto-source)))
            (should
             (eq (key-binding (kbd (car binding)))
                 (cdr binding))))
          ;; A suppressed view map lets modal editors infer a motion state
          ;; without diffs.el knowing about any particular editor.
          (dolist (key (split-string "abcdefghijklmnopqrstuvwxyz" "" t))
            (should-not
             (eq (key-binding key) #'self-insert-command)))
          (goto-char (point-min))
          (re-search-forward "^@@")
          (beginning-of-line)
          (should (eq (key-binding (kbd "TAB")) #'outline-cycle)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-patch-files-enter-the-native-review-mode ()
  (dolist (extension '("diff" "patch"))
    (with-temp-buffer
      (setq buffer-file-name
            (expand-file-name
             (format "diffs-mode-entry.%s" extension)
             temporary-file-directory))
      (insert diffs-tests--hidden-context)
      (set-auto-mode)
      (should (eq major-mode 'diffs-mode))
      (should (derived-mode-p 'diff-mode))
      (should diffs-minor-mode)
      (should diffs--sections)
      (should buffer-read-only))))

(ert-deftest diffs-files-compares-independent-sources-in-one-review ()
  (let* ((directory (make-temp-file "diffs-files-test-" t))
         (old-directory (expand-file-name "old/" directory))
         (new-directory (expand-file-name "new/" directory))
         (old (expand-file-name "sample.el" old-directory))
         (new (expand-file-name "sample.el" new-directory))
         (source (generate-new-buffer " *diffs files source*"))
         owner
         target-buffer
         (calls 0)
         (diffs-default-view 'split))
    (unwind-protect
        (progn
          (make-directory old-directory)
          (make-directory new-directory)
          (with-temp-file old
            (insert "before\n(setq value 'old)\nafter\n"))
          (with-temp-file new
            (insert "before\n(setq value 'new)\nafter\n"))
          (require 'diff)
          (cl-letf
              (((symbol-function 'diff-no-select)
                (lambda (actual-old actual-new switches no-async buffer)
                  (cl-incf calls)
                  (should (equal actual-old old))
                  (should (equal actual-new new))
                  (should (equal switches '("-u")))
                  (should no-async)
                  (with-current-buffer buffer
                    (insert
                     (format
                      (concat
                       "diff -u %s %s\n"
                       "--- %s\tdate\n"
                       "+++ %s\tdate\n"
                       "@@ -1,3 +1,3 @@\n"
                       " before\n"
                       "-(setq value 'old)\n"
                       "+(setq value 'new)\n"
                       " after\n\n"
                       "Diff finished.  date\n")
                      old new old new)))
                  buffer)))
            (save-window-excursion
              (switch-to-buffer source)
              (insert "entry")
              (goto-char 3)
              (set-window-point (selected-window) (point))
              (diffs-files old new)
              (setq owner (diffs--review-owner-buffer))
              (should (= calls 1))
              (should (derived-mode-p 'diffs-split-mode))
              (should
               (buffer-local-value
                'diffs--independent-sources owner))
              (should
               (equal
                (buffer-local-value
                 'diffs--review-repository owner)
                (file-name-as-directory directory)))
              (with-current-buffer owner
                (should (= (length diffs--sections) 1))
                (let ((section (car diffs--sections)))
                  (should (equal (plist-get section :old-file) old))
                  (should (equal (plist-get section :file) new))
                  (should
                   (equal
                    (append (diffs--section-lines section 'old) nil)
                    '("before" "(setq value 'old)" "after")))
                  (should
                   (equal
                    (append (diffs--section-lines section 'new) nil)
                    '("before" "(setq value 'new)" "after")))
                  (let ((stacked-header
                         (diffs--file-header section 'stacked)))
                    (should
                     (string-match-p
                      "A · .*old/sample\\.el → B · .*new/sample\\.el"
                      stacked-header)))
                  (pcase-let* ((`(,chunks ,_anchors ,_count)
                                 (diffs--split-paged-index))
                                (rows
                                 (diffs--split-paged-chunk-rows
                                  (aref chunks 0)))
                                (old-header (car (aref (nth 0 rows) 0)))
                                (new-header (car (aref (nth 1 rows) 0))))
                    (diffs-tests--assert-file-comparison-side-header
                     old-header "A" "old/sample.el" "new/sample.el")
                    (diffs-tests--assert-file-comparison-side-header
                     new-header "B" "new/sample.el" "old/sample.el"))))
              (let* ((cache
                      (buffer-local-value 'diffs--split-cache owner))
                     (old-view (plist-get cache :old))
                     (new-view (plist-get cache :new)))
                (dolist (spec
                         (list (list old-view 'del old "A" "old" "new")
                               (list new-view 'add new "B" "new" "old")))
                  (pcase-let ((`(,view ,kind ,file ,label
                                      ,own-directory ,peer-directory)
                               spec))
                    (with-current-buffer view
                      (let ((header (car (aref diffs--split-rows 0)))
                            (index
                             (cl-loop
                              for row across diffs--split-rows
                              for row-index from 0
                              when (eq (nth 3 row) kind)
                              return row-index)))
                        (diffs-tests--assert-file-comparison-side-header
                         header label
                         (format "%s/sample.el" own-directory)
                         (format "%s/sample.el" peer-directory))
                        (diffs-tests--assert-file-comparison-side-header
                         (diffs--split-header-line) label
                         (format "%s/sample.el" own-directory)
                         (format "%s/sample.el" peer-directory))
                        (goto-char
                         (diffs--split-row-position index))
                        (diffs--split-materialize-range
                         index (1+ index))
                        (should
                         (equal
                          (diffs--split-property-at
                           'diffs-src (point))
                          (cons file 2)))))))
                (with-current-buffer old-view
                  (goto-char (point-min))
                  (search-forward "(setq value 'old)")
                  (beginning-of-line)
                  (diffs-review-select)
                  (diffs-review-add-annotation
                   "Keep the old-side review identity." "")
                  (let ((text
                         (car
                          (diffs-tests--review-annotation-projection
                           "Keep the old-side review identity"))))
                    (should
                     (string-match-p "old/sample\\.el A2" text))
                    (should-not
                     (string-match-p "new/sample\\.el" text))))
                (with-current-buffer new-view
                  (goto-char (point-min))
                  (search-forward "(setq value 'new)")
                  (beginning-of-line)
                  (diffs-review-select)
                  (diffs-review-add-annotation
                   "Keep the new-side review identity." "")
                  (let ((text
                         (car
                          (diffs-tests--review-annotation-projection
                           "Keep the new-side review identity"))))
                    (should
                     (string-match-p "new/sample\\.el B2" text))
                    (should-not
                     (string-match-p "old/sample\\.el" text))))
                (let ((annotation
                       (cl-find-if
                        (lambda (candidate)
                          (equal
                           (plist-get candidate :summary)
                           "Keep the old-side review identity."))
                        (buffer-local-value
                         'diffs--review-annotations owner))))
                  (should annotation)
                  (should (equal (plist-get annotation :file) new))
                  (should
                   (equal (plist-get annotation :old-range) '(2 2)))))
              (diffs-refresh)
              (should (= calls 2))
              (should
               (buffer-local-value
                'diffs--independent-sources owner))
              (let* ((cache
                      (buffer-local-value 'diffs--split-cache owner))
                     (new-view (plist-get cache :new)))
                (with-current-buffer new-view
                  (goto-char (point-min))
                  (search-forward "(setq value 'new)")
                  (beginning-of-line)
                  (diffs-review-reject-change)
                  (let (confirmation)
                    (cl-letf (((symbol-function 'yes-or-no-p)
                               (lambda (prompt)
                                 (setq confirmation prompt)
                                 t)))
                      (diffs-review-apply-decisions))
                    (should
                     (equal confirmation
                            "Apply 1 reviewed decision to file B? ")))))
              (setq target-buffer (find-buffer-visiting new))
              (should (buffer-live-p target-buffer))
              (with-current-buffer target-buffer
                (should (buffer-modified-p))
                (should
                 (equal
                  (buffer-string)
                  "before\n(setq value 'old)\nafter\n")))
              (with-temp-buffer
                (insert-file-contents new)
                (should
                 (equal
                  (buffer-string)
                  "before\n(setq value 'new)\nafter\n")))
              (diffs-split-quit-all)
              (let ((return-window (get-buffer-window source)))
                (should (window-live-p return-window))
                (should (= (window-point return-window) 3))))))
      (dolist (buffer (list owner source target-buffer))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (delete-directory directory t))))

(ert-deftest diffs-minor-mode-keeps-an-external-diff-editable ()
  (diffs-tests--with-diff diffs-tests--hidden-context
    (diffs-minor-mode 1)
    (should (eq major-mode 'diff-mode))
    (should-not buffer-read-only)
    (should (eq (key-binding "b") #'self-insert-command))
    (should (eq (key-binding "c") #'self-insert-command))
    (should (eq (key-binding "e") #'diffs-expand-context))))

(ert-deftest diffs-context-expands-directly-in-split-view ()
  (let ((buf (generate-new-buffer " *diffs split context test*"))
        (diffs-context-step 2)
        old new)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--hidden-context)
          (diff-mode)
          (diffs-minor-mode 1)
          (let ((section (car diffs--sections)))
            (puthash section
                     ["old one" "old two" "old three" "old four"
                      "old five"]
                     diffs--old-content-cache)
            (puthash section
                     ["new one" "new two" "new three" "new four"
                      "new five"]
                     diffs--new-content-cache))
          ;; `diffs--present' makes real views read-only.
          (setq buffer-read-only t)
          (diffs-toggle-split)
          (setq new (current-buffer)
                old diffs--split-other)
          (select-window (get-buffer-window old))
          (goto-char (point-min))
          (forward-line 1)
          (let ((hunk (get-text-property (point) 'diffs-hunk)))
            (diffs-split-expand-context)
            (should (eq diffs--split-role 'old))
            (should (eq (get-text-property (point) 'diffs-hunk) hunk))
            (should (> (point) (point-min))))
          (should (derived-mode-p 'diffs-split-mode))
          (goto-char (point-min))
          (should (re-search-forward "old three" nil t))
          (should (re-search-forward "old four" nil t))
          (with-current-buffer diffs--split-unified
            (should (= (plist-get (car diffs--context-gaps) :visible)
                       2)))
          ;; Expanding the complete gap removes its visual prompt rather than
          ;; leaving an "all lines shown" row between contiguous source lines.
          (diffs-split-expand-context)
          (setq old (current-buffer)
                new diffs--split-other)
          (with-current-buffer diffs--split-unified
            (should (= (plist-get (car diffs--context-gaps) :visible)
                       4)))
          (dolist (buffer (list old new))
            (with-current-buffer buffer
              (should-not
               (string-match-p "unmodified lines" (buffer-string)))))
          (let* ((anchor (car diffs--split-anchors))
                 (position
                  (diffs--split-row-position (1- anchor)))
                 (row (diffs--split-row-at-position position)))
            (should (eq (nth 3 row) 'ctx))
            (should (nth 5 row)))
          (let ((split (current-buffer))
                (peer diffs--split-other))
            (should-error (diffs-split-expand-context) :type 'user-error)
            (should (eq (current-buffer) split))
            (should (buffer-live-p peer))
            (should (get-buffer-window split))
            (should (get-buffer-window peer)))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old new buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-split-context-rebuild-restores-wrapped-chunk-offset ()
  (let* ((buf (generate-new-buffer " *diffs split wrapped restore test*"))
         (diffs-context-step 2)
         (diffs-split-wrap-lines t)
         (old-text (concat "old-" (make-string 180 ?a)))
         (new-text (concat "new-" (make-string 180 ?b)))
         old new)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert
           (concat
            "diff --git a/context.el b/context.el\n"
            "--- a/context.el\n"
            "+++ b/context.el\n"
            "@@ -5 +5 @@ context-function\n"
            "-" old-text "\n"
            "+" new-text "\n"))
          (diff-mode)
          (diffs-minor-mode 1)
          (let ((section (car diffs--sections)))
            (puthash section
                     (vector "old one" "old two" "old three" "old four"
                             old-text)
                     diffs--old-content-cache)
            (puthash section
                     (vector "new one" "new two" "new three" "new four"
                             new-text)
                     diffs--new-content-cache))
          (setq buffer-read-only t)
          (diffs-toggle-split)
          (setq new (current-buffer)
                old diffs--split-other)
          (select-window (get-buffer-window old))
          (goto-char (point-min))
          (search-forward "old-")
          (beginning-of-line)
          (forward-line 2)
          (let* ((row (diffs--split-row-at-position (point)))
                 (offset (nth 9 row)))
            (should (> offset 0))
            (diffs-split-expand-context)
            (should (eq diffs--split-role 'old))
            (should (= (nth 9 (diffs--split-row-at-position (point)))
                       offset))
            ;; The rebuild that removes the fully expanded separator must
            ;; preserve the same wrapped physical chunk too.
            (diffs-split-expand-context)
            (should (eq diffs--split-role 'old))
            (should (= (nth 9 (diffs--split-row-at-position (point)))
                       offset))
            (should-not
             (string-match-p "unmodified lines" (buffer-string))))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old new buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    diffs-fully-expanded-multiple-hunks-keep-navigation-and-decision-identity
    ()
  (let ((buf (generate-new-buffer " *diffs full multi-hunk test*"))
        (patch
         (concat
          "diff --git a/multi.el b/multi.el\n"
          "--- a/multi.el\n"
          "+++ b/multi.el\n"
          "@@ -3 +3 @@ first\n"
          "-old three\n"
          "+new three\n"
          "@@ -8 +8 @@ second\n"
          "-old eight\n"
          "+new eight\n"))
        old new key-one key-two)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert patch)
          (diff-mode)
          (diffs-minor-mode 1)
          (let ((section (car diffs--sections)))
            (puthash
             section
             ["one" "two" "old three" "four"
              "five" "six" "seven" "old eight"]
             diffs--old-content-cache)
            (puthash
             section
             ["one" "two" "new three" "four"
              "five" "six" "seven" "new eight"]
             diffs--new-content-cache)
            (dolist (gap diffs--context-gaps)
              (diffs--set-context-visible
               gap (plist-get gap :count))))
          (setq buffer-read-only t)
          (diffs-toggle-split)
          (setq new (current-buffer)
                old diffs--split-other)
          (select-window (get-buffer-window old))
          (should (equal diffs--split-anchors '(2 5)))
          (should-not
           (string-match-p "unmodified lines" (buffer-string)))
          (goto-char (point-min))
          (diffs-split-next-hunk)
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "one"))
          (let ((first-hunk
                 (nth 5 (diffs--split-row-at-position (point)))))
            (diffs-split-next-hunk)
            (should
             (equal
              (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))
              "four"))
            (should-not
             (eq (nth 5 (diffs--split-row-at-position (point)))
                 first-hunk))
            (diffs-split-prev-hunk)
            (should
             (eq (nth 5 (diffs--split-row-at-position (point)))
                 first-hunk)))
          (goto-char (point-min))
          (search-forward "old three")
          (beginning-of-line)
          (setq key-one
                (plist-get
                 (diffs--resolution-block-at-point buf) :key))
          (should (equal key-one '("multi.el" 3 3 0)))
          (diffs-review-accept-change)
          (setq old (current-buffer)
                new diffs--split-other)
          (should
           (eq
            (plist-get
             (with-current-buffer buf
               (alist-get key-one diffs--review-decisions
                          nil nil #'equal))
             :action)
            'accept))
          (diffs-split-next-hunk)
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "four"))
          (goto-char (point-min))
          (search-forward "old eight")
          (beginning-of-line)
          (setq key-two
                (plist-get
                 (diffs--resolution-block-at-point buf) :key))
          (should (equal key-two '("multi.el" 8 8 0)))
          (should-not (equal key-one key-two))
          (diffs-review-reject-change)
          (setq old (current-buffer)
                new diffs--split-other)
          (with-current-buffer buf
            (should
             (eq (plist-get
                  (alist-get key-one diffs--review-decisions
                             nil nil #'equal)
                  :action)
                 'accept))
            (should
             (eq (plist-get
                  (alist-get key-two diffs--review-decisions
                             nil nil #'equal)
                  :action)
                 'reject)))
          (should
           (equal
            (diffs--split-row-resolution-key
             (diffs--split-row-at-position (point)))
            key-two))
          (diffs-review-reset-change)
          (setq old (current-buffer)
                new diffs--split-other)
          (with-current-buffer buf
            (should
             (alist-get key-one diffs--review-decisions
                        nil nil #'equal))
            (should-not
             (alist-get key-two diffs--review-decisions
                        nil nil #'equal)))
          (goto-char (point-min))
          (search-forward "Kept change")
          (beginning-of-line)
          (should
           (equal
            (diffs--split-row-resolution-key
             (diffs--split-row-at-position (point)))
            key-one))
          (diffs-review-reset-change)
          (with-current-buffer buf
            (should-not diffs--review-decisions))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old new buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-split-context-error-keeps-split-layout ()
  (let ((buf (generate-new-buffer " *diffs split context error test*"))
        split other)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq split (current-buffer)
                other diffs--split-other)
          (goto-char (point-min))
          (forward-line 1)
          (should-error (diffs-split-expand-context) :type 'user-error)
          (should (eq (current-buffer) split))
          (should (derived-mode-p 'diffs-split-mode))
          (should (buffer-live-p other))
          (should (get-buffer-window split))
          (should (get-buffer-window other))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list split other buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-split-context-load-error-keeps-split-layout ()
  (let ((buf (generate-new-buffer " *diffs split context load error*"))
        split other)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--hidden-context)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq split (current-buffer)
                other diffs--split-other)
          (goto-char (point-min))
          (forward-line 1)
          (let* ((error-data
                  (should-error
                   (diffs-split-expand-context)
                   :type 'user-error))
                 (message (error-message-string error-data)))
            (should
             (string-match-p
              "old: Review has no VC backend"
              message))
            (should
             (string-match-p
              "new: Working-tree file is not readable:"
              message)))
          (should (eq (current-buffer) split))
          (should (derived-mode-p 'diffs-split-mode))
          (should (buffer-live-p other))
          (should (get-buffer-window split))
          (should (get-buffer-window other))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list split other buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-context-gap-tracks-renamed-old-path ()
  (diffs-tests--with-diff
      (concat
       "diff --git a/old.el b/new.el\n"
       "--- a/old.el\n"
       "+++ b/new.el\n"
       "@@ -2 +2 @@\n-old\n+new\n")
    (diffs--scan)
    (let ((section (car diffs--sections)))
      (should (equal (plist-get section :old-file) "old.el"))
      (should (equal (plist-get section :file) "new.el")))))

(ert-deftest diffs-context-revision-loader-keeps-owning-backend ()
  (let ((stable-root (file-name-as-directory temporary-file-directory))
        called-backend called-file called-revision called-directory)
    (with-temp-buffer
      (setq-local diff-vc-backend 'Git)
      (setq-local diffs--review-repository stable-root)
      (cl-letf (((symbol-function 'vc-call-backend)
                 (lambda (backend _operation file revision buffer)
                   (setq called-backend backend
                         called-file file
                         called-revision revision
                         called-directory
                         (buffer-local-value 'default-directory buffer))
                   (with-current-buffer buffer
                     (insert "one\ntwo\n")))))
        (should (equal (diffs--revision-lines "foo.el" "HEAD")
                       ["one" "two"]))))
    (should (eq called-backend 'Git))
    (should (equal called-file (expand-file-name "foo.el" stable-root)))
    (should (equal called-revision "HEAD"))
    (should (equal called-directory stable-root))))

(ert-deftest diffs-defaults-to-non-wrapping-split-view ()
  (should (eq (default-value 'diffs-default-view) 'split))
  (should-not (default-value 'diffs-split-wrap-lines))
  (should
   (eq (default-value 'diffs-split-virtualization) 'auto))
  (should
   (= (default-value 'diffs-split-virtualization-threshold) 5000))
  (should (eq (lookup-key diffs-split-mode-map (kbd "q"))
              #'diffs-split-quit-all))
  (should (eq (lookup-key diffs-split-mode-map (kbd "s"))
              #'diffs-split-quit)))

(ert-deftest diffs-default-split-q-quits-both-columns ()
  (let ((buf (generate-new-buffer " *diffs default split test*"))
        (origin (generate-new-buffer " *diffs origin test*"))
        (diffs-fullscreen nil)
        old new)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer origin)
          (with-current-buffer buf
            (insert diffs-tests--normal))
          (diffs--present buf 'Git "HEAD")
          (should (derived-mode-p 'diffs-split-mode))
          (setq new (current-buffer)
                old diffs--split-other)
          (diffs-split-quit-all)
          (should-not (buffer-live-p old))
          (should-not (buffer-live-p new))
          (should-not (get-buffer-window buf)))
      (dolist (buffer (list old new buf origin))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-file-unsaved-diff-keeps-last-revision-baseline ()
  (let ((source (generate-new-buffer " *diffs unsaved source*"))
        (review (generate-new-buffer " *diffs unsaved review*"))
        (real-require (symbol-function 'require))
        (diff-hl-show-staged-changes nil)
        observed)
    (unwind-protect
        (with-current-buffer source
          (setq buffer-file-name "/tmp/diffs-unsaved.el"
                default-directory "/tmp/")
          (insert "(message \"changed\")\n")
          (set-buffer-modified-p t)
          (cl-letf
              (((symbol-function 'vc-backend)
                (lambda (_file) 'Git))
               ((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'diff-hl)
                      t
                    (funcall real-require feature filename noerror))))
               ((symbol-function
                 'diff-hl-diff-buffer-with-reference)
                (lambda (_file destination _backend _context)
                  (setq observed diff-hl-show-staged-changes)
                  destination))
               ((symbol-function 'diffs--prepare-buffer)
                (lambda (_directory) review))
               ((symbol-function 'diffs--present)
                (lambda (&rest _arguments) review)))
            (diffs-file)))
      (dolist (buffer (list source review))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))
    (should observed)))

(ert-deftest diffs-file-split-quit-restores-clicked-source-position ()
  (let ((source (generate-new-buffer " *diffs return source*"))
        (diffs-buffer-name " *diffs return review*")
        (diffs-default-view 'split)
        (diffs-fullscreen nil)
        (real-pop-to-buffer (symbol-function 'pop-to-buffer))
        source-window expected-point review)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (setq buffer-file-name "/tmp/foo.el"
                default-directory temporary-file-directory
                source-window (selected-window))
          (insert "one\ntwo\nthree\nfour\n")
          (set-buffer-modified-p nil)
          (goto-char (point-min))
          (forward-line 1)
          (setq expected-point (point))
          (set-window-point source-window expected-point)
          (cl-letf
              (((symbol-function 'vc-backend)
                (lambda (_file) 'Git))
               ((symbol-function 'diffs--reference-revision)
                (lambda (_directory) "HEAD"))
               ((symbol-function 'vc-call-backend)
                (lambda (_backend operation &rest arguments)
                  (pcase operation
                    ('root
                     (with-current-buffer source
                       (goto-char (point-min))
                       (forward-line 2)
                       (set-window-point source-window (point)))
                     temporary-file-directory)
                    ('diff
                     (with-current-buffer source
                       (goto-char (point-max))
                       (set-window-point source-window (point)))
                     (with-current-buffer (nth 3 arguments)
                       (insert diffs-tests--normal))))))
               ((symbol-function 'diff-hl-diff-skip-to)
                (lambda (&rest _arguments)))
               ((symbol-function 'pop-to-buffer)
                (lambda (&rest arguments)
                  ;; Reproduce a source point change after return-layout
                  ;; capture but before the source window is replaced.
                  (with-current-buffer source
                    (goto-char (point-max))
                    (set-window-point source-window (point)))
                  (apply real-pop-to-buffer arguments))))
            (diffs-file))
          (setq review (get-buffer diffs-buffer-name))
          (should (derived-mode-p 'diffs-split-mode))
          (diffs-split-quit-all)
          (let ((return-window (get-buffer-window source)))
            (should (window-live-p return-window))
            (should (= (window-point return-window) expected-point))))
      (dolist (buffer (list review source))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest diffs-project-reference-uses-diff-hl-public-cache ()
  (let* ((root (make-temp-file "diffs-reference-" t))
         (nested (expand-file-name "src/" root))
         (diff-hl-reference-revision nil)
         (diff-hl-reference-revision-projects-cache
          (list (cons (file-name-as-directory root) "PROJECT-BASE"))))
    (unwind-protect
        (progn
          (make-directory nested t)
          (with-temp-buffer
            (setq default-directory nested)
            (should
             (equal
              (diffs--reference-revision nested)
              "PROJECT-BASE"))))
      (delete-directory root t))))

(ert-deftest diffs-source-line-entry-survives-default-split ()
  (let ((buffer (generate-new-buffer " *diffs entry split*"))
        (origin (generate-new-buffer " *diffs entry origin*"))
        (real-require (symbol-function 'require))
        (diffs-default-view 'split)
        (diffs-fullscreen nil)
        old new)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer origin)
          (with-current-buffer buffer
            (insert diffs-tests--normal))
          (cl-letf
              (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'diff-hl)
                      t
                    (funcall real-require feature filename noerror))))
               ((symbol-function 'diff-hl-diff-skip-to)
                (lambda (_line &optional _filename)
                  (goto-char (point-min))
                  (re-search-forward "^+(message \"extra\")")
                  (beginning-of-line))))
            (diffs--present buffer 'Git "HEAD" 3))
          (should (derived-mode-p 'diffs-split-mode))
          (setq new (current-buffer)
                old diffs--split-other)
          (should (eq diffs--split-role 'new))
          (should (eq (diffs--split-property-at 'diffs-kind (point))
                      'add))
          (should
           (equal (diffs--split-property-at 'diffs-src (point))
                  '("foo.el" . 3)))
          (should
           (string-match-p
            "message \"extra\""
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position)))))
      (dolist (item (list old new buffer origin))
        (when (buffer-live-p item)
          (kill-buffer item))))))

(ert-deftest diffs-diff-hl-mode-restores-renderer ()
  (let ((diff-hl-show-hunk-function #'ignore)
        (diffs--diff-hl-show-hunk-function-before-mode nil)
        (diffs--diff-hl-show-hunk-function-saved-p nil)
        (diffs-diff-hl-mode nil)
        (real-require (symbol-function 'require)))
    (cl-letf
        (((symbol-function 'require)
          (lambda (feature &optional filename noerror)
            (if (eq feature 'diff-hl-show-hunk)
                t
              (funcall real-require feature filename noerror)))))
      (unwind-protect
          (progn
            (diffs-diff-hl-mode 1)
            (should
             (eq diff-hl-show-hunk-function
                 #'diffs-diff-hl-show-hunk))
            (should (eq (diffs--diff-hl-display-backend) #'ignore))
            ;; Re-enabling must not replace the original saved renderer.
            (diffs-diff-hl-mode 1))
        (diffs-diff-hl-mode -1)))
    (should (eq diff-hl-show-hunk-function #'ignore))
    (should-not diffs--diff-hl-show-hunk-function-saved-p)))

(ert-deftest diffs-diff-hl-adapter-loads-lazily ()
  (should diffs-tests--diff-hl-adapter-was-lazy)
  (should (featurep 'diffs-diff-hl)))

(ert-deftest diffs-diff-hl-mode-restores-nil-renderer ()
  (let ((diff-hl-show-hunk-function nil)
        (diffs--diff-hl-show-hunk-function-before-mode nil)
        (diffs--diff-hl-show-hunk-function-saved-p nil)
        (diffs-diff-hl-mode nil)
        (real-require (symbol-function 'require))
        inside)
    (cl-letf
        (((symbol-function 'require)
          (lambda (feature &optional filename noerror)
            (if (eq feature 'diff-hl-show-hunk)
                t
              (funcall real-require feature filename noerror)))))
      (unwind-protect
          (progn
            (diffs-diff-hl-mode 1)
            (setq inside diff-hl-show-hunk-function))
        (diffs-diff-hl-mode -1)))
    (should (eq inside #'diffs-diff-hl-show-hunk))
    (should-not diff-hl-show-hunk-function)))

(ert-deftest diffs-diff-hl-renderer-decorates-only-current-hunk ()
  (let ((supplied (generate-new-buffer " *diffs diff-hl supplied*"))
        (diffs-default-view 'stacked)
        original
        narrowed
        removed-display)
    (unwind-protect
        (with-current-buffer supplied
          (insert diffs-tests--two-files)
          (diff-mode)
          (goto-char (point-min))
          (re-search-forward "^@@")
          (forward-line 1)
          (let ((begin (point))
                (end (progn
                       (re-search-forward "^diff --git a/bar")
                       (line-beginning-position))))
            (setq narrowed
                  (buffer-substring-no-properties begin end))
            (add-text-properties
             begin end '(line-prefix "upstream line number "))
            (narrow-to-region begin end))
          (setq original
                (save-restriction
                  (widen)
                  (buffer-substring-no-properties
                   (point-min) (point-max))))
          (diffs--diff-hl-render-current-hunk supplied)
          (goto-char (point-min))
          (while (< (point) (point-max))
            (should (get-text-property (point) 'diffs-diff-hl))
            (should (stringp (get-text-property (point) 'display)))
            (should-not (get-text-property (point) 'line-prefix))
            (forward-line 1))
          (goto-char (point-min))
          (re-search-forward "^-(message \"old\")")
          (setq removed-display
                (get-text-property (line-beginning-position) 'display))
          (should (string-match-p "\\` +2 +" removed-display))
          (should (string-match "\"old\"" removed-display))
          (should
           (diffs-tests--face-includes-p
            (get-text-property (1+ (match-beginning 0))
                               'face removed-display)
            'font-lock-string-face))
          (should (string-match "old" removed-display))
          (should
           (diffs-tests--face-includes-p
            (get-text-property (match-beginning 0)
                               'face removed-display)
            'diff-refine-removed))
          (save-restriction
            (widen)
            (goto-char (point-min))
            (re-search-forward "^-old bar")
            (should-not
             (get-text-property (line-beginning-position)
                                'diffs-diff-hl)))
          (should
           (equal
            (save-restriction
              (widen)
              (buffer-substring-no-properties
               (point-min) (point-max)))
            original))
          (should (equal (buffer-substring-no-properties
                          (point-min) (point-max))
                         narrowed)))
      (when (buffer-live-p supplied)
        (kill-buffer supplied)))))

(ert-deftest diffs-diff-hl-renderer-delegates-single-hunk ()
  (let ((source (generate-new-buffer " *diffs diff-hl source*"))
        (supplied (generate-new-buffer " *diffs diff-hl delegated*"))
        (diffs-default-view 'stacked)
        (source-point nil)
        (observed-buffer nil)
        (observed-line nil)
        (observed-content nil)
        (observed-display nil))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (insert "one\ntwo\nthree\n")
          (forward-line 1)
          (setq source-point (point))
          (with-current-buffer supplied
            (insert diffs-tests--two-files)
            (diff-mode)
            (goto-char (point-min))
            (re-search-forward "^@@")
            (forward-line 1)
            (let ((begin (point))
                  (end (progn
                         (re-search-forward "^diff --git a/bar")
                         (line-beginning-position))))
              (narrow-to-region begin end)))
          (let ((diffs-diff-hl-display-function
                 (lambda (buffer line)
                   (setq observed-buffer buffer
                         observed-line line
                         observed-content
                         (with-current-buffer buffer
                           (buffer-substring-no-properties
                            (point-min) (point-max)))
                         observed-display
                         (with-current-buffer buffer
                           (get-text-property (point-min) 'display))))))
            (diffs-diff-hl-show-hunk supplied 3))
          (should (= (point) source-point)))
      (dolist (buffer (list supplied source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))
    (should (eq observed-buffer supplied))
    (should (= observed-line 3))
    (should (equal observed-content
                   (concat
                    " (message \"same\")\n"
                    "-(message \"old\")\n"
                    "+(message \"new\")\n"
                    "+(message \"extra\")\n")))
    (should (stringp observed-display))))

(ert-deftest diffs-diff-hl-split-layout-uses-aligned-current-hunk ()
  (let ((supplied (generate-new-buffer " *diffs diff-hl split source*"))
        (diffs-default-view 'split)
        (diffs-split-wrap-lines nil)
        (available-width 81)
        original
        carrier
        displays)
    (unwind-protect
        (progn
          (with-current-buffer supplied
            (insert diffs-tests--two-files)
            (diff-mode)
            (goto-char (point-min))
            (re-search-forward "^@@")
            (forward-line 1)
            (let ((begin (point))
                  (end (progn
                         (re-search-forward "^diff --git a/bar")
                         (line-beginning-position))))
              (narrow-to-region begin end))
            (setq original
                  (save-restriction
                    (widen)
                    (buffer-substring-no-properties
                     (point-min) (point-max)))))
          (cl-letf (((symbol-function 'window-body-width)
                     (lambda (&optional _window) available-width)))
            (setq carrier
                  (diffs--diff-hl-render-current-hunk supplied)))
          (should-not (eq carrier supplied))
          (with-current-buffer carrier
            (should (= (count-lines (point-min) (point-max)) 3))
            (goto-char (point-min))
            (while (< (point) (point-max))
              (should (equal
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       " "))
              (push (get-text-property (point) 'display) displays)
              (forward-line 1)))
          (setq displays (nreverse displays))
          (dolist (display displays)
            (should (stringp display))
            (should (string-match-p " │ " display))
            (should-not (string-search "\n" display))
            ;; Posframe enables wrapping.  Reaching the exact parent
            ;; width would create one blank continuation row.
            (should (< (string-width display) available-width)))
          (should (string-match-p "(message \"same\")" (nth 0 displays)))
          (should (string-match-p "(message \"old\")" (nth 1 displays)))
          (should (string-match-p "(message \"new\")" (nth 1 displays)))
          (should (string-match-p "(message \"extra\")" (nth 2 displays)))
          ;; The right column must not be padded to the parent-window
          ;; edge.  Posframe enables wrapping, so that padding could
          ;; become an otherwise empty continuation row.
          (should
           (string-suffix-p
            "(message \"extra\")"
            (substring-no-properties (nth 2 displays))))
          (should
           (equal
            (with-current-buffer supplied
              (save-restriction
                (widen)
                (buffer-substring-no-properties
                 (point-min) (point-max))))
            original)))
      (dolist (buffer (list carrier supplied))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-diff-hl-posframe-selection-keeps-the-adapter ()
  (let ((supplied (generate-new-buffer " *diffs diff-hl posframe source*"))
        (diff-hl-show-hunk-function #'diffs-diff-hl-show-hunk)
        (diffs-diff-hl-display-function #'diff-hl-show-hunk-posframe)
        (diffs-default-view 'split)
        (real-require (symbol-function 'require))
        observed-buffer
        observed-line)
    (unwind-protect
        (progn
          (with-current-buffer supplied
            (insert diffs-tests--normal)
            (diff-mode)
            (goto-char (point-min))
            (re-search-forward "^@@")
            (forward-line 1)
            (narrow-to-region (point) (point-max)))
          (cl-letf
              (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'diff-hl-show-hunk-posframe)
                      t
                    (funcall real-require feature filename noerror))))
               ((symbol-function 'diff-hl-show-hunk-posframe)
                (lambda (buffer line)
                  (setq observed-buffer buffer
                        observed-line line))))
            (diffs-diff-hl-show-hunk supplied 2))
          (should
           (eq diff-hl-show-hunk-function
               #'diffs-diff-hl-show-hunk))
          (should-not (eq observed-buffer supplied))
          (should (= observed-line 2))
          (with-current-buffer observed-buffer
            (should
             (string-match-p
              " │ " (get-text-property (point-min) 'display)))))
      (dolist (buffer (list observed-buffer supplied))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-diff-hl-inline-shows-the-complete-current-hunk ()
  (let ((supplied (generate-new-buffer " *diffs diff-hl complete hunk*"))
        (diff-hl-show-hunk-inline-smart-lines t)
        observed-smart-lines
        observed-line)
    (unwind-protect
        (cl-letf
            (((symbol-function 'diffs--diff-hl-display-backend)
              (lambda () #'diff-hl-show-hunk-inline))
             ((symbol-function 'diffs--diff-hl-render-current-hunk)
              #'identity)
             ((symbol-function 'diff-hl-show-hunk-inline)
              (lambda (_buffer line)
                (setq observed-smart-lines
                      diff-hl-show-hunk-inline-smart-lines
                      observed-line line))))
          (diffs-diff-hl-show-hunk supplied 4))
      (when (buffer-live-p supplied)
        (kill-buffer supplied)))
    (should-not observed-smart-lines)
    (should (= observed-line 4))))

(ert-deftest diffs-review-selection-and-annotations-survive-layout-switches ()
  (let ((buf (generate-new-buffer " *diffs review selection test*"))
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-(message")
          (beginning-of-line)
          (diffs-review-select)
          (should
           (equal diffs--review-selection
                  '(:file "foo.el" :side old :start 2 :end 2)))
          (should
           (cl-some
            (lambda (overlay)
              (eq (overlay-get overlay 'face)
                  'diffs-review-selection))
            (overlays-at (point))))
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (with-current-buffer old-buf
            (goto-char (point-min))
            (re-search-forward "(message \"old\")")
            (beginning-of-line)
            (should
             (cl-some
              (lambda (overlay)
                (eq (overlay-get overlay 'face)
                    'diffs-review-selection))
              (overlays-at (point)))))
          (with-current-buffer new-buf
            (should-not
             (cl-some
              (lambda (overlay)
                (eq (overlay-get overlay 'face)
                    'diffs-review-selection))
              (overlays-in (point-min) (point-max)))))
          (diffs-review-add-annotation
           "The old-side behavior needs verification." "")
          (with-current-buffer old-buf
            (should
             (cl-some
              (lambda (overlay)
                (when-let* ((text (overlay-get overlay 'after-string)))
                  (string-match-p "needs verification" text)))
              (overlays-in (point-min) (point-max)))))
          (with-current-buffer new-buf
            (should
             (cl-some
              (lambda (overlay)
                (when-let* ((text (overlay-get overlay 'after-string)))
                  (and (string-match-p "\\`\n" text)
                       (not (string-match-p "needs verification" text)))))
              (overlays-in (point-min) (point-max)))))
          (diffs-split-quit)
          (with-current-buffer buf
            (should
             (cl-some
              (lambda (overlay)
                (when-let* ((text (overlay-get overlay 'after-string)))
                  (string-match-p "needs verification" text)))
              (overlays-in (point-min) (point-max))))
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-review-interactive-comment-uses-bottom-composer ()
  (diffs-tests--with-diff diffs-tests--normal
    (let ((owner (current-buffer)) draft origin-point)
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer owner)
        (diffs-minor-mode 1)
        (goto-char (point-min))
        (re-search-forward "^+(message \"new\")")
        (beginning-of-line)
        (setq origin-point (point))
        (let ((origin-window (selected-window))
              (origin-count (length (window-list))))
          (call-interactively #'diffs-review-add-annotation)
          (setq draft (current-buffer))
          (should (derived-mode-p 'diffs-review-compose-mode))
          (should (eq diffs--review-compose-owner owner))
          (should (eq (command-remapping 'yank)
                      #'diffs-review-compose-yank))
          (should (eq (window-parameter nil 'window-side) 'bottom))
          (should (> (length (window-list)) origin-count))
          (cl-letf (((symbol-function 'yank-media)
                     (lambda (&optional _noselect)
                       (ert-fail "prefixed yank attempted media")))
                    ((symbol-function 'yank)
                     (lambda (&optional _argument)
                       (insert "forced text"))))
            (let ((this-command 'diffs-review-compose-yank))
              (diffs-review-compose-yank '(4))
              (should (eq this-command 'yank))))
          (should (equal (buffer-string) "forced text"))
          (erase-buffer)
          (cl-letf (((symbol-function 'yank-media)
                     (lambda (&optional _noselect)
                       (user-error "No image is available")))
                    ((symbol-function 'yank)
                     (lambda (&optional _argument)
                       (insert "Summary line\ncontinues"))))
            (diffs-review-compose-yank))
          (insert "\n\nReason one\nreason two")
          (diffs-review-compose-submit)
          (should-not (buffer-live-p draft))
          (should (eq (current-buffer) owner))
          (should (eq (selected-window) origin-window))
          (should (= (length (window-list)) origin-count))
          (should (= (point) origin-point))
          (let ((annotation (car diffs--review-annotations)))
            (should (equal (plist-get annotation :summary)
                           "Summary line\ncontinues"))
            (should (equal (plist-get annotation :rationale)
                           "Reason one\nreason two"))))
        (diffs-minor-mode -1)))))

(ert-deftest diffs-review-composer-removes-a-draft-image ()
  (should diffs-tests--review-composer-was-lazy)
  (require 'diffs-review-compose)
  (with-temp-buffer
    (diffs-review-compose-mode)
    (let ((attachment
           (list :id "diffs-attachment:delete-test"
                 :label "Image #1"
                 :bytes 3
                 :data "png")))
      (setq diffs--review-compose-attachments (list attachment))
      (diffs--review-compose-insert-attachment attachment)
      (let ((attachment-end (point)))
        (insert " trailing text")
        (should-not
         (get-text-property attachment-end
                            'diffs-review-attachment-id))
        (goto-char attachment-end))
      (diffs-review-compose-delete-attachment)
      (should (equal (buffer-string) " trailing text"))
      (should-not diffs--review-compose-attachments))))

(ert-deftest diffs-review-image-attachments-stay-in-live-session ()
  (diffs-tests--with-diff diffs-tests--normal
    (let ((owner (current-buffer)) draft attachment-id annotation-id)
      (save-window-excursion
        (switch-to-buffer owner)
        (diffs-minor-mode 1)
        (goto-char (point-min))
        (re-search-forward "^+(message \"new\")")
        (beginning-of-line)
        (call-interactively #'diffs-review-add-annotation)
        (setq draft (current-buffer))
        (insert "The screenshot shows the failure.\n\n")
        (let ((diffs-review-image-max-bytes 1))
          (should-error
           (diffs-review-compose-yank-image
            'image/png diffs-tests--png)
           :type 'user-error))
        (should-error
         (diffs-review-compose-yank-image 'image/png "not an image")
         :type 'user-error)
        (should-error
         (diffs-review-compose-yank-image 'image/jpeg diffs-tests--png)
         :type 'user-error)
        (should-error
         (diffs-review-compose-yank-image
          'image/png
          (string-make-unibyte "\x89PNG\r\n\x1a\n"))
         :type 'user-error)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'create-image)
                   (lambda (&rest _) (error "Injected decoder failure"))))
          (should-error
           (diffs-review-compose-yank-image 'image/png diffs-tests--png)
           :type 'user-error))
        (cl-letf (((symbol-function 'gui-get-selection)
                   (lambda (_selection target)
                     (pcase target
                       ('TARGETS [image/png])
                       ('image/png diffs-tests--png)))))
          (diffs-review-compose-yank))
        (let ((attachment (car diffs--review-compose-attachments)))
          (setq attachment-id (plist-get attachment :id))
          (should (equal (plist-get attachment :mime) "image/png"))
          (should (equal (buffer-substring-no-properties
                          (- (point) (length "[Image #1]")) (point))
                         "[Image #1]"))
          (should (equal (get-text-property
                          (1- (point)) 'diffs-review-attachment-id)
                         attachment-id)))
        (diffs-review-compose-submit)
        (should-not (buffer-live-p draft))
        (should (eq (current-buffer) owner))
        (let* ((annotation (car diffs--review-annotations))
               (metadata (car (plist-get annotation :attachments)))
               (comments
                (json-parse-string
                 (diffs-review-comments-json nil "user")
                 :object-type 'alist :array-type 'list))
               (comment
                (car (diffs--review-json-value comments "comments")))
               (json-metadata
                (car (diffs--review-json-value comment "attachments")))
               (payload
                (json-parse-string
                 (diffs-review-attachment-json nil attachment-id)
                 :object-type 'alist)))
          (setq annotation-id (plist-get annotation :id))
          (should (equal (plist-get annotation :rationale) "[Image #1]"))
          (should (equal (plist-get metadata :id) attachment-id))
          (should (= (length diffs--review-attachments) 1))
          (should (equal (diffs--review-json-value json-metadata "id")
                         attachment-id))
          (should-not (diffs--review-json-value json-metadata "data"))
          (should (equal
                   (base64-decode-string
                    (diffs--review-json-value payload "data"))
                   diffs-tests--png))
          (should-error (diffs-review-sidecar-json) :type 'user-error)
          (diffs-review-remove-comment-json nil annotation-id)
          (should-not diffs--review-annotations)
          (should-not diffs--review-attachments))
        (diffs-minor-mode -1)))))

(ert-deftest diffs-review-owner-kill-discards-its-comment-draft ()
  (let ((owner (generate-new-buffer " *diffs review owner kill test*"))
        draft)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer owner
            (insert diffs-tests--normal)
            (diff-mode)
            (diffs-minor-mode 1))
          (switch-to-buffer owner)
          (goto-char (point-min))
          (re-search-forward "^+(message \"new\")")
          (beginning-of-line)
          (call-interactively #'diffs-review-add-annotation)
          (setq draft (current-buffer))
          (should (buffer-live-p draft))
          (with-current-buffer owner
            (set-buffer-modified-p nil)
            (kill-buffer owner))
          (should-not (buffer-live-p draft)))
      (dolist (buffer (list draft owner))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest diffs-review-multiline-annotation-reports-rendered-height ()
  (pcase-let*
      ((`(,display . ,height)
        (diffs--review-annotation-display
         '(:summary "first\nsecond"
           :rationale "reason one\nreason two"
           :author "agent\nname"
           :source "agent"
           :file "src/example.el"
           :new-range (1 2)))))
    (should (= height 7))
    (should (= height (cl-count ?\n display)))
    (should (string-match-p
             "Agent note · agent name · src/example.el R2" display))
    (should (eq (get-text-property
                 (string-match "Agent note" display) 'face display)
                'diffs-review-annotation-heading))
    (should (eq (get-text-property
                 (string-match "first" display) 'face display)
                'diffs-review-annotation))
    (should (eq (get-text-property
                 (string-match "╭" display) 'face display)
                'diffs-review-annotation-border))))

(ert-deftest diffs-review-annotation-projectors-use-live-pixel-geometry ()
  (diffs-tests--with-diff diffs-tests--normal
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (re-search-forward "^+(message \"new\")")
      (beginning-of-line)
      (diffs-review-add-annotation
       "[Image #1] mixed 中文 👌\nshort\n中" nil)
      (pcase-let ((`(,display . ,prefix)
                   (diffs-tests--review-annotation-projection
                    "[Image #1] mixed 中文 👌")))
        (should (> prefix 0))
        (should
         (= (diffs-tests--review-annotation-align-position display)
            (diffs-tests--review-annotation-expected-right-edge
             display prefix))))
      (diffs-toggle-split)
      (pcase-let ((`(,display . ,prefix)
                   (diffs-tests--review-annotation-projection
                    "[Image #1] mixed 中文 👌")))
        (should (> prefix 0))
        (should
         (= (diffs-tests--review-annotation-align-position display)
            (diffs-tests--review-annotation-expected-right-edge
             display prefix))))
      (diffs-split-quit)
      (diffs-minor-mode -1))))

(ert-deftest diffs-review-display-metric-hooks-reproject-annotations ()
  (diffs-tests--with-diff diffs-tests--normal
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (re-search-forward "^+(message \"new\")")
      (beginning-of-line)
      (diffs-review-add-annotation "metric-sensitive-note" nil)
      (cl-letf (((symbol-function 'string-pixel-width)
                 (lambda (string &optional _buffer)
                   (if (string-match-p "╭" string) 211 71))))
        (run-hooks 'text-scale-mode-hook)
        (should
         (= (diffs-tests--review-annotation-align-position
             (car (diffs-tests--review-annotation-projection
                   "metric-sensitive-note")))
            282)))
      (diffs-toggle-split)
      (cl-letf (((symbol-function 'string-pixel-width)
                 (lambda (string &optional _buffer)
                   (if (string-match-p "╭" string) 241 83))))
        (run-hooks 'text-scale-mode-hook)
        (should
         (= (diffs-tests--review-annotation-align-position
             (car (diffs-tests--review-annotation-projection
                   "metric-sensitive-note")))
            324)))
      (diffs-split-quit)
      (diffs-minor-mode -1))))

(ert-deftest diffs-review-opposite-split-comments-share-one-lane ()
  (diffs-tests--with-diff diffs-tests--normal
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (re-search-forward "^-(message \"old\")")
      (beginning-of-line)
      (diffs-review-add-annotation "Old-side note." nil)
      (diffs-review-clear-selection)
      (goto-char (point-min))
      (re-search-forward "^+(message \"new\")")
      (beginning-of-line)
      (diffs-review-add-annotation
       "New-side note."
       "This side is taller.\nIt still shares the same lane.")
      (diffs-toggle-split)
      (let ((new-buffer (current-buffer))
            (old-buffer diffs--split-other))
        (cl-labels
            ((annotation-string
              (buffer)
              (with-current-buffer buffer
                (let ((strings
                       (cl-loop for overlay in diffs--review-overlays
                                for string = (overlay-get overlay 'after-string)
                                when (stringp string) collect string)))
                  (should (= (length strings) 1))
                  (car strings)))))
          (let ((old-string (annotation-string old-buffer))
                (new-string (annotation-string new-buffer)))
            (should (string-match-p "Old-side note" old-string))
            (should (string-match-p "New-side note" new-string))
            (should (= (cl-count ?\n old-string)
                       (cl-count ?\n new-string))))))
      (diffs-split-quit)
      (diffs-minor-mode -1))))

(ert-deftest diffs-split-clearing-selection-removes-all-selection-face ()
  (let ((buf (generate-new-buffer " *diffs split selection face test*"))
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-(message")
          (beginning-of-line)
          (diffs-review-select)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (with-current-buffer old-buf
            (goto-char (point-min))
            (re-search-forward "(message \"old\")")
            (let ((position (match-beginning 0)))
              (should
               (cl-some
                (lambda (overlay)
                  (eq (overlay-get overlay 'face)
                      'diffs-review-selection))
                (overlays-at position)))
              (diffs-review-clear-selection)
              (should-not
               (cl-some
                (lambda (overlay)
                  (eq (overlay-get overlay 'face)
                      'diffs-review-selection))
                (overlays-at position)))
              (should-not
               (diffs-tests--face-includes-p
                (get-text-property position 'face)
                'diffs-review-selection))))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-review-decisions-preview-and-reset-in-both-layouts ()
  (let ((buf (generate-new-buffer " *diffs decision preview test*"))
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--two-change-blocks)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (select-window (get-buffer-window old-buf))
          (goto-char (point-min))
          (search-forward "old one")
          (beginning-of-line)
          ;; Exercise the public command from the default unresolved
          ;; split path, including its paired-row origin fallback.
          (diffs-review-accept-change)
          (setq old-buf (current-buffer)
                new-buf diffs--split-other)
          (should
           (= (length
               (buffer-local-value 'diffs--review-decisions buf))
              1))
          (dolist (split (list old-buf new-buf))
            (with-current-buffer split
              (goto-char (point-min))
              (should (search-forward "Kept change" nil t))
              (forward-line 1)
              (should (equal
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       "new one"))))
          (with-current-buffer old-buf
            (goto-char (point-min))
            (search-forward "Kept change")
            (beginning-of-line)
            (diffs-review-reset-change))
          (should-not
           (buffer-local-value 'diffs--review-decisions buf))
          (let ((split
                 (plist-get
                  (buffer-local-value 'diffs--split-cache buf)
                  :new)))
            (with-current-buffer split
              (should (derived-mode-p 'diffs-split-mode))
              (diffs-split-quit)))
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "^+new one")
            (beginning-of-line)
            (diffs-review-reject-change t)
            (should (= (length diffs--review-decisions) 2))
            (should
             (cl-every
              (lambda (entry)
                (eq (plist-get (cdr entry) :action) 'reject))
              diffs--review-decisions))
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-review-split-decision-defers-hidden-owner-projection ()
  (let ((buf (generate-new-buffer " *diffs deferred decision test*"))
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--two-change-blocks)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (select-window (get-buffer-window old-buf))
          (goto-char (point-min))
          (search-forward "old one")
          (beginning-of-line)
          (let ((original
                 (symbol-function
                  'diffs--review-project-unified-decisions))
                (owner-projections 0))
            (cl-letf
                (((symbol-function
                   'diffs--review-project-unified-decisions)
                  (lambda (owner decisions)
                    (cl-incf owner-projections)
                    (funcall original owner decisions))))
              (diffs-review-accept-change)
              ;; Rebuilding the visible split must not spend time projecting
              ;; a decision preview into its now-hidden unified owner.
              (should (= owner-projections 0))
              ;; A consecutive decision also returns through owner only as a
              ;; layout implementation detail; it must keep deferring.
              (diffs-review-reject-change)
              (should (= owner-projections 0))
              (should
               (buffer-local-value
                'diffs--review-owner-overlays-stale buf))
              (with-current-buffer buf
                (goto-char (point-min))
                (search-forward "-old one")
                (beginning-of-line)
                (should-not
                 (eq (get-char-property (point) 'invisible)
                     'diffs-resolution)))
              (diffs-split-quit)
              ;; A real return to stacked projects exactly once, before the
              ;; restored owner becomes interactive.
              (should (= owner-projections 1))
              (should-not
               (buffer-local-value
                'diffs--review-owner-overlays-stale buf))
              (with-current-buffer buf
                (goto-char (point-min))
                (search-forward "+new one")
                (beginning-of-line)
                (should
                 (eq (get-char-property (point) 'invisible)
                     'diffs-resolution)))))
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-resolved-split-copies-retain-the-chosen-source-side ()
  (let ((buf (generate-new-buffer " *diffs resolved source side test*"))
        old-buf new-buf)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert diffs-tests--two-change-blocks)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^+new one")
          (beginning-of-line)
          (diffs-review-accept-change)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          ;; The accepted new-side row is visually copied into the old
          ;; column, but selecting that copy must still create a newRange.
          (with-current-buffer old-buf
            (goto-char (point-min))
            (search-forward "new one")
            (beginning-of-line)
            (diffs-review-select))
          (should
           (equal
            (buffer-local-value 'diffs--review-selection buf)
            '(:file "two.el" :side new :start 2 :end 2)))
          (with-current-buffer old-buf
            (diffs-review-clear-selection))
          (diffs-split-quit)
          (diffs-review-reset-change t)
          (goto-char (point-min))
          (re-search-forward "^-old one")
          (beginning-of-line)
          (diffs-review-reject-change)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          ;; The rejected old-side row is likewise copied into the new
          ;; column without becoming a synthetic new-side source line.
          (with-current-buffer new-buf
            (goto-char (point-min))
            (search-forward "old one")
            (beginning-of-line)
            (diffs-review-select))
          (should
           (equal
            (buffer-local-value 'diffs--review-selection buf)
            '(:file "two.el" :side old :start 2 :end 2)))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-resolved-copies-keep-source-lines-after-result-shifts ()
  (dolist
      (case
       `((,diffs-tests--addition-before-change
          accept reject new "old value" old 3 4 :old-range)
         (,diffs-tests--deletion-before-change
          reject accept old "new value" new 3 3 :new-range)))
    (pcase-let
        ((`(,patch ,first-action ,second-action ,display-role ,text
                   ,source-side ,source-line ,target-line ,range-property)
          case))
      (let ((buffer
             (generate-new-buffer " *diffs shifted source identity test*"))
            old-buffer new-buffer)
        (unwind-protect
            (save-window-excursion
              (switch-to-buffer buffer)
              (insert patch)
              (diff-mode)
              (diffs-minor-mode 1)
              (let ((blocks (diffs--resolution-all-blocks buffer)))
                (diffs--resolution-set-decisions
                 buffer (list (nth 0 blocks)) first-action)
                (diffs--resolution-set-decisions
                 buffer (list (nth 1 blocks)) second-action))
              (diffs-toggle-split)
              (setq new-buffer (current-buffer)
                    old-buffer diffs--split-other)
              (with-current-buffer
                  (if (eq display-role 'old) old-buffer new-buffer)
                (goto-char (point-min))
                (search-forward text)
                (beginning-of-line)
                ;; The prefix is the decision-adjusted result line, while
                ;; review identity remains the immutable patch-side line.
                (let ((row (diffs--split-row-at-position (point))))
                  (should (= (nth 1 row) 4))
                  (should (= (diffs--split-row-source-number row)
                             source-line))
                  (should
                   (equal (diffs--split-property-at 'diffs-src (point))
                          (cons "shift.el" target-line)))
                  (should (eq (diffs--split-row-source-side row)
                              source-side)))
                (diffs-review-select)
                (diffs-review-add-annotation "Stable source line." ""))
              (let* ((annotation
                      (car
                       (buffer-local-value
                        'diffs--review-annotations buffer)))
                     (range (plist-get annotation range-property))
                     (sidecar
                      (with-current-buffer buffer
                        (diffs-review-sidecar-json)))
                     (field
                      (if (eq range-property :old-range)
                          "oldRange"
                        "newRange")))
                (should (equal range (list source-line source-line)))
                (should
                 (string-match-p
                  (format "\"%s\":\\[%d,%d\\]"
                          field source-line source-line)
                  sidecar))
                (should-not
                 (string-match-p
                  (format "\"%s\":\\[4,4\\]" field)
                  sidecar)))
              (diffs-split-quit)
              (with-current-buffer buffer
                (diffs-minor-mode -1)))
          (dolist (candidate (list old-buffer new-buffer buffer))
            (when (buffer-live-p candidate)
              (kill-buffer candidate))))))))

(ert-deftest diffs-split-ret-keeps-current-target-after-result-shift ()
  (let* ((directory (make-temp-file "diffs shifted RET-" t))
         (file (expand-file-name "shift.el" directory))
         (source
          (concat "same\n" "inserted\n" "middle\n"
                  "new value\n" "tail\n"))
         (buffer (generate-new-buffer " *diffs shifted RET test*"))
         old-buffer new-buffer source-buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert source))
          (switch-to-buffer buffer)
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--addition-before-change)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^+inserted")
          (beginning-of-line)
          (diffs-review-accept-change)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "old value")
          (beginning-of-line)
          (let ((row (diffs--split-row-at-position (point))))
            (should (= (nth 1 row) 4))
            (should (= (diffs--split-row-source-number row) 3))
            (should
             (equal (diffs--split-property-at 'diffs-src (point))
                    '("shift.el" . 4))))
          (diffs-split-goto-source)
          (setq source-buffer (current-buffer))
          (should (equal (buffer-file-name) file))
          (should (= (line-number-at-pos) 4))
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "new value")))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate)))
      (delete-directory directory t))))

(ert-deftest diffs-reset-decision-restores-the-original-split-block ()
  (let ((buffer (generate-new-buffer " *diffs reset anchor test*"))
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert diffs-tests--two-change-blocks)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "old two")
          (beginning-of-line)
          (diffs-review-reject-change)
          (should (eq diffs--split-role 'old))
          (should (string-match-p
                   "Rejected change"
                   (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))))
          (diffs-review-reset-change)
          (should (eq diffs--split-role 'old))
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "old two"))
          (let ((row (diffs--split-row-at-position (point))))
            (should (equal (nth 4 row) "two.el"))
            (should (eq (nth 3 row) 'del))
            (should (eq (diffs--split-row-source-side row) 'old))
            (should (= (diffs--split-row-source-number row) 4)))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-review-apply-preserves-a-nondecision-split-anchor ()
  (let* ((directory (make-temp-file "diffs apply anchor-" t))
         (file (expand-file-name "foo.el" directory))
         (source
          (concat
           "(message \"same\")\n"
           "(message \"new\")\n"
           "(message \"extra\")\n"))
         (buffer (generate-new-buffer " *diffs apply anchor test*"))
         old-buffer new-buffer source-buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert source))
          (switch-to-buffer buffer)
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^+(message \"new\")")
          (beginning-of-line)
          (diffs-review-accept-change)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          ;; The accepted new-side row is copied into the old display column.
          ;; It has no decision key of its own, so apply must use row identity.
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "(message \"extra\")")
          (beginning-of-line)
          (move-to-column 5)
          (let* ((row (diffs--split-row-at-position (point)))
                 (hunk (nth 5 row))
                 (window-line
                  (count-screen-lines
                   (window-start) (line-beginning-position))))
            (should-not (diffs--split-row-resolution-key row))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions))
            (should (derived-mode-p 'diffs-split-mode))
            (should (eq diffs--split-role 'old))
            (should (= (current-column) 5))
            (should
             (= (count-screen-lines
                 (window-start) (line-beginning-position))
                window-line))
            (setq row (diffs--split-row-at-position (point)))
            (should (equal (nth 4 row) "foo.el"))
            (should (equal (nth 5 row) hunk))
            (should (eq (nth 3 row) 'ctx))
            (should (eq (diffs--split-row-source-side row) 'new))
            (should (= (diffs--split-row-source-number row) 3))
            (should
             (equal
              (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))
              "(message \"extra\")")))
          (setq source-buffer (find-buffer-visiting file))
          (should (buffer-live-p source-buffer))
          (with-current-buffer source-buffer
            (should-not (buffer-modified-p)))
          (diffs-split-quit)
          (with-current-buffer buffer
            (diffs-minor-mode -1)))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate)))
      (delete-directory directory t))))

(ert-deftest diffs-review-apply-updates-live-targets-independently ()
  (let* ((directory (make-temp-file "diffs live target-" t))
         (file (expand-file-name "shift.el" directory))
         (source (concat "same\n" "middle\n" "new value\n" "tail\n"))
         (buffer (generate-new-buffer " *diffs live target test*"))
         old-buffer new-buffer source-buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert source))
          (switch-to-buffer buffer)
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--deletion-before-change)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-removed")
          (beginning-of-line)
          (diffs-review-reject-change)
          (goto-char (point-min))
          (re-search-forward "^+new value")
          (beginning-of-line)
          (diffs-review-accept-change)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "new value")
          (beginning-of-line)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) t)))
            (diffs-review-apply-decisions))
          (let ((row (diffs--split-row-at-position (point))))
            ;; Preview and live worktree both place this row at four, while
            ;; comments retain its immutable new-side source line three.
            (should (= (nth 1 row) 4))
            (should (= (diffs--split-row-source-number row) 3))
            (should
             (equal (diffs--split-property-at 'diffs-src (point))
                    '("shift.el" . 4))))
          ;; A later pending preview decision must not undo the live shift
          ;; contributed by the already-applied preceding rejection.
          (diffs-review-reject-change)
          (goto-char (point-min))
          (search-forward "old value")
          (beginning-of-line)
          (let* ((row (diffs--split-row-at-position (point)))
                 (decisions
                  (buffer-local-value 'diffs--review-decisions buffer))
                 (decision
                  (cl-find-if
                   (lambda (entry)
                     (= (plist-get (cdr entry) :index) 1))
                   decisions)))
            (should (= (nth 1 row) 4))
            (should (= (diffs--split-row-source-number row) 4))
            (should
             (equal (diffs--split-property-at 'diffs-src (point))
                    '("shift.el" . 4)))
            (should (eq (plist-get (cdr decision) :action) 'reject))
            (should-not (plist-get (cdr decision) :applied))
            (should (eq (plist-get (cdr decision) :source-action)
                        'accept)))
          (diffs-split-goto-source)
          (setq source-buffer (current-buffer))
          (should (equal (buffer-file-name) file))
          (should (= (line-number-at-pos) 4))
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "new value")))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate)))
      (delete-directory directory t))))

(ert-deftest diffs-review-reset-keeps-applied-source-coordinate-state ()
  (let* ((directory (make-temp-file "diffs reset live target-" t))
         (file (expand-file-name "shift.el" directory))
         (source (concat "same\n" "middle\n" "new value\n" "tail\n"))
         (buffer (generate-new-buffer " *diffs reset live target test*"))
         source-buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert source))
          (switch-to-buffer buffer)
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--deletion-before-change)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-removed")
          (beginning-of-line)
          (diffs-review-reject-change)
          (diffs-toggle-split)
          (goto-char (point-min))
          (search-forward "removed")
          (beginning-of-line)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) t)))
            (diffs-review-apply-decisions))
          (goto-char (point-min))
          (search-forward "removed")
          (beginning-of-line)
          (diffs-review-reset-change)
          (should-not
           (buffer-local-value 'diffs--review-decisions buffer))
          (let ((source-actions
                 (buffer-local-value
                  'diffs--review-source-actions buffer)))
            (should (= (length source-actions) 1))
            (should (eq (plist-get (cdar source-actions) :action)
                        'reject)))
          ;; U resets only the preview decision.  The source still contains
          ;; the restored deletion, so the later unresolved block lives one
          ;; line below its immutable new-side review coordinate.
          (select-window
           (get-buffer-window
            (plist-get
             (buffer-local-value 'diffs--split-cache buffer)
             :new)))
          (goto-char (point-min))
          (search-forward "new value")
          (beginning-of-line)
          (let ((row (diffs--split-row-at-position (point))))
            (should (= (diffs--split-row-source-number row) 3))
            (should
             (equal (diffs--split-property-at 'diffs-src (point))
                    '("shift.el" . 4))))
          (diffs-split-goto-source)
          (setq source-buffer (current-buffer))
          (should (= (line-number-at-pos) 4))
          (should
           (equal
            (buffer-substring-no-properties
             (line-beginning-position) (line-end-position))
            "new value"))
          ;; A later decision is reconciled at that live coordinate rather
          ;; than overwriting the preceding applied source state.
          (pop-to-buffer
           (plist-get
            (buffer-local-value 'diffs--split-cache buffer)
            :new))
          (goto-char (point-min))
          (search-forward "new value")
          (beginning-of-line)
          (diffs-review-reject-change)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) t)))
            (diffs-review-apply-decisions))
          (setq source-buffer (find-buffer-visiting file))
          (with-current-buffer source-buffer
            (goto-char (point-min))
            (forward-line 3)
            (should
             (equal
              (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))
              "old value"))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (let ((cache
             (and (buffer-live-p buffer)
                  (buffer-local-value 'diffs--split-cache buffer))))
        (dolist (candidate
                 (list (plist-get cache :old)
                       (plist-get cache :new)
                       buffer))
          (when (buffer-live-p candidate)
            (kill-buffer candidate))))
      (delete-directory directory t))))

(ert-deftest diffs-review-reset-maps-each-restored-old-row-to-source ()
  (let* ((directory (make-temp-file "diffs unequal live target-" t))
         (file (expand-file-name "unequal.el" directory))
         (source
          (concat
           (mapconcat
            (lambda (line) (format "prefix %d" line))
            (number-sequence 1 8) "\n")
           "\n"
           "same\nnew combined\nmiddle\nnew later\ntail\n"))
         (buffer
          (generate-new-buffer " *diffs unequal live target test*"))
         source-buffer)
    (unwind-protect
        (save-window-excursion
          (with-temp-file file
            (insert source))
          (switch-to-buffer buffer)
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--unequal-replacement-before-change)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-old first")
          (beginning-of-line)
          (diffs-review-reject-change)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) t)))
            (diffs-review-apply-decisions))
          (goto-char (point-min))
          (re-search-forward "^-old first")
          (beginning-of-line)
          (diffs-review-reset-change)
          (should-not diffs--review-decisions)
          (should
           (eq
            (plist-get (cdar diffs--review-source-actions) :action)
            'reject))
          (cl-labels
              ((visit-row
                (role text display-number source-number target-number)
                (pop-to-buffer buffer)
                (diffs-toggle-split)
                (let* ((cache
                        (buffer-local-value
                         'diffs--split-cache buffer))
                       (view
                        (plist-get
                         cache (if (eq role 'old) :old :new))))
                  (select-window (get-buffer-window view))
                  (goto-char (point-min))
                  (search-forward text)
                  (beginning-of-line)
                  (let ((row (diffs--split-row-at-position (point))))
                    (should (= (nth 1 row) display-number))
                    (should
                     (= (diffs--split-row-source-number row)
                        source-number))
                    (should
                     (eq (diffs--split-row-source-side row) role))
                    (should
                     (equal
                      (diffs--split-property-at 'diffs-src (point))
                      (cons "unequal.el" target-number))))
                  (diffs-split-goto-source)
                  (setq source-buffer (current-buffer))
                  (should (= (line-number-at-pos) target-number))
                  (should
                   (equal
                    (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))
                    text)))))
            ;; Both restored old lines retain their immutable old-side
            ;; identities while addressing distinct physical source lines.
            (visit-row 'old "old first" 10 10 10)
            (visit-row 'old "old second" 11 11 11)
            ;; The applied 2→1 rejection still shifts every later block.
            (visit-row 'new "new later" 12 12 13)))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (let ((cache
             (and (buffer-live-p buffer)
                  (buffer-local-value 'diffs--split-cache buffer))))
        (dolist (candidate
                 (list (plist-get cache :old)
                       (plist-get cache :new)
                       buffer))
          (when (buffer-live-p candidate)
            (kill-buffer candidate))))
      (delete-directory directory t))))

(ert-deftest diffs-review-refresh-revalidates-applied-source-actions ()
  (let* ((directory (make-temp-file "diffs source action refresh-" t))
         (file (expand-file-name "shift.el" directory))
         (source (concat "same\n" "middle\n" "new value\n" "tail\n"))
         (buffer
          (generate-new-buffer " *diffs source action refresh test*"))
         (next-patch diffs-tests--deletion-before-change)
         regenerator source-buffer generation key)
    (unwind-protect
        (with-current-buffer buffer
          (with-temp-file file
            (insert source))
          (setq default-directory (file-name-as-directory directory))
          (insert diffs-tests--deletion-before-change)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^-removed")
          (beginning-of-line)
          (diffs-review-reject-change)
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) t)))
            (diffs-review-apply-decisions))
          (setq source-buffer (find-buffer-visiting file)
                generation diffs--review-generation
                key (caar diffs--review-source-actions)
                regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          (file-name-as-directory directory))))
                    (with-current-buffer staged
                      (insert next-patch))
                    (diffs--present
                     staged nil nil nil regenerator)))
                diffs--regenerator regenerator)
          (diffs-refresh)
          (let ((source-action
                 (alist-get key diffs--review-source-actions
                            nil nil #'equal)))
            (should source-action)
            (should (eq (plist-get source-action :action) 'reject))
            (should
             (= (plist-get source-action :generation)
                (1+ generation))))
          ;; A refresh whose patch no longer contains the same fingerprint
          ;; must not let its old coordinate shift leak into the new view.
          (setq next-patch diffs-tests--hidden-context)
          (diffs-refresh)
          (should-not diffs--review-source-actions))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest diffs-split-decision-rebuild-failure-rolls-back-view-and-state ()
  (let ((buffer (generate-new-buffer " *diffs decision rollback test*"))
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert diffs-tests--two-change-blocks)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "old two")
          (beginning-of-line)
          (move-to-column 3)
          (let ((original (symbol-function 'diffs-toggle-split))
                (calls 0))
            (cl-letf
                (((symbol-function 'diffs-toggle-split)
                  (lambda ()
                    (cl-incf calls)
                    (if (= calls 1)
                        (error "Synthetic split rebuild failure")
                      (funcall original)))))
              (should-error (diffs-review-reject-change))
              (should (= calls 2))))
          (should-not
           (buffer-local-value 'diffs--review-decisions buffer))
          (should (derived-mode-p 'diffs-split-mode))
          (should (eq diffs--split-role 'old))
          (should (= (current-column) 3))
          (let ((row (diffs--split-row-at-position (point))))
            (should (equal (nth 4 row) "two.el"))
            (should (eq (nth 3 row) 'del))
            (should (eq (diffs--split-row-source-side row) 'old))
            (should (= (diffs--split-row-source-number row) 4))
            (should
             (equal
              (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))
              "old two")))
          (should (get-buffer-window diffs--split-other))
          (with-current-buffer buffer
            (should-not diffs--review-owner-overlays-stale)
            (goto-char (point-min))
            (re-search-forward "^-old two")
            (beginning-of-line)
            (should-not
             (eq (get-char-property (point) 'invisible)
                 'diffs-resolution))
            (diffs-minor-mode -1)))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-review-decisions-collapse-stacked-discarded-side ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (goto-char (point-min))
    (search-forward "+(message \"new\")")
    (beginning-of-line)
    (diffs-review-accept-change)
    (goto-char (point-min))
    (search-forward "-(message \"old\")")
    (beginning-of-line)
    (should
     (eq (get-char-property (point) 'invisible)
         'diffs-resolution))
    (diffs-review-reset-change)
    (should-not
     (eq (get-char-property (point) 'invisible)
         'diffs-resolution))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-decisions-adjust-later-result-line-numbers ()
  (diffs-tests--with-diff diffs-tests--addition-before-change
    (diffs-minor-mode 1)
    (let* ((blocks (diffs--resolution-all-blocks (current-buffer)))
           (first (car blocks)))
      (diffs--resolution-set-decisions
       (current-buffer) (list first) 'accept)
      (let* ((snapshot
              (json-parse-string
               (diffs-review-json)
               :object-type 'alist :array-type 'list))
             (file
              (car (diffs--review-json-value snapshot "files")))
             (decision
              (car (diffs--review-json-value file "decisions"))))
        (should
         (equal (diffs--review-json-value decision "action")
                "accept")))
      (pcase-let* ((`(,old-rows ,new-rows . ,_)
                    (diffs--split-collect))
                   (old
                    (cl-find "old value" old-rows
                             :key #'car :test #'equal))
                   (new
                    (cl-find "new value" new-rows
                             :key #'car :test #'equal)))
        ;; Accepting the preceding insertion grows the old result side
        ;; by one, so the later unresolved pair meets at line four.
        (should (= (nth 1 old) 4))
        (should (= (nth 1 new) 4))))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-applies-rejections-without-saving-source ()
  (let* ((directory (make-temp-file "diffs-decision-" t))
         (file (expand-file-name "foo.el" directory))
         (source
          (concat
           "(message \"same\")\n"
           "(message \"new\")\n"
           "(message \"extra\")\n"))
         diff-buffer source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert source))
          (setq diff-buffer
                (generate-new-buffer " *diffs decision apply test*"))
          (with-current-buffer diff-buffer
            (setq default-directory (file-name-as-directory directory))
            (insert diffs-tests--normal)
            (diff-mode)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (search-forward "+(message \"new\")")
            (beginning-of-line)
            (diffs-review-reject-change)
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions))
            (should
             (plist-get (cdar diffs--review-decisions) :applied)))
          (setq source-buffer (find-buffer-visiting file))
          (should (buffer-live-p source-buffer))
          (with-current-buffer source-buffer
            (should (buffer-modified-p))
            (should
             (equal
              (buffer-substring-no-properties (point-min) (point-max))
              (concat
               "(message \"same\")\n"
               "(message \"old\")\n"))))
          (with-temp-buffer
            (insert-file-contents file)
            (should
             (equal
              (buffer-substring-no-properties (point-min) (point-max))
              source))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-reject-restores-context-zero-deletion-position ()
  (let* ((directory (make-temp-file "diffs-zero-deletion-" t))
         (file (expand-file-name "pure.el" directory))
         (diff-buffer
          (generate-new-buffer " *diffs zero deletion test*"))
         source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "before\n"))
          (with-current-buffer diff-buffer
            (setq default-directory (file-name-as-directory directory))
            (insert diffs-tests--context-zero-deletion)
            (diff-mode)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (search-forward "-removed")
            (beginning-of-line)
            (diffs-review-reject-change)
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions)))
          (setq source-buffer (find-buffer-visiting file))
          (with-current-buffer source-buffer
            (should
             (equal
              (buffer-substring-no-properties (point-min) (point-max))
              "before\nremoved\n"))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-apply-reconciles-action-changes-and-source-undo ()
  (let* ((directory (make-temp-file "diffs-reconcile-" t))
         (file (expand-file-name "foo.el" directory))
         (source
          (concat
           "(message \"same\")\n"
           "(message \"new\")\n"
           "(message \"extra\")\n"))
         (diff-buffer
          (generate-new-buffer " *diffs reconcile apply test*"))
         source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert source))
          (with-current-buffer diff-buffer
            (setq default-directory (file-name-as-directory directory))
            (insert diffs-tests--normal)
            (diff-mode)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (re-search-forward "^+(message \"new\")")
            (beginning-of-line)
            (diffs-review-reject-change)
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions))
            (setq source-buffer (find-buffer-visiting file))
            (with-current-buffer source-buffer
              (should
               (equal (buffer-substring-no-properties
                       (point-min) (point-max))
                      (concat
                       "(message \"same\")\n"
                       "(message \"old\")\n")))
              (undo-boundary))
            ;; Changing the decision after it was applied must restore
            ;; the new side instead of treating accept as a no-op.
            (goto-char (point-min))
            (re-search-forward "^+(message \"new\")")
            (beginning-of-line)
            (diffs-review-accept-change)
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions))
            (with-current-buffer source-buffer
              (should
               (equal (buffer-substring-no-properties
                       (point-min) (point-max))
                      source))
              ;; Undoing in the source invalidates the observed result
              ;; even if the decision still carries its applied label.
              (undo-boundary)
              (undo-only)
              (should
               (string-match-p
                "old"
                (buffer-substring-no-properties
                 (point-min) (point-max)))))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions)))
          (with-current-buffer source-buffer
            (should
             (equal (buffer-substring-no-properties
                     (point-min) (point-max))
                    source))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-apply-rejects-historical-and-escaping-paths ()
  (let* ((directory (make-temp-file "diffs-confine-" t))
         (repository (expand-file-name "repository" directory))
         (outside (expand-file-name "outside.el" directory))
         (inside (expand-file-name "foo.el" repository))
         (diff-buffer
          (generate-new-buffer " *diffs confined apply test*")))
    (unwind-protect
        (progn
          (make-directory repository)
          (with-temp-file inside
            (insert "(message \"same\")\n"
                    "(message \"new\")\n"
                    "(message \"extra\")\n"))
          (with-temp-file outside
            (insert "new outside\n"))
          (with-current-buffer diff-buffer
            (setq default-directory
                  (file-name-as-directory repository))
            (insert diffs-tests--normal)
            (diff-mode)
            (diffs-minor-mode 1)
            (diffs--resolution-set-decisions
             diff-buffer
             (diffs--resolution-all-blocks diff-buffer)
             'reject)
            (setq diffs--target-revision "deadbeef")
            (should-error
             (cl-letf (((symbol-function 'yes-or-no-p)
                        (lambda (&rest _)
                          (ert-fail "historical review prompted"))))
               (diffs-review-apply-decisions))
             :type 'user-error)
            (setq diffs--target-revision nil)
            (setf (plist-get (cdar diffs--review-decisions) :file)
                  "../outside.el")
            (should-error
             (cl-letf (((symbol-function 'yes-or-no-p)
                        (lambda (&rest _) t)))
               (diffs-review-apply-decisions))
             :type 'user-error))
          (with-temp-buffer
            (insert-file-contents outside)
            (should (equal (buffer-string) "new outside\n"))))
      (when-let* ((buffer (find-buffer-visiting inside)))
        (kill-buffer buffer))
      (when-let* ((buffer (find-buffer-visiting outside)))
        (kill-buffer buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-apply-rolls-back-a-multibuffer-batch ()
  (let* ((directory (make-temp-file "diffs-multibuffer-" t))
         (bar-file (expand-file-name "bar.el" directory))
         (foo-file (expand-file-name "foo.el" directory))
         (diff-buffer
          (generate-new-buffer " *diffs multibuffer apply test*"))
         bar-buffer foo-buffer hook-fired)
    (unwind-protect
        (progn
          (with-temp-file bar-file (insert "new bar\n"))
          (with-temp-file foo-file (insert "new foo\n"))
          (setq bar-buffer (find-file-noselect bar-file)
                foo-buffer (find-file-noselect foo-file))
          (with-current-buffer foo-buffer
            (add-hook
             'before-change-functions
             (lambda (&rest _)
               (unless hook-fired
                 (setq hook-fired t)
                 (error "Injected second-buffer failure")))
             nil t))
          (with-current-buffer diff-buffer
            (setq default-directory
                  (file-name-as-directory directory))
            (insert diffs-tests--two-source-files)
            (diff-mode)
            (diffs-minor-mode 1)
            (diffs--resolution-set-decisions
             diff-buffer
             (diffs--resolution-all-blocks diff-buffer)
             'reject))
          (with-current-buffer foo-buffer
            (narrow-to-region (point-min) (1- (point-max))))
          (with-current-buffer diff-buffer
            (should-error
             (cl-letf (((symbol-function 'yes-or-no-p)
                        (lambda (&rest _) t)))
               (diffs-review-apply-decisions))
             :type 'user-error))
          (with-current-buffer foo-buffer
            (widen))
          (with-current-buffer diff-buffer
            (should-error
             (cl-letf (((symbol-function 'yes-or-no-p)
                        (lambda (&rest _) t)))
               (diffs-review-apply-decisions))
             :type 'error)
            (should-not
             (cl-some
              (lambda (entry)
                (plist-get (cdr entry) :applied))
              diffs--review-decisions)))
          (with-current-buffer bar-buffer
            (should (equal (buffer-string) "new bar\n")))
          (with-current-buffer foo-buffer
            (should (equal (buffer-string) "new foo\n"))))
      (dolist (buffer (list bar-buffer foo-buffer))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (kill-buffer buffer)))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-refresh-preserves-and-revalidates-live-state ()
  (let ((buffer
         (generate-new-buffer " *diffs refresh state test*"))
        (next-patch diffs-tests--normal)
        regenerator session annotation-id attachment-id generation)
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^+(message \"new\")")
          (beginning-of-line)
          (diffs-review-select)
          (setq annotation-id
                (plist-get
                 (diffs-review-add-annotation
                  "Keep this review state." "")
                 :id))
          (let* ((data diffs-tests--png)
                 (attachment
                  (list :id "diffs-attachment:refresh-test"
                        :label "Image #1"
                        :mime "image/png"
                        :bytes (string-bytes data)
                        :sha256 (secure-hash 'sha256 data)
                        :data data)))
            (setq attachment-id (plist-get attachment :id)
                  diffs--review-attachments (list attachment))
            (setf (plist-get (car diffs--review-annotations) :attachments)
                  (list (diffs--review-attachment-metadata attachment))))
          (diffs-review-reject-change)
          (setq session diffs--review-session-id
                generation diffs--review-generation
                regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert next-patch))
                    (diffs--present
                     staged nil nil nil regenerator)))
                diffs--regenerator regenerator)
          (diffs-refresh)
          (should (equal diffs--review-session-id session))
          (should (= diffs--review-generation (1+ generation)))
          (should diffs--review-selection)
          (should
           (equal
            (plist-get (car diffs--review-annotations) :id)
            annotation-id))
          (should
           (equal (plist-get (car diffs--review-attachments) :id)
                  attachment-id))
          (should
           (equal (plist-get (car diffs--review-attachments) :data)
                  diffs-tests--png))
          (should
           (eq (plist-get (cdar diffs--review-decisions) :action)
               'reject))
          (should-not
           (plist-get (cdar diffs--review-decisions) :applied))
          ;; A regenerated patch with no matching locations keeps the
          ;; session identity but drops stale review coordinates.
          (setq next-patch diffs-tests--hidden-context)
          (diffs-refresh)
          (should (equal diffs--review-session-id session))
          (should-not diffs--review-selection)
          (should-not diffs--review-annotations)
          (should-not diffs--review-attachments)
          (should-not diffs--review-decisions))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-review-refresh-revalidates-dual-ranges-independently ()
  (let ((buffer
         (generate-new-buffer " *diffs dual range refresh test*"))
        regenerator)
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (setq diffs--review-annotations
                (list
                 '(:id "paired" :file "foo.el"
                   :old-range (2 2) :new-range (2 2)
                   :summary "Keep the surviving side."
                   :source "agent-context")))
          (diffs--review-refresh-overlays buffer)
          (setq regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert
                       diffs-tests--foo-context-zero-deletion))
                    (diffs--present
                     staged nil nil nil regenerator)))
                diffs--regenerator regenerator)
          (diffs-refresh)
          (let* ((annotation
                  (car diffs--review-annotations))
                 (json (diffs-review-sidecar-json)))
            (should (= (length diffs--review-annotations) 1))
            (should
             (equal (plist-get annotation :old-range) '(2 2)))
            (should-not (plist-get annotation :new-range))
            (should
             (string-match-p "\"oldRange\":\\[2,2\\]" json))
            (should-not (string-match-p "\"newRange\"" json))
            (goto-char (point-min))
            (re-search-forward "^-(message \"old\")")
            (let ((line-end (line-end-position)))
              (should
               (cl-some
                (lambda (overlay)
                  (and (= (overlay-start overlay) line-end)
                       (overlay-get overlay 'after-string)))
                diffs--review-overlays)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-review-failed-refresh-leaves-live-split-untouched ()
  (let ((buffer
         (generate-new-buffer " *diffs failed refresh test*"))
        old-buffer new-buffer index-buffer
        regenerator)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (goto-char (point-min))
          (re-search-forward "^+(message \"new\")")
          (beginning-of-line)
          (diffs-review-select)
          (diffs-review-add-annotation
           "This state must survive." "")
          (diffs-review-reject-change)
          (setq regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert "partial backend output\n"))
                    (error "Synthetic backend failure")))
                diffs--regenerator regenerator)
          (diffs-toggle-index)
          (setq index-buffer diffs--index-buffer)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "old")
          (let ((text
                 (with-current-buffer buffer
                   (buffer-substring-no-properties
                    (point-min) (point-max))))
                (session
                 (buffer-local-value
                  'diffs--review-session-id buffer))
                (generation
                 (buffer-local-value
                  'diffs--review-generation buffer))
                (selection
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-selection buffer)))
                (annotations
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-annotations buffer)))
                (decisions
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-decisions buffer)))
                (configuration
                 (current-window-configuration))
                (selected-window-before (selected-window))
                (window-buffers
                 (mapcar #'window-buffer (window-list))))
            (should-error (diffs-refresh) :type 'error)
            (should
             (compare-window-configurations
              configuration
              (current-window-configuration)))
            (should
             (eq (selected-window) selected-window-before))
            (should (eq (current-buffer) old-buffer))
            (should (derived-mode-p 'diffs-split-mode))
            (should
             (equal (mapcar #'window-buffer (window-list))
                    window-buffers))
            (should (buffer-live-p index-buffer))
            (with-current-buffer buffer
              (should diffs-minor-mode)
              (should (derived-mode-p 'diff-mode))
              (should
               (equal
                (buffer-substring-no-properties
                 (point-min) (point-max))
                text))
              (should
               (equal diffs--review-session-id session))
              (should
               (= diffs--review-generation generation))
              (should
               (equal diffs--review-selection selection))
              (should
               (equal diffs--review-annotations annotations))
              (should
               (equal diffs--review-decisions decisions)))))
      (dolist
          (candidate
           (list old-buffer new-buffer index-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-review-context-refresh-failure-precedes-adoption ()
  (let ((buffer
         (generate-new-buffer " *diffs context refresh failure test*"))
        old-buffer new-buffer index-buffer regenerator)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--hidden-context)
          (diff-mode)
          (diffs-minor-mode 1)
          (let* ((section (car diffs--sections))
                 (hunk (car (plist-get section :hunks)))
                 (gap (diffs--gap-for-hunk hunk)))
            ;; The live review already owns valid cached context.  The
            ;; staged refresh has no source file from which to reload it.
            (puthash
             section
             ["old one" "old two" "old three" "old four" "old five"]
             diffs--old-content-cache)
            (puthash
             section
             ["new one" "new two" "new three" "new four" "new five"]
             diffs--new-content-cache)
            (diffs--set-context-visible gap 2))
          (setq regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert diffs-tests--hidden-context))
                    (diffs--present
                     staged nil nil nil regenerator)))
                diffs--regenerator regenerator)
          (diffs-toggle-index)
          (setq index-buffer diffs--index-buffer)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (let ((configuration
                 (current-window-configuration))
                (selected-window-before (selected-window))
                (text
                 (with-current-buffer buffer
                   (buffer-substring-no-properties
                    (point-min) (point-max))))
                (session
                 (buffer-local-value
                  'diffs--review-session-id buffer))
                (generation
                 (buffer-local-value
                  'diffs--review-generation buffer)))
            (should-error (diffs-refresh) :type 'user-error)
            (should
             (compare-window-configurations
              configuration
              (current-window-configuration)))
            (should
             (eq (selected-window) selected-window-before))
            (should (eq (current-buffer) old-buffer))
            (should (buffer-live-p index-buffer))
            (with-current-buffer buffer
              (should diffs-minor-mode)
              (should
               (equal
                (buffer-substring-no-properties
                 (point-min) (point-max))
                text))
              (should
               (equal diffs--review-session-id session))
              (should
               (= diffs--review-generation generation))
              (let ((gap (car diffs--context-gaps)))
                (should (= (plist-get gap :visible) 2))
                (should
                 (overlayp (plist-get gap :overlay)))))))
      (dolist
          (candidate
           (list old-buffer new-buffer index-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-review-post-adoption-failure-rolls-back-owner ()
  (let ((buffer
         (generate-new-buffer " *diffs adoption rollback test*"))
        old-buffer new-buffer regenerator
        (owner-hook-runs 0))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--hidden-context)
          (diff-mode)
          (diffs-minor-mode 1)
          (add-hook
           'diff-mode-hook
           (lambda ()
             (when (eq (current-buffer) buffer)
               (cl-incf owner-hook-runs)
               (error "Owner diff-mode hook must not run during refresh")))
           nil t)
          (let* ((section (car diffs--sections))
                 (hunk (car (plist-get section :hunks)))
                 (gap (diffs--gap-for-hunk hunk)))
            (puthash
             section
             ["old one" "old two" "old three" "old four" "old five"]
             diffs--old-content-cache)
            (puthash
             section
             ["new one" "new two" "new three" "new four" "new five"]
             diffs--new-content-cache)
            (diffs--set-context-visible gap 2))
          (goto-char (point-min))
          (re-search-forward "^+new five")
          (beginning-of-line)
          (diffs-review-select)
          (diffs-review-add-annotation
           "Rollback this review state." "")
          (diffs-review-reject-change)
          (setq regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert
                       (replace-regexp-in-string
                        "new five" "new six"
                        diffs-tests--hidden-context)))
                    (diffs--present
                     staged nil nil nil regenerator)
                    (with-current-buffer staged
                      (let ((section (car diffs--sections)))
                        (puthash
                         section
                         ["old one" "old two" "old three"
                          "old four" "old five"]
                         diffs--old-content-cache)
                        (puthash
                         section
                         ["new one" "new two" "new three"
                          "new four" "new six"]
                         diffs--new-content-cache)))))
                diffs--regenerator regenerator)
          (diffs-toggle-index)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "old five")
          (beginning-of-line)
          (with-current-buffer buffer
            (set-marker (mark-marker) nil)
            (setq mark-active nil))
          (let ((configuration
                 (current-window-configuration))
                (text
                 (with-current-buffer buffer
                   (buffer-substring-no-properties
                    (point-min) (point-max))))
                (session
                 (buffer-local-value
                  'diffs--review-session-id buffer))
                (generation
                 (buffer-local-value
                  'diffs--review-generation buffer))
                (selection
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-selection buffer)))
                (annotations
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-annotations buffer)))
                (decisions
                 (copy-tree
                  (buffer-local-value
                   'diffs--review-decisions buffer))))
            (should-error
             (cl-letf
                 (((symbol-function
                    'diffs--review-restore-refreshed-state)
                   (lambda (&rest _)
                     (error "Injected post-adoption failure"))))
               (diffs-refresh))
             :type 'error)
            (should
             (compare-window-configurations
              configuration
              (current-window-configuration)))
            (should (= owner-hook-runs 0))
            (should (derived-mode-p 'diffs-split-mode))
            (should (eq diffs--split-role 'old))
            (should
             (equal
              (diffs--split-property-at
               'diffs-src (line-beginning-position))
              '("context.el" . 5)))
            (with-current-buffer buffer
              (should diffs-minor-mode)
              (should (derived-mode-p 'diff-mode))
              (should
               (equal
                (buffer-substring-no-properties
                 (point-min) (point-max))
                text))
              (should
               (equal diffs--review-session-id session))
              (should
               (= diffs--review-generation generation))
              (should
               (equal diffs--review-selection selection))
              (should
               (equal diffs--review-annotations annotations))
              (should
               (equal diffs--review-decisions decisions))
              (should-not (mark t))
              (should-not mark-active)
              (let ((gap (car diffs--context-gaps)))
                (should (= (plist-get gap :visible) 2))
                (should
                 (overlayp
                  (plist-get gap :overlay)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-review-stacked-refresh-rollback-restores-owner-windows ()
  (let* ((buffer
          (generate-new-buffer " *diffs stacked window rollback test*"))
         (body
          (mapconcat
           (lambda (index)
             (if (= index 45)
                 (concat
                  "-old-value-045 with a deliberately long source line\n"
                  "+new-value-045 with a deliberately long source line")
               (format
                " unchanged-%03d %s"
                index (make-string 90 ?x))))
           (number-sequence 1 90)
           "\n"))
         (patch
          (concat
           "diff --git a/window.el b/window.el\n"
           "--- a/window.el\n"
           "+++ b/window.el\n"
           "@@ -1,90 +1,90 @@\n"
           body "\n"))
         (transient-mark-mode t)
         regenerator)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (insert patch)
          (diff-mode)
          (diffs-minor-mode 1)
          (delete-other-windows)
          (let* ((first-window (selected-window))
                 (second-window (split-window-below))
                 (position
                  (lambda (line column)
                    (save-excursion
                      (goto-char (point-min))
                      (forward-line line)
                      (move-to-column column)
                      (point))))
                 (first-start (funcall position 12 0))
                 (first-point (funcall position 17 35))
                 (second-start (funcall position 56 0))
                 (second-point (funcall position 61 42))
                 (mark-position (funcall position 15 8)))
            (set-window-buffer second-window buffer)
            (set-window-point first-window first-point)
            (set-window-start first-window first-start)
            (set-window-hscroll first-window 7)
            (set-window-vscroll first-window 2 t)
            (set-window-point second-window second-point)
            (set-window-start second-window second-start)
            (set-window-hscroll second-window 11)
            (set-window-vscroll second-window 3 t)
            (set-mark mark-position)
            (setq mark-active t)
            (let ((first-state
                   (list
                    (window-start first-window)
                    (window-point first-window)
                    (window-hscroll first-window)
                    (window-vscroll first-window t)))
                  (second-state
                   (list
                    (window-start second-window)
                    (window-point second-window)
                    (window-hscroll second-window)
                    (window-vscroll second-window t)))
                  (region-state
                   (cons (region-beginning) (region-end))))
              (should (> (car first-state) (point-min)))
              (should (> (car second-state) (car first-state)))
              (should (use-region-p))
              (setq regenerator
                    (lambda ()
                      (let ((staged
                             (diffs--prepare-buffer
                              temporary-file-directory)))
                        (with-current-buffer staged
                          (insert
                           (replace-regexp-in-string
                            "new-value-045" "newer-value-045"
                            patch t t)))
                        (diffs--present
                         staged nil nil nil regenerator)))
                    diffs--regenerator regenerator)
              (should-error
               (cl-letf
                   (((symbol-function
                      'diffs--review-restore-refreshed-state)
                     (lambda (&rest _)
                       (error "Injected stacked refresh failure"))))
                 (diffs-refresh))
               :type 'error)
              (should (eq (window-buffer first-window) buffer))
              (should (eq (window-buffer second-window) buffer))
              (should
               (equal
                (list
                 (window-start first-window)
                 (window-point first-window)
                 (window-hscroll first-window)
                 (window-vscroll first-window t))
                first-state))
              (should
               (equal
                (list
                 (window-start second-window)
                 (window-point second-window)
                 (window-hscroll second-window)
                 (window-vscroll second-window t))
                second-state))
              (should (= (mark t) mark-position))
              (should mark-active)
              (should (use-region-p))
              (should
               (equal
                (cons (region-beginning) (region-end))
                region-state)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-review-narrowed-refresh-rollback-restores-full-owner ()
  (let ((buffer
         (generate-new-buffer " *diffs narrowed rollback test*"))
        (transient-mark-mode t)
        regenerator)
    (unwind-protect
        (with-current-buffer buffer
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (let* ((narrow-begin
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line 4)
                    (point)))
                 (narrow-end
                  (save-excursion
                    (goto-char (point-max))
                    (forward-line -1)
                    (point)))
                 (full-text
                  (buffer-substring-no-properties
                   (point-min) (point-max))))
            (narrow-to-region narrow-begin narrow-end)
            (goto-char (point-min))
            (forward-line 2)
            (let* ((point-before (point))
                   (mark-before
                    (save-excursion
                      (goto-char (point-min))
                      (forward-line 1)
                      (point))))
              (set-mark mark-before)
              (setq mark-active t)
              (let ((region-before
                     (cons (region-beginning) (region-end))))
                (setq regenerator
                      (lambda ()
                        (let ((staged
                               (diffs--prepare-buffer
                                temporary-file-directory)))
                          (with-current-buffer staged
                            (insert
                             (replace-regexp-in-string
                              "\"new\"" "\"newer\""
                              diffs-tests--normal)))
                          (diffs--present
                           staged nil nil nil regenerator)))
                      diffs--regenerator regenerator)
                (should-error
                 (cl-letf
                     (((symbol-function
                        'diffs--review-restore-refreshed-state)
                       (lambda (&rest _)
                         (error "Injected narrowed refresh failure"))))
                   (diffs-refresh))
                 :type 'error)
                (should (buffer-narrowed-p))
                (should (= (point-min) narrow-begin))
                (should (= (point-max) narrow-end))
                (should (= (point) point-before))
                (should (= (mark t) mark-before))
                (should mark-active)
                (should (use-region-p))
                (should
                 (equal
                  (cons (region-beginning) (region-end))
                  region-before))
                (save-restriction
                  (widen)
                  (should
                   (equal
                    (buffer-substring-no-properties
                     (point-min) (point-max))
                    full-text)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest diffs-split-g-refreshes-and-restores-side-identity ()
  (let ((buffer
         (generate-new-buffer " *diffs split refresh test*"))
        old-buffer new-buffer regenerator)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (setq default-directory temporary-file-directory)
          (insert diffs-tests--normal)
          (diff-mode)
          (diffs-minor-mode 1)
          (setq regenerator
                (lambda ()
                  (let ((staged
                         (diffs--prepare-buffer
                          temporary-file-directory)))
                    (with-current-buffer staged
                      (insert diffs-tests--normal))
                    (diffs--present
                     staged nil nil nil regenerator)))
                diffs--regenerator regenerator)
          (diffs-toggle-split)
          (setq new-buffer (current-buffer)
                old-buffer diffs--split-other)
          (select-window (get-buffer-window old-buffer))
          (goto-char (point-min))
          (search-forward "(message \"old\")")
          (beginning-of-line)
          (let ((source
                 (diffs--split-property-at
                  'diffs-src (point)))
                (session
                 (buffer-local-value
                  'diffs--review-session-id buffer))
                (generation
                 (buffer-local-value
                  'diffs--review-generation buffer)))
            (should
             (eq (keymap-lookup diffs-split-mode-map "g")
                 #'diffs-refresh))
            (call-interactively
             (keymap-lookup (current-local-map) "g"))
            (should (derived-mode-p 'diffs-split-mode))
            (should (eq diffs--split-role 'old))
            (should
             (equal
              (diffs--split-property-at
               'diffs-src (line-beginning-position))
              source))
            (with-current-buffer buffer
              (should
               (equal diffs--review-session-id session))
              (should
               (= diffs--review-generation
                  (1+ generation))))))
      (dolist (candidate (list old-buffer new-buffer buffer))
        (when (buffer-live-p candidate)
          (kill-buffer candidate))))))

(ert-deftest diffs-review-apply-revalidates-after-confirmation ()
  (let* ((directory (make-temp-file "diffs-confirm-race-" t))
         (file (expand-file-name "foo.el" directory))
         (source
          (concat
           "(message \"same\")\n"
           "(message \"new\")\n"
           "(message \"extra\")\n"))
         (diff-buffer
          (generate-new-buffer " *diffs confirm race test*"))
         source-buffer)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert source))
          (setq source-buffer (find-file-noselect file))
          (with-current-buffer diff-buffer
            (setq default-directory
                  (file-name-as-directory directory))
            (insert diffs-tests--normal)
            (diff-mode)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (re-search-forward "^+(message \"new\")")
            (beginning-of-line)
            (diffs-review-reject-change)
            (should-error
             (cl-letf
                 (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _)
                     (with-current-buffer source-buffer
                       (goto-char (point-min))
                       (insert "external edit\n"))
                     t)))
               (diffs-review-apply-decisions))
             :type 'user-error)
            (should-not
             (plist-get
              (cdar diffs--review-decisions)
              :applied)))
          (with-current-buffer source-buffer
            (should
             (equal
              (buffer-substring-no-properties
               (point-min) (point-max))
              (concat "external edit\n" source)))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-review-apply-normalizes-crlf-to-buffer-eol ()
  (let* ((directory (make-temp-file "diffs-crlf-" t))
         (file (expand-file-name "foo.el" directory))
         (patch
          (concat
           "diff --git a/foo.el b/foo.el\n"
           "--- a/foo.el\n"
           "+++ b/foo.el\n"
           "@@ -1,2 +1,3 @@\n"
           " (message \"same\")\r\n"
           "-(message \"old\")\r\n"
           "+(message \"new\")\r\n"
           "+(message \"extra\")\r\n"))
         (diff-buffer
          (generate-new-buffer " *diffs CRLF apply test*"))
         source-buffer)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-file file
              (insert
               "(message \"same\")\r\n"
               "(message \"new\")\r\n"
               "(message \"extra\")\r\n")))
          (setq source-buffer (find-file-noselect file))
          (with-current-buffer diff-buffer
            (setq default-directory (file-name-as-directory directory))
            (insert patch)
            (diff-mode)
            (diffs-minor-mode 1)
            (goto-char (point-min))
            (re-search-forward "^+(message \"new\")")
            (beginning-of-line)
            (diffs-review-reject-change)
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (&rest _) t)))
              (diffs-review-apply-decisions)))
          (with-current-buffer source-buffer
            (should
             (equal
              (buffer-substring-no-properties
               (point-min) (point-max))
              (concat
               "(message \"same\")\n"
               "(message \"old\")\n")))))
      (when (buffer-live-p source-buffer)
        (with-current-buffer source-buffer
          (set-buffer-modified-p nil))
        (kill-buffer source-buffer))
      (when (buffer-live-p diff-buffer)
        (kill-buffer diff-buffer))
      (delete-directory directory t))))

(ert-deftest diffs-conflict-standard-actions-delegate-to-smerge ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (let ((keep-upper (symbol-function 'smerge-keep-upper))
          (keep-lower (symbol-function 'smerge-keep-lower))
          (upper-calls 0)
          (lower-calls 0))
      (cl-letf
          (((symbol-function 'smerge-keep-upper)
            (lambda ()
              (cl-incf upper-calls)
              (funcall keep-upper)))
           ((symbol-function 'smerge-keep-lower)
            (lambda ()
              (cl-incf lower-calls)
              (funcall keep-lower))))
        (diffs-conflict-mode 1)
        (should
         (cl-every
          (lambda (block)
            (eq (plist-get block :engine) 'smerge))
          diffs--conflict-blocks))
        (diffs-conflict-current)
        ;; Switching an already resolved block restores its original
        ;; marker syntax inside the same edit before delegating again.
        (diffs-conflict-incoming)
        (should (= upper-calls 1))
        (should (= lower-calls 1))
        (should
         (string-match-p
          "(message \"incoming one\")"
          (buffer-substring-no-properties
           (point-min) (point-max))))))))

(ert-deftest diffs-conflict-both-uses-smerge-without-diff3-base ()
  (diffs-tests--with-conflict-source diffs-tests--diff3-conflict
    (let ((match-conflict (symbol-function 'smerge-match-conflict))
          (match-calls 0))
      (cl-letf
          (((symbol-function 'smerge-match-conflict)
            (lambda ()
              (cl-incf match-calls)
              (funcall match-conflict))))
        (diffs-conflict-mode 1)
        (should
         (eq (plist-get (car diffs--conflict-blocks) :engine)
             'smerge))
        (setq match-calls 0)
        (diffs-conflict-both)
        (should (> match-calls 0))
        (should-not
         (string-match-p
          "'base"
          (buffer-substring-no-properties
           (point-min) (point-max))))))))

(ert-deftest diffs-conflict-mode-is-the-complete-entry-and-toggle ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (goto-char (point-max))
    (call-interactively #'diffs-conflict-mode)
    (should diffs-conflict-mode)
    (should diffs--conflict-blocks)
    (should
     (= (point)
        (marker-position
         (plist-get (car diffs--conflict-blocks) :begin))))
    (let ((blocks diffs--conflict-blocks)
          (overlays diffs--conflict-overlays)
          (position (point)))
      (diffs-conflict-mode 1)
      (should (eq diffs--conflict-blocks blocks))
      (should (equal diffs--conflict-overlays overlays))
      (should (= (point) position)))
    (call-interactively #'diffs-conflict-mode)
    (should-not diffs-conflict-mode)
    (should-not diffs--conflict-blocks)
    (should-not diffs--conflict-overlays)
    (should
     (equal diffs-tests--two-conflicts
            (buffer-substring-no-properties
             (point-min) (point-max))))))

(ert-deftest diffs-conflict-mode-preserves-source-mode-and-smerge-bindings ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (let ((source-file buffer-file-name)
          (source-text
           (buffer-substring-no-properties (point-min) (point-max))))
      (smerge-mode 1)
      (let ((plain-bindings
             (mapcar (lambda (key) (key-binding (kbd key)))
                     '("c" "i" "b" "u" "n" "p")))
            (smerge-binding (key-binding (kbd "C-c ^ n"))))
        (diffs-conflict-mode 1)
        (should (eq major-mode 'emacs-lisp-mode))
        (should (equal buffer-file-name source-file))
        (should-not buffer-read-only)
        (should-not (buffer-modified-p))
        (should (equal
                 source-text
                 (buffer-substring-no-properties
                  (point-min) (point-max))))
        (should diffs-conflict-mode)
        (should smerge-mode)
        (should (eq (key-binding (kbd "C-c C-d c"))
                    #'diffs-conflict-current))
        (should (eq (key-binding (kbd "C-c C-d i"))
                    #'diffs-conflict-incoming))
        (should (eq (key-binding (kbd "C-c C-d b"))
                    #'diffs-conflict-both))
        (should (eq (key-binding (kbd "C-c C-d u"))
                    #'diffs-conflict-reset))
        (should (eq (key-binding (kbd "C-c C-d n"))
                    #'diffs-conflict-next))
        (should (eq (key-binding (kbd "C-c C-d p"))
                    #'diffs-conflict-previous))
        (should (eq (key-binding (kbd "C-c C-d q"))
                    #'diffs-conflict-quit))
        (should
         (equal
          plain-bindings
          (mapcar (lambda (key) (key-binding (kbd key)))
                  '("c" "i" "b" "u" "n" "p"))))
        (should (eq (key-binding (kbd "C-c ^ n")) smerge-binding))
        (diffs-conflict-quit)
        (should-not diffs-conflict-mode)
        (should smerge-mode)))))

(ert-deftest diffs-conflict-major-mode-change-removes-presentation ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (diffs-conflict-mode 1)
    (should
     (cl-some
      (lambda (overlay)
        (overlay-get overlay 'before-string))
      diffs--conflict-overlays))
    (normal-mode)
    (should (eq major-mode 'emacs-lisp-mode))
    (should-not diffs-conflict-mode)
    (should-not
     (cl-some
      (lambda (overlay)
        (overlay-get overlay 'diffs-conflict-id))
      (overlays-in (point-min) (point-max))))
    (should-not
     (cl-some
      (lambda (overlay)
        (overlay-get overlay 'before-string))
      (overlays-in (point-min) (point-max))))))

(ert-deftest diffs-conflict-revert-removes-stale-presentation-state ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (diffs-conflict-mode 1)
    (diffs-conflict-current)
    (revert-buffer t t)
    (should-not diffs-conflict-mode)
    (should
     (equal diffs-tests--two-conflicts
            (buffer-substring-no-properties
             (point-min) (point-max))))
    (should-not
     (cl-some
      (lambda (overlay)
        (overlay-get overlay 'diffs-conflict-id))
      (overlays-in (point-min) (point-max))))))

(ert-deftest diffs-conflict-presentation-keeps-syntax-and-shows-diff3-sections ()
  (diffs-tests--with-conflict-source diffs-tests--diff3-conflict
    (font-lock-ensure (point-min) (point-max))
    (goto-char (point-min))
    (re-search-forward "'current")
    (let ((syntax-face
           (get-text-property (match-beginning 0) 'face)))
      (diffs-conflict-mode 1)
      (goto-char (point-min))
      (re-search-forward "'current")
      (should (equal
               syntax-face
               (get-text-property (match-beginning 0) 'face)))
      (let ((overlay
             (cl-find-if
              (lambda (candidate)
                (eq (overlay-get candidate 'face)
                    'diffs-conflict-current))
              (overlays-at (match-beginning 0)))))
        (should overlay)
        (should (< (overlay-get overlay 'priority) 0))
        (should
         (equal
          (get-text-property
           0 'display (overlay-get overlay 'line-prefix))
          '(left-fringe diffs-fringe-bar
                        diff-indicator-added)))))
    (goto-char (point-min))
    (re-search-forward "'base")
    (should
     (cl-some
      (lambda (overlay)
        (eq (overlay-get overlay 'face)
            'diffs-conflict-base))
      (overlays-at (match-beginning 0))))
    (goto-char (point-min))
    (re-search-forward "'incoming")
    (should
     (cl-some
      (lambda (overlay)
        (eq (overlay-get overlay 'face)
            'diffs-conflict-incoming))
      (overlays-at (match-beginning 0))))
    (goto-char (point-min))
    (re-search-forward "^<<<<<<< HEAD$")
    (let ((marker
           (cl-find-if
            (lambda (overlay)
              (overlay-get overlay 'display))
            (overlays-at (line-beginning-position)))))
      (should marker)
      (should (eq (overlay-get marker 'face)
                  'diffs-conflict-current-marker))
      (should
       (string-match-p
        "<<<<<<< HEAD  (Current Change)"
        (overlay-get marker 'display)))
      (let* ((display (overlay-get marker 'display))
             (label-start
              (string-match "(Current Change)" display)))
        (should label-start)
        (should
         (eq (get-text-property label-start 'face display)
             'diffs-conflict-marker-label))
        (should
         (eq (face-attribute
              'diffs-conflict-marker-label :weight nil 'default)
             'normal))))
    (goto-char (point-min))
    (re-search-forward "^>>>>>>> feature/value$")
    (let ((marker
           (cl-find-if
            (lambda (overlay)
              (overlay-get overlay 'display))
            (overlays-at (line-beginning-position)))))
      (should marker)
      (should (eq (overlay-get marker 'face)
                  'diffs-conflict-incoming-marker))
      (should
       (string-match-p
        ">>>>>>> feature/value  (Incoming Change)"
        (overlay-get marker 'display))))
    (let* ((action
            (cl-find-if
             (lambda (overlay)
               (overlay-get overlay 'before-string))
             diffs--conflict-overlays))
           (row (and action (overlay-get action 'before-string))))
      (should (string-match-p "Accept current change" row))
      (should (string-match-p "Accept incoming change" row))
      (should (string-match-p "Accept both" row))
      (should-not (string-match-p "\\[" row))
      (should-not (string-match-p "Reset" row))
      (should-not (string-match-p "C-c C-d" row)))
    (diffs-conflict-current)
    (let* ((action
            (cl-find-if
             (lambda (overlay)
               (overlay-get overlay 'before-string))
             diffs--conflict-overlays))
           (row (and action (overlay-get action 'before-string))))
      (should (string-match-p "Resolved: Current" row))
      (should (string-match-p "Reset" row))
      (should-not (string-match-p "Accept current change" row))
      (should-not (string-match-p "Accept incoming change" row))
      (should-not (string-match-p "Accept both" row)))))

(ert-deftest diffs-conflict-resolutions-track-multiple-blocks-and-reset ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (diffs-conflict-mode 1)
    (call-interactively (key-binding (kbd "C-c C-d i")))
    (diffs-conflict-next)
    (diffs-conflict-current)
    (let ((resolved
           (concat
            "(message \"before\")\n"
            "(message \"incoming one\")\n"
            "(message \"incoming extra\")\n"
            "(message \"middle\")\n"
            "(message \"current two a\")\n"
            "(message \"current two b\")\n"
            "(message \"after\")\n")))
      (should
       (equal resolved
              (buffer-substring-no-properties
               (point-min) (point-max))))
      (should (string-match-p "0 unresolved" header-line-format)))
    (goto-char (point-min))
    (re-search-forward "(message \"incoming one\")")
    (beginning-of-line)
    (diffs-conflict-reset)
    (should (string-match-p "<<<<<<< HEAD"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))
    (should-not
     (string-match-p ">>>>>>> feature/two"
                     (buffer-substring-no-properties
                      (point-min) (point-max))))
    (re-search-forward "(message \"current two a\")")
    (beginning-of-line)
    (diffs-conflict-reset)
    (should
     (equal diffs-tests--two-conflicts
            (buffer-substring-no-properties
             (point-min) (point-max))))
    (should-not (buffer-modified-p))
    (should diffs-conflict-mode)
    (with-temp-buffer
      (insert-file-contents file)
      (should
       (equal diffs-tests--two-conflicts
              (buffer-substring-no-properties
               (point-min) (point-max)))))))

(ert-deftest diffs-conflict-both-omits-diff3-base-and-undo-restores-markers ()
  (diffs-tests--with-conflict-source diffs-tests--diff3-conflict
    (smerge-mode 1)
    (diffs-conflict-mode 1)
    (undo-boundary)
    (diffs-conflict-both)
    (undo-boundary)
    (should
     (equal
      (concat
       "(setq value\n"
       "      'current)\n"
       "      'incoming)\n")
      (buffer-substring-no-properties (point-min) (point-max))))
    (should-not (string-match-p
                 "base\\|[<|=>]\\{7\\}"
                 (buffer-substring-no-properties
                  (point-min) (point-max))))
    (should smerge-mode)
    (should-not
     (cl-some
      (lambda (overlay)
        (eq (overlay-get overlay 'smerge) 'conflict))
      (overlays-in (point-min) (point-max))))
    (undo-only 1)
    (should
     (equal diffs-tests--diff3-conflict
            (buffer-substring-no-properties
             (point-min) (point-max))))
    (should-not (buffer-modified-p))
    (goto-char (point-min))
    (re-search-forward "^<<<<<<<")
    (beginning-of-line)
    (diffs-conflict-incoming)
    (should
     (equal
      (concat
       "(setq value\n"
       "      'incoming)\n")
      (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest diffs-conflict-entry-rejects-read-only-and-narrowed-sources ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (setq header-line-format "source header"
          buffer-read-only t)
    (let ((text (buffer-substring-no-properties
                 (point-min) (point-max)))
          (undo-list (copy-tree buffer-undo-list))
          (overlays (overlays-in (point-min) (point-max)))
          (error-data
           (should-error (diffs-conflict-mode 1) :type 'user-error)))
      (should (string-match-p
               "read-only" (error-message-string error-data)))
      (should-not diffs-conflict-mode)
      (should buffer-read-only)
      (should (equal header-line-format "source header"))
      (should-not (buffer-modified-p))
      (should (equal undo-list buffer-undo-list))
      (should (equal overlays
                     (overlays-in (point-min) (point-max))))
      (should
       (equal text
              (buffer-substring-no-properties
               (point-min) (point-max))))))
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (goto-char (point-min))
    (forward-line 1)
    (let ((begin (point)))
      (re-search-forward "^>>>>>>> feature/one$")
      (forward-line 1)
      (narrow-to-region begin (point)))
    (goto-char (point-min))
    (forward-line 2)
    (let ((minimum (point-min))
          (maximum (point-max))
          (position (point))
          (undo-list (copy-tree buffer-undo-list))
          (text
           (save-restriction
             (widen)
             (buffer-substring-no-properties
              (point-min) (point-max))))
          (error-data
           (should-error (diffs-conflict-mode 1) :type 'user-error)))
      (should (string-match-p
               "Widen" (error-message-string error-data)))
      (should-not diffs-conflict-mode)
      (should (= (point-min) minimum))
      (should (= (point-max) maximum))
      (should (= (point) position))
      (should (equal undo-list buffer-undo-list))
      (should
       (equal
        text
        (save-restriction
          (widen)
          (buffer-substring-no-properties
           (point-min) (point-max))))))))

(ert-deftest diffs-conflict-stale-block-fails-without-overwriting-source ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (diffs-conflict-mode 1)
    (diffs-conflict-current)
    (goto-char (point-min))
    (re-search-forward "(message \"current two a\")")
    (let ((inhibit-modification-hooks t))
      (replace-match "(message \"externally edited\")" t t))
    (let ((text
           (buffer-substring-no-properties
            (point-min) (point-max)))
          (undo-list (copy-tree buffer-undo-list)))
      (beginning-of-line)
      (should-error (diffs-conflict-current) :type 'user-error)
      (should diffs-conflict-mode)
      (should
       (equal text
              (buffer-substring-no-properties
               (point-min) (point-max))))
      (should (equal undo-list buffer-undo-list)))))

(ert-deftest diffs-conflict-boundary-inserts-stay-outside-adjacent-blocks ()
  (let ((fixture
         (concat
          "<<<<<<< HEAD\n"
          "current one\n"
          "=======\n"
          "incoming one\n"
          ">>>>>>> one\n"
          "<<<<<<< HEAD\n"
          "current two\n"
          "=======\n"
          "incoming two\n"
          ">>>>>>> two\n")))
    (diffs-tests--with-conflict-source fixture
      (diffs-conflict-mode 1)
      (let* ((first (car diffs--conflict-blocks))
             (boundary
              (marker-position (plist-get first :end))))
        (goto-char boundary)
        (insert "outside both conflicts\n")
        (goto-char
         (marker-position (plist-get first :begin)))
        (diffs-conflict-current)
        (diffs-conflict-next)
        (diffs-conflict-incoming))
      (should
       (equal
        (concat
         "current one\n"
         "outside both conflicts\n"
         "incoming two\n")
        (buffer-substring-no-properties
         (point-min) (point-max)))))))

(ert-deftest diffs-conflict-navigation-distinguishes-empty-adjacent-blocks ()
  (let ((fixture
         (concat
          "<<<<<<< HEAD\n"
          "=======\n"
          "incoming one\n"
          ">>>>>>> one\n"
          "<<<<<<< HEAD\n"
          "=======\n"
          "incoming two\n"
          ">>>>>>> two\n")))
    (diffs-tests--with-conflict-source fixture
      (diffs-conflict-mode 1)
      (diffs-conflict-current)
      (let ((first-position (point)))
        (diffs-conflict-next)
        (should (= (point) first-position))
        (should (= diffs--conflict-current-id 2))
        (diffs-conflict-current)
        (should (string-empty-p
                 (buffer-substring-no-properties
                  (point-min) (point-max))))
        (diffs-conflict-previous)
        (should (= diffs--conflict-current-id 1))
        (diffs-conflict-reset)
        (should
         (equal
          (concat
           "<<<<<<< HEAD\n"
           "=======\n"
           "incoming one\n"
           ">>>>>>> one\n")
          (buffer-substring-no-properties
           (point-min) (point-max))))))))

(ert-deftest diffs-conflict-mouse-action-uses-the-clicked-window-buffer ()
  (let ((buffer-a (generate-new-buffer " *diffs conflict mouse a*"))
        (buffer-b (generate-new-buffer " *diffs conflict mouse b*"))
        (fixture
         (concat
          "<<<<<<< HEAD\n"
          "current\n"
          "=======\n"
          "incoming\n"
          ">>>>>>> branch\n")))
    (unwind-protect
        (save-window-excursion
          (dolist (buffer (list buffer-a buffer-b))
            (with-current-buffer buffer
              (insert fixture)
              (emacs-lisp-mode)
              (diffs-conflict-mode 1)))
          (delete-other-windows)
          (let* ((window-a (selected-window))
                 (window-b (split-window-right)))
            (set-window-buffer window-a buffer-a)
            (set-window-buffer window-b buffer-b)
            (select-window window-a)
            (let* ((row
                    (with-current-buffer buffer-b
                      (cl-loop
                       for overlay in diffs--conflict-overlays
                       when (overlay-get overlay 'before-string)
                       return (overlay-get overlay 'before-string))))
                   (index
                    (text-property-any
                     0 (length row)
                     'diffs-conflict-action 'current row))
                   (button-map
                    (get-text-property index 'keymap row))
                   (fake-position (list 'fake-position)))
              (should
               (eq (lookup-key button-map [mouse-1])
                   #'diffs-conflict-mouse-action))
              ;; `follow-link' translates the normal mouse-1 click to
              ;; mouse-2.  This binding prevents the global primary-
              ;; selection yank from receiving the translated event.
              (should
               (eq (lookup-key button-map [mouse-2])
                   #'diffs-conflict-mouse-action))
              (cl-letf
                  (((symbol-function 'event-start)
                    (lambda (_) fake-position))
                   ((symbol-function 'posn-window)
                    (lambda (_) window-b))
                   ((symbol-function 'posn-string)
                    (lambda (_) (cons row index)))
                   ((symbol-function 'posn-set-point)
                    (lambda (_)
                      (select-window window-b)
                      (goto-char (point-min)))))
                (diffs-conflict-mouse-action 'fake-event)))
            (should (eq (current-buffer) buffer-b))
            (with-current-buffer buffer-a
              (should
               (equal fixture
                      (buffer-substring-no-properties
                       (point-min) (point-max)))))
            (with-current-buffer buffer-b
              (should
               (equal "current\n"
                      (buffer-substring-no-properties
                       (point-min) (point-max)))))))
      (dolist (buffer (list buffer-a buffer-b))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when diffs-conflict-mode
              (diffs-conflict-mode -1))
            (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest diffs-conflict-entry-rejects-malformed-and-nested-markers ()
  (dolist
      (fixture
       (list
        (concat
         "<<<<<<< HEAD\n"
         "current\n"
         "=======\n"
         "incoming\n")
        (concat
         "<<<<<<< HEAD\n"
         "outer\n"
         "<<<<<<< nested\n"
         "inner\n"
         "=======\n"
         "other\n"
         ">>>>>>> nested\n"
         "=======\n"
         "incoming\n"
         ">>>>>>> outer\n")
        (concat
         ">>>>>>> orphan\n"
         "<<<<<<< HEAD\n"
         "current\n"
         "=======\n"
         "incoming\n"
         ">>>>>>> branch\n")))
    (diffs-tests--with-conflict-source fixture
      (let ((text
             (buffer-substring-no-properties
              (point-min) (point-max)))
            (undo-list (copy-tree buffer-undo-list))
            (overlays (overlays-in (point-min) (point-max))))
        (should-error (diffs-conflict-mode 1) :type 'user-error)
        (should-not diffs-conflict-mode)
        (should-not (buffer-modified-p))
        (should (equal undo-list buffer-undo-list))
        (should (equal overlays
                       (overlays-in (point-min) (point-max))))
        (should
         (equal text
                (buffer-substring-no-properties
                 (point-min) (point-max))))))))

(ert-deftest diffs-conflict-supports-long-markers-and-final-line-at-eof ()
  (let ((fixture
         (concat
          "start\n"
          "<<<<<<<<<< current\n"
          "left\n"
          "==========\n"
          "right\n"
          ">>>>>>>>>> incoming")))
    (diffs-tests--with-conflict-source fixture
      (diffs-conflict-mode 1)
      (diffs-conflict-both)
      (should
       (equal
        "start\nleft\nright\n"
        (buffer-substring-no-properties
         (point-min) (point-max)))))))

(ert-deftest diffs-conflict-empty-sides-remain-resettable ()
  (let ((empty-current
         (concat
          "before\n"
          "<<<<<<< HEAD\n"
          "=======\n"
          "incoming\n"
          ">>>>>>> branch\n"
          "after\n"))
        (empty-incoming
         (concat
          "before\n"
          "<<<<<<< HEAD\n"
          "current\n"
          "=======\n"
          ">>>>>>> branch\n"
          "after\n")))
    (diffs-tests--with-conflict-source empty-current
      (diffs-conflict-mode 1)
      (diffs-conflict-current)
      (should
       (equal "before\nafter\n"
              (buffer-substring-no-properties
               (point-min) (point-max))))
      (diffs-conflict-reset)
      (should
       (equal empty-current
              (buffer-substring-no-properties
               (point-min) (point-max)))))
    (diffs-tests--with-conflict-source empty-incoming
      (diffs-conflict-mode 1)
      (diffs-conflict-incoming)
      (should
       (equal "before\nafter\n"
              (buffer-substring-no-properties
               (point-min) (point-max))))
      (diffs-conflict-reset)
      (should
       (equal empty-incoming
              (buffer-substring-no-properties
               (point-min) (point-max)))))))

(ert-deftest diffs-conflict-reset-after-an-explicit-save-stays-modified ()
  (diffs-tests--with-conflict-source diffs-tests--diff3-conflict
    (diffs-conflict-mode 1)
    (diffs-conflict-current)
    (save-buffer)
    (should-not (buffer-modified-p))
    (diffs-conflict-reset)
    (should (buffer-modified-p))
    (should
     (equal diffs-tests--diff3-conflict
            (buffer-substring-no-properties
             (point-min) (point-max))))
    (with-temp-buffer
      (insert-file-contents file)
      (should-not
       (equal diffs-tests--diff3-conflict
              (buffer-substring-no-properties
               (point-min) (point-max)))))))

(ert-deftest diffs-conflict-render-failure-rolls-back-source-and-state ()
  (diffs-tests--with-conflict-source diffs-tests--two-conflicts
    (diffs-conflict-mode 1)
    (let ((make-overlay-function (symbol-function 'make-overlay))
          (fail t))
      (cl-letf
          (((symbol-function 'make-overlay)
            (lambda (&rest arguments)
              (if fail
                  (progn
                    (setq fail nil)
                    (error "Synthetic conflict render failure"))
                (apply make-overlay-function arguments)))))
        (should-error (diffs-conflict-current))))
    (should diffs-conflict-mode)
    (should-not (buffer-modified-p))
    (should
     (equal diffs-tests--two-conflicts
            (buffer-substring-no-properties
             (point-min) (point-max))))
    (diffs-conflict-current)
    (should (string-match-p
             "(message \"current one\")"
             (buffer-substring-no-properties
              (point-min) (point-max))))))

(ert-deftest diffs-review-sidecar-round-trips-hunk-compatible-fields ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (goto-char (point-min))
    (re-search-forward "^+(message \"new\")")
    (beginning-of-line)
    (diffs-review-select)
    (diffs-review-add-annotation
     "New behavior is intentional."
     "The caller now receives the replacement value.")
    (let* ((json (diffs-review-sidecar-json))
           (parsed (diffs--review-parse-sidecar
                    json (current-buffer)))
           (annotation (car parsed)))
      (should (string-match-p "\"version\":1" json))
      (should (string-match-p "\"newRange\":\\[2,2\\]" json))
      (should (= (length parsed) 1))
      (should (equal (plist-get annotation :file) "foo.el"))
      (should (equal (plist-get annotation :new-range) '(2 2)))
      (should (equal (plist-get annotation :summary)
                     "New behavior is intentional."))
      (should (equal (plist-get annotation :rationale)
                     "The caller now receives the replacement value.")))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-sidecar-import-validates-before-mutation ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (let* ((file (make-temp-file "diffs-sidecar-" nil ".json"))
           (before
            (list
             '(:id "existing" :file "foo.el" :new-range (2 2)
               :summary "Existing note." :source "user"))))
      (unwind-protect
          (progn
            (setq diffs--review-annotations before)
            (dolist
                (json
                 '("{\"version\":1,\"files\":[{\"path\":\"foo.el\",\"annotations\":[{\"newRange\":[2,2],\"summary\":\"note\",\"rationale\":42}]}]}"
                   "{\"version\":1,\"files\":[{\"path\":\"foo.el\",\"annotations\":[{\"newRange\":[99,99],\"summary\":\"outside\"}]}]}"
                   "{\"version\":1,\"files\":[{\"path\":\"foo.el\",\"annotations\":[{\"oldRange\":[99,99],\"newRange\":[2,2],\"summary\":\"old outside\"}]}]}"
                   "{\"version\":1,\"files\":[{\"path\":\"foo.el\",\"annotations\":[{\"oldRange\":[2,2],\"newRange\":[99,99],\"summary\":\"new outside\"}]}]}"))
              (with-temp-file file (insert json))
              (should-error (diffs-review-import file))
              (should (equal diffs--review-annotations before)))
            (with-temp-file file
              (insert
               "{\"version\":1,\"files\":[{\"path\":\"foo.el\",\"annotations\":[{\"newRange\":[2,2],\"summary\":\"valid\"}]}]}"))
            (let ((refreshes 0))
              (cl-letf
                  (((symbol-function 'diffs--review-refresh-overlays)
                    (lambda (&rest _)
                      (cl-incf refreshes)
                      (when (= refreshes 1)
                        (error "Synthetic sidecar projection failure")))))
                (should-error (diffs-review-import file)))
              (should (= refreshes 2))
              (should (equal diffs--review-annotations before))))
        (delete-file file)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-sidecar-import-keeps-forward-compatible-dual-ranges ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (let ((file (make-temp-file "diffs-sidecar-forward-" nil ".json")))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert
               (concat
                "{\"version\":1,\"futureRoot\":{\"format\":2},\"files\":[{"
                "\"path\":\"foo.el\",\"futureFile\":true,\"annotations\":[{"
                "\"oldRange\":[2,2],\"newRange\":[2,2],"
                "\"summary\":\"paired replacement\","
                "\"tags\":[\"compat\"],\"confidence\":0.5,"
                "\"futureAnnotation\":[\"ignored\"]}]}]}")))
            (let* ((imported (diffs-review-import file))
                   (annotation (car imported))
                   (exported (diffs-review-sidecar-json))
                   (round-trip
                    (car
                     (diffs--review-parse-sidecar
                      exported (current-buffer)))))
              (should (= (length imported) 1))
              (should (equal (plist-get annotation :old-range) '(2 2)))
              (should (equal (plist-get annotation :new-range) '(2 2)))
              (should (equal (plist-get annotation :tags) '("compat")))
              (should (= (plist-get annotation :confidence) 0.5))
              (should (string-match-p "\"oldRange\":\\[2,2\\]" exported))
              (should (string-match-p "\"newRange\":\\[2,2\\]" exported))
              (should (equal (plist-get round-trip :old-range) '(2 2)))
              (should (equal (plist-get round-trip :new-range) '(2 2)))))
        (delete-file file)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-agent-batches-are-atomic-and-readable ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (let ((result
           (diffs-review-apply-comments-json
            (concat
             "{\"comments\":["
             "{\"filePath\":\"foo.el\",\"oldLine\":2,"
             "\"summary\":\"Check the removed behavior.\"},"
             "{\"filePath\":\"foo.el\",\"newLine\":3,"
             "\"summary\":\"Check the extra behavior.\","
             "\"rationale\":\"This changes the result count.\"}"
             "]}"))))
      (should (string-match-p "\"applied\"" result))
      (should (= (length diffs--review-annotations) 2)))
    (let* ((snapshot (diffs-review-json nil nil t))
           (parsed
            (json-parse-string
             snapshot :object-type 'alist :array-type 'list)))
      (should (= (length (diffs--review-json-value parsed "files")) 1))
      (should
       (= (length
           (diffs--review-json-value
            (car (diffs--review-json-value parsed "files"))
            "annotations"))
          2)))
    (let ((before (copy-tree diffs--review-annotations)))
      (should-error
       (diffs-review-apply-comments-json
        (concat
         "{\"comments\":["
         "{\"filePath\":\"foo.el\",\"newLine\":2,"
         "\"summary\":\"Valid first item.\"},"
         "{\"filePath\":\"missing.el\",\"newLine\":1,"
         "\"summary\":\"Invalid second item.\"}"
         "]}")))
      (should (equal diffs--review-annotations before)))
    (should (string-match-p
             (regexp-quote (buffer-name))
             (diffs-review-sessions-json)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-agent-comment-schema-is-validated-before-mutation ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (dolist
        (payload
         '("{\"comments\":[{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\",\"rationale\":42}]}"
           "{\"comments\":[{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\",\"author\":false}]}"
           "{\"comments\":[{\"filePath\":\"foo.el\",\"newLine\":\"2\",\"summary\":\"note\"}]}"
           "{\"comments\":[{\"filePath\":\"foo.el\",\"newRange\":\"2-3\",\"summary\":\"note\"}]}"
           "{\"comments\":[{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\",\"severity\":\"high\"}]}"
           "{\"comments\":[{\"filePath\":\"foo.el\",\"hunk\":1,\"hunkNumber\":1,\"summary\":\"note\"}]}"
           "{\"comments\":{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\"}}"
           "[{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\"}]"))
      (should-error (diffs-review-apply-comments-json payload))
      (should-not diffs--review-annotations))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-agent-render-failure-rolls-back-state ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (let ((refreshes 0))
      (cl-letf
          (((symbol-function 'diffs--review-refresh-overlays)
            (lambda (&rest _)
              (cl-incf refreshes)
              (when (= refreshes 1)
                (error "Synthetic projection failure")))))
        (should-error
         (diffs-review-apply-comments-json
          "{\"comments\":[{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"note\"}]}")))
      (should (= refreshes 2))
      (should-not diffs--review-annotations))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-zero-count-sides-cannot-own-comments ()
  (diffs-tests--with-diff diffs-tests--context-zero-deletion
    (diffs-minor-mode 1)
    (let* ((root
            (json-parse-string
             (diffs-review-json)
             :object-type 'alist :array-type 'list))
           (file
            (car (diffs--review-json-value root "files")))
           (hunk
            (car (diffs--review-json-value file "hunks"))))
      (should
       (= (diffs--review-json-value hunk "oldCount") 1))
      (should
       (= (diffs--review-json-value hunk "newCount") 0))
      (should
       (equal
        (diffs--review-json-value hunk "oldRange")
        '(2 2)))
      (should-not
       (diffs--review-json-value hunk "newRange")))
    (should-error
     (diffs-review-apply-comments-json
      "{\"comments\":[{\"filePath\":\"pure.el\",\"newLine\":1,\"summary\":\"ghost\"}]}"))
    (diffs-review-apply-comments-json
     "{\"comments\":[{\"filePath\":\"pure.el\",\"oldLine\":2,\"summary\":\"real deletion\"}]}")
    (should (= (length diffs--review-annotations) 1))
    (diffs-minor-mode -1))
  (diffs-tests--with-diff diffs-tests--zero-count-addition
    (diffs-minor-mode 1)
    (let* ((root
            (json-parse-string
             (diffs-review-json)
             :object-type 'alist :array-type 'list))
           (file
            (car (diffs--review-json-value root "files")))
           (hunk
            (car (diffs--review-json-value file "hunks"))))
      (should
       (= (diffs--review-json-value hunk "oldCount") 0))
      (should
       (= (diffs--review-json-value hunk "newCount") 1))
      (should-not
       (diffs--review-json-value hunk "oldRange"))
      (should
       (equal
        (diffs--review-json-value hunk "newRange")
        '(1 1))))
    (should-error
     (diffs-review-apply-comments-json
      "{\"comments\":[{\"filePath\":\"added.el\",\"oldLine\":1,\"summary\":\"ghost\"}]}"))
    (diffs-review-apply-comments-json
     "{\"comments\":[{\"filePath\":\"added.el\",\"newLine\":1,\"summary\":\"real addition\"}]}")
    (should (= (length diffs--review-annotations) 1))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-decision-json-uses-json-booleans ()
  (let* ((json
          (diffs--review-json-serialize
           (diffs--review-decision-json-object
            '(:key ("foo.el" 1 1 0)
              :action reject :applied nil
              :old-start 1 :old-lines ("old")
              :new-start 1 :new-lines ("new")))))
         (parsed
          (json-parse-string
           json :object-type 'alist :false-object :false)))
    (should (string-match-p "\"applied\":false" json))
    (should
     (eq (diffs--review-json-value parsed "applied") :false))))

(ert-deftest diffs-review-live-sessions-filter-and-mutate-comments ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    ;; Live buffers created before the session CLI was loaded are
    ;; upgraded lazily without requiring a refresh.
    (setq diffs--review-session-id nil
          diffs--review-repository nil)
    (let* ((sessions
            (json-parse-string
             (diffs-review-sessions-json)
             :object-type 'alist :array-type 'list))
           (session-id diffs--review-session-id)
           (session (car sessions)))
      (should (string-prefix-p "diffs-session:" session-id))
      (should (equal
               (diffs--review-json-value session "id")
               session-id))
      (should (stringp
               (diffs--review-json-value session "repository")))
      (goto-char (point-min))
      (search-forward "+(message \"new\")")
      (beginning-of-line)
      (diffs-review-add-annotation "Human session note." "")
      (diffs-review-apply-comments-json
       (concat
        "{\"comments\":[{\"filePath\":\"foo.el\",\"oldLine\":2,"
        "\"summary\":\"Agent session note.\"}]}")
       session-id)
      (let* ((user-root
              (json-parse-string
               (diffs-review-comments-json session-id "user")
               :object-type 'alist :array-type 'list))
             (agent-root
              (json-parse-string
               (diffs-review-comments-json session-id "agent")
               :object-type 'alist :array-type 'list))
             (user-comments
              (diffs--review-json-value user-root "comments"))
             (agent-comments
              (diffs--review-json-value agent-root "comments"))
             (agent-id
              (diffs--review-json-value
               (car agent-comments) "id")))
        (should (= (length user-comments) 1))
        (should (= (length agent-comments) 1))
        (should (equal
                 (diffs--review-json-value
                  (car user-comments) "source")
                 "user"))
        (should (string-match-p
                 (regexp-quote session-id)
                 (diffs-review-remove-comment-json
                  session-id agent-id)))
        (should (equal
                 (diffs--review-json-value
                  (json-parse-string
                   (diffs-review-comments-json
                    session-id "agent")
                   :object-type 'alist :array-type 'list)
                  "comments")
                 nil))
        (diffs-review-clear-comments-json
         session-id nil "user")
        (should-not diffs--review-annotations)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-json-removals-roll-back-on-projection-failure ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (diffs-review-apply-comments-json
     (concat
      "{\"comments\":["
      "{\"filePath\":\"foo.el\",\"oldLine\":2,\"summary\":\"old\"},"
      "{\"filePath\":\"foo.el\",\"newLine\":2,\"summary\":\"new\"}"
      "]}"))
    (let* ((before (copy-tree diffs--review-annotations))
           (id (plist-get (car before) :id))
           (refreshes 0))
      (cl-letf
          (((symbol-function 'diffs--review-refresh-overlays)
            (lambda (&rest _)
              (cl-incf refreshes)
              (when (= refreshes 1)
                (error "Synthetic remove projection failure")))))
        (should-error (diffs-review-remove-comment-json nil id)))
      (should (= refreshes 2))
      (should (equal diffs--review-annotations before))
      (setq refreshes 0)
      (cl-letf
          (((symbol-function 'diffs--review-refresh-overlays)
            (lambda (&rest _)
              (cl-incf refreshes)
              (when (= refreshes 1)
                (error "Synthetic clear projection failure")))))
        (should-error
         (diffs-review-clear-comments-json nil nil "all")))
      (should (= refreshes 2))
      (should (equal diffs--review-annotations before)))
    (diffs-minor-mode -1)))

(ert-deftest diffs-review-agent-skill-uses-the-live-session-cli ()
  (require 'diffs-assets)
  (let ((cli (diffs-review-cli-path))
        (skill (diffs-review-skill-path)))
    (should (file-executable-p cli))
    (with-temp-buffer
      (insert-file-contents skill)
      (should (equal (buffer-string) diffs--review-skill-content))
      (should (search-forward
               "diffs session review --repo . --include-notes --json"
               nil t))
      (should (search-forward
               "diffs session attachment get --repo . ATTACHMENT_ID"
               nil t))
      (should-not (search-forward
                   "diffs-review-write-json" nil t)))))

(ert-deftest diffs-review-assets-survive-root-only-package-builds ()
  (let* ((directory (make-temp-file "diffs-package-build-" t))
         (build (expand-file-name "build/" directory))
         (assets (expand-file-name "assets/" directory))
         (install-bin (expand-file-name "install/bin/" directory))
         (install-skill
          (expand-file-name "install/skills/diffs-review/" directory))
         (source
          (file-name-directory
           (or (locate-library "diffs.el" t)
               (error "Cannot locate test source"))))
         (original-locate (symbol-function 'locate-library)))
    (unwind-protect
        (progn
          (make-directory build t)
          (dolist (file '("diffs.el" "diffs-diff-hl.el"
                          "diffs-review-compose.el" "diffs-cli.el"
                          "diffs-assets.el"))
            (copy-file (expand-file-name file source)
                       (expand-file-name file build)))
          (should-not
           (file-exists-p (expand-file-name "bin/" build)))
          (should-not
           (file-exists-p (expand-file-name "skills/" build)))
          (let ((diffs-review-assets-directory assets)
                (diffs-review-cli-install-path
                 (expand-file-name "diffs" install-bin))
                (diffs-review-skill-install-directory install-skill))
            (cl-letf
                (((symbol-function 'locate-library)
                  (lambda (library &optional nosuffix path interactive-call)
                    (pcase library
                      ((or "diffs" "diffs.el")
                       (expand-file-name "diffs.el" build))
                      ("diffs-cli.el"
                       (expand-file-name "diffs-cli.el" build))
                      ("diffs-assets.el"
                       (expand-file-name "diffs-assets.el" build))
                      (_
                       (funcall original-locate
                                library nosuffix path interactive-call))))))
              (let ((cli (diffs-review-cli-path))
                    (skill (diffs-review-skill-path)))
                (should (file-executable-p cli))
                (should (file-regular-p skill))
                (should (string-prefix-p assets cli))
                (should (string-prefix-p assets skill))
                (diffs-review-install-agent-tools t)))
            (delete-directory build t)
            (let ((installed-cli diffs-review-cli-install-path)
                  (installed-cli-library
                   (expand-file-name "diffs-cli.el" install-bin))
                  (installed-skill
                   (expand-file-name "SKILL.md" install-skill)))
              (dolist (file
                       (list installed-cli installed-cli-library
                             installed-skill))
                (should (file-regular-p file))
                (should-not (file-symlink-p file)))
              (should (file-executable-p installed-cli))
              (let ((process-environment (copy-sequence process-environment)))
                (setenv
                 "EMACS"
                 (expand-file-name invocation-name invocation-directory))
                (with-temp-buffer
                  (should (zerop
                           (call-process installed-cli nil t nil "--help")))
                  (goto-char (point-min))
                  (should (search-forward "session list" nil t)))))))
      (delete-directory directory t))))

(ert-deftest diffs-review-installer-preflights-every-target ()
  (let* ((directory (make-temp-file "diffs-install-preflight-" t))
         (assets (expand-file-name "assets/" directory))
         (install-bin (expand-file-name "install/bin/" directory))
         (installed-cli (expand-file-name "diffs" install-bin))
         (installed-cli-library
          (expand-file-name "diffs-cli.el" install-bin))
         (installed-skill-directory
          (expand-file-name "install/skills/diffs-review/" directory)))
    (unwind-protect
        (let ((diffs-review-assets-directory assets)
              (diffs-review-cli-install-path installed-cli)
              (diffs-review-skill-install-directory
               installed-skill-directory))
          (make-directory install-bin t)
          (with-temp-file installed-cli-library
            (insert "unrelated contents"))
          (should-error (diffs-review-install-agent-tools))
          (should-not (file-exists-p installed-cli))
          (should-not
           (file-exists-p installed-skill-directory))
          (with-temp-buffer
            (insert-file-contents installed-cli-library)
            (should (equal (buffer-string) "unrelated contents"))))
      (delete-directory directory t))))

(ert-deftest diffs-review-installer-rejects-directory-symlink ()
  (let* ((directory (make-temp-file "diffs-install-symlink-" t))
         (assets (expand-file-name "assets/" directory))
         (installed-cli
          (expand-file-name "install/bin/diffs" directory))
         (installed-cli-library
          (expand-file-name "install/bin/diffs-cli.el" directory))
         (installed-skill-directory
          (expand-file-name "install/skills/diffs-review/" directory))
         (installed-skill-target
          (directory-file-name installed-skill-directory))
         (referent (expand-file-name "existing-skill/" directory))
         (sentinel (expand-file-name "sentinel" referent)))
    (unwind-protect
        (let ((diffs-review-assets-directory assets)
              (diffs-review-cli-install-path installed-cli)
              (diffs-review-skill-install-directory
               installed-skill-directory))
          (make-directory referent t)
          (make-directory
           (file-name-directory installed-skill-target) t)
          (with-temp-file sentinel
            (insert "referent must stay untouched"))
          (make-symbolic-link referent installed-skill-target)
          (should-error (diffs-review-install-agent-tools))
          (should (equal (file-symlink-p installed-skill-target)
                         referent))
          (should-not (file-exists-p installed-cli))
          (should-not (file-exists-p installed-cli-library))
          (should-not
           (file-exists-p (expand-file-name "SKILL.md" referent)))
          (with-temp-buffer
            (insert-file-contents sentinel)
            (should
             (equal (buffer-string) "referent must stay untouched"))))
      (delete-directory directory t))))

(ert-deftest diffs-review-installer-replaces-directory-symlink ()
  (let* ((directory (make-temp-file "diffs-install-symlink-" t))
         (assets (expand-file-name "assets/" directory))
         (installed-cli
          (expand-file-name "install/bin/diffs" directory))
         (installed-skill-directory
          (expand-file-name "install/skills/diffs-review/" directory))
         (installed-skill-target
          (directory-file-name installed-skill-directory))
         (referent (expand-file-name "existing-skill/" directory))
         (sentinel (expand-file-name "sentinel" referent)))
    (unwind-protect
        (let ((diffs-review-assets-directory assets)
              (diffs-review-cli-install-path installed-cli)
              (diffs-review-skill-install-directory
               installed-skill-directory))
          (make-directory referent t)
          (make-directory
           (file-name-directory installed-skill-target) t)
          (with-temp-file sentinel
            (insert "referent must stay untouched"))
          (make-symbolic-link referent installed-skill-target)
          (diffs-review-install-agent-tools t)
          (should-not (file-symlink-p installed-skill-target))
          (should (file-directory-p installed-skill-target))
          (should
           (file-regular-p
            (expand-file-name "SKILL.md" installed-skill-directory)))
          (should-not
           (file-exists-p (expand-file-name "SKILL.md" referent)))
          (with-temp-buffer
            (insert-file-contents sentinel)
            (should
             (equal (buffer-string) "referent must stay untouched"))))
      (delete-directory directory t))))

(ert-deftest diffs-review-installer-restores-directory-symlink ()
  (let* ((directory (make-temp-file "diffs-install-symlink-" t))
         (assets (expand-file-name "assets/" directory))
         (installed-cli
          (expand-file-name "install/bin/diffs" directory))
         (installed-cli-library
          (expand-file-name "install/bin/diffs-cli.el" directory))
         (installed-skill-directory
          (expand-file-name "install/skills/diffs-review/" directory))
         (installed-skill-target
          (directory-file-name installed-skill-directory))
         (referent (expand-file-name "existing-skill/" directory))
         (sentinel (expand-file-name "sentinel" referent))
         (original-write
          (symbol-function 'diffs--review-install-write-plan))
         cli-mode library-mode
         (writes 0)
         saw-replacement)
    (unwind-protect
        (let ((diffs-review-assets-directory assets)
              (diffs-review-cli-install-path installed-cli)
              (diffs-review-skill-install-directory
               installed-skill-directory))
          (make-directory referent t)
          (make-directory (file-name-directory installed-cli) t)
          (make-directory
           (file-name-directory installed-skill-target) t)
          (with-temp-file sentinel
            (insert "referent must stay untouched"))
          (with-temp-file installed-cli
            (insert "original cli"))
          (with-temp-file installed-cli-library
            (insert "original library"))
          (setq cli-mode (file-modes installed-cli)
                library-mode (file-modes installed-cli-library))
          (make-symbolic-link referent installed-skill-target)
          (cl-letf
              (((symbol-function 'diffs--review-install-write-plan)
                (lambda (plan)
                  (cl-incf writes)
                  (when (= writes 3)
                    (setq saw-replacement
                          (and
                           (not
                            (file-symlink-p installed-skill-target))
                           (file-directory-p installed-skill-target))))
                  (funcall original-write plan)
                  (when (= writes 3)
                    (error "Synthetic skill write failure")))))
            (should-error (diffs-review-install-agent-tools t)))
          (should (= writes 3))
          (should saw-replacement)
          (should (equal (file-symlink-p installed-skill-target)
                         referent))
          (should-not
           (file-exists-p (expand-file-name "SKILL.md" referent)))
          (should (= (file-modes installed-cli) cli-mode))
          (should (= (file-modes installed-cli-library) library-mode))
          (with-temp-buffer
            (insert-file-contents installed-cli)
            (should (equal (buffer-string) "original cli")))
          (with-temp-buffer
            (insert-file-contents installed-cli-library)
            (should (equal (buffer-string) "original library")))
          (with-temp-buffer
            (insert-file-contents sentinel)
            (should
             (equal (buffer-string) "referent must stay untouched"))))
      (delete-directory directory t))))

(ert-deftest diffs-review-installer-rolls-back-late-write-failure ()
  (let* ((directory (make-temp-file "diffs-install-rollback-" t))
         (assets (expand-file-name "assets/" directory))
         (installed-cli
          (expand-file-name "install/bin/diffs" directory))
         (installed-cli-library
          (expand-file-name "install/bin/diffs-cli.el" directory))
         (installed-skill-directory
          (expand-file-name "install/skills/diffs-review/" directory))
         (original-write
          (symbol-function 'diffs--review-install-write-plan))
         (writes 0))
    (unwind-protect
        (let ((diffs-review-assets-directory assets)
              (diffs-review-cli-install-path installed-cli)
              (diffs-review-skill-install-directory
               installed-skill-directory))
          (make-directory installed-skill-directory t)
          (cl-letf
              (((symbol-function 'diffs--review-install-write-plan)
                (lambda (plan)
                  (cl-incf writes)
                  (if (= writes 2)
                      (error "Synthetic install write failure")
                    (funcall original-write plan)))))
            (should-error (diffs-review-install-agent-tools t)))
          (should (= writes 2))
          (should-not (file-exists-p installed-cli))
          (should-not (file-exists-p installed-cli-library))
          (should (file-directory-p installed-skill-directory))
          (should-not
           (directory-files installed-skill-directory nil
                            directory-files-no-dot-files-regexp)))
      (delete-directory directory t))))

(ert-deftest diffs-sticky-header-follows-file-and-hunk-position ()
  (let ((diffs-file-header-function
         (lambda (context)
           (format "PUBLIC:%s:%s"
                   (plist-get context :view)
                   (plist-get context :file)))))
    (diffs-tests--with-diff diffs-tests--two-files
      (diffs--scan)
      (let* ((section (aref diffs--section-vector 1))
             (hunk (car (plist-get section :hunks))))
        (goto-char (1+ (car hunk)))
        (let ((header (diffs--header-line)))
          (should (string-prefix-p "PUBLIC:stacked:bar.el" header))
          (should (string-match-p "\\[2/2\\]" header))
          (should (string-match-p (regexp-quote "−10 +10") header))
          (should (string-match-p "bar-function" header)))))))

(ert-deftest diffs-sticky-header-yields-to-visible-file-header ()
  (let ((owner (generate-new-buffer " *diffs sticky header test*"))
        old-buffer new-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer owner)
          (insert diffs-tests--two-files)
          (diff-mode)
          (diffs-minor-mode 1)
          (let* ((window (selected-window))
                 (section (car diffs--sections))
                 (hunk (car (plist-get section :hunks))))
            (should-not header-line-format)
            (redisplay t)
            (should (zerop (window-header-line-height window)))
            (run-hook-with-args
             'window-scroll-functions window (car hunk))
            (should-not header-line-format)
            (should
             (window-parameter window 'header-line-format))
            (redisplay t)
            (should (> (window-header-line-height window) 0))
            (run-hook-with-args
             'window-scroll-functions window (plist-get section :beg))
            (should-not
             (window-parameter window 'header-line-format)))
          (dolist (virtualization '(complete paged))
            (ert-info ((format "virtualization: %s" virtualization))
              (let ((diffs-split-virtualization virtualization))
                (diffs-toggle-split)
                (setq new-buffer (current-buffer)
                      old-buffer diffs--split-other)
                (dolist (buffer (list old-buffer new-buffer))
                  (with-current-buffer buffer
                    (should-not header-line-format)))
                (let* ((window (selected-window))
                       (position
                        (with-current-buffer new-buffer
                          (cl-loop
                           for row across diffs--split-rows
                           for index from 0
                           when (and
                                 row
                                 (not (eq (nth 3 row) 'header)))
                           return (diffs--split-row-position index)))))
                  (with-current-buffer new-buffer
                    (run-hook-with-args
                     'window-scroll-functions window position)
                    (should-not header-line-format)
                    (should
                     (window-parameter
                      window 'header-line-format))))
                (diffs-split-quit))))
          (diffs-minor-mode -1))
      (dolist (buffer (list old-buffer new-buffer owner))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-sticky-headers-are-window-local-and-restored ()
  (let ((owner
         (generate-new-buffer " *diffs multiwindow sticky test*"))
        (plain
         (generate-new-buffer " *diffs sticky replacement test*")))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer owner)
          (insert diffs-tests--two-files)
          (diff-mode)
          (delete-other-windows)
          (let* ((first-window (selected-window))
                 (second-window (split-window-right))
                 (external-header '("External window header")))
            (set-window-buffer second-window owner)
            (set-window-parameter
             second-window 'header-line-format external-header)
            (diffs-minor-mode 1)
            (let* ((section (cadr diffs--sections))
                   (hunk (car (plist-get section :hunks)))
                   (hunk-position (car hunk)))
              (should-not header-line-format)
              (diffs--update-sticky-header
               first-window (plist-get (car diffs--sections) :beg))
              (diffs--update-sticky-header
               second-window hunk-position)
              (should-not
               (window-parameter first-window 'header-line-format))
              (should
               (window-parameter second-window 'header-line-format))
              (should
               (eq
                (window-parameter
                 first-window diffs--sticky-header-owner-parameter)
                owner))
              (should
               (eq
                (window-parameter
                 second-window diffs--sticky-header-owner-parameter)
                owner))
              (diffs--update-sticky-header
               first-window hunk-position)
              (should
               (window-parameter first-window 'header-line-format))
              (should
               (window-parameter second-window 'header-line-format))
              (diffs--update-sticky-header
               first-window (plist-get (car diffs--sections) :beg))
              (should-not
               (window-parameter first-window 'header-line-format))
              (should
               (window-parameter second-window 'header-line-format))
              (set-window-buffer second-window plain)
              ;; Batch Emacs does not enter redisplay, so drive the
              ;; standard old-buffer hook that interactive redisplay runs.
              (run-hook-with-args
               'window-buffer-change-functions second-window)
              (should
               (equal
                (window-parameter
                 second-window 'header-line-format)
                external-header))
              (should-not
               (window-parameter
                second-window
                diffs--sticky-header-owner-parameter))
              (diffs-minor-mode -1)
              (should-not
               (window-parameter first-window 'header-line-format))
              (should
               (equal
                (window-parameter
                 second-window 'header-line-format)
                external-header))
              (should-not
               (window-parameter
                first-window diffs--sticky-header-owner-parameter))
              (should-not
               (window-parameter
                second-window
                diffs--sticky-header-owner-parameter)))))
      (dolist (buffer (list owner plain))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-file-icons-cover-file-label-surfaces ()
  (let ((diffs-file-icons t)
        (diffs--nerd-icons-state 'available))
    (cl-letf
        (((symbol-function 'nerd-icons-icon-for-file)
          (lambda (file &rest _)
            (propertize
             (if (string-suffix-p ".el" file) "λ" "□")
             'face 'font-lock-type-face))))
      (let* ((header
              (diffs-default-file-header
               '(:file "src/sample.el" :old-file "src/sample.el"
                 :adds 1 :dels 1)))
             (icon-position (string-match "λ" header))
             (faces (get-text-property icon-position 'face header)))
        (should (string-match-p "λ src/sample\\.el" header))
        (should-not (string-prefix-p "──" header))
        (should
         (diffs-tests--face-includes-p
          faces 'font-lock-type-face))
        (should
         (diffs-tests--face-includes-p
          faces 'diffs-file-header)))
      (should
       (string-match-p
        "λ old\\.el → □ new\\.js"
        (diffs--display-file-label "old.el" "new.js" 40)))
      (diffs-tests--with-diff diffs-tests--normal
        (diffs-minor-mode 1)
        (let* ((owner (current-buffer))
               (section (car diffs--sections))
               (hunk (car (plist-get section :hunks)))
               (logical (diffs--split-collect-hunk section hunk))
               (physical
                (diffs--split-physical-rows
                 (nth 0 logical) (nth 1 logical) 80 nil))
               (index (generate-new-buffer " *diffs icon index test*")))
          (unwind-protect
              (progn
                (goto-char (plist-get section :beg))
                (should
                 (string-match-p "λ foo\\.el"
                                 (diffs--header-line)))
                (diffs--index-render owner index)
                (with-current-buffer index
                  (should
                   (string-match-p "λ foo\\.el" (buffer-string))))
                (with-temp-buffer
                  (diffs-split-mode)
                  (setq-local diffs-file-icons t)
                  (setq-local diffs--split-unified owner)
                  (setq-local diffs--split-role 'new)
                  (diffs--split-install-rows (nth 1 physical)
                                             (plist-get section :width))
                  (goto-char (point-min))
                  (cl-letf (((symbol-function 'get-buffer-window)
                             (lambda (&rest _) nil)))
                    (let ((sticky (diffs--split-header-line)))
                      (should
                       (string-prefix-p
                        "λ foo.el  +2 −1" sticky))
                      (should-not
                       (string-match-p
                        "\\` \\(?:old\\|new\\)  │" sticky))))))
            (kill-buffer index)))
        (diffs-minor-mode -1)))))

(ert-deftest diffs-file-icons-fall-back-to-text-labels ()
  (let ((diffs-file-icons t)
        (diffs--nerd-icons-state 'missing))
    (should
     (equal (diffs--file-label "src/sample.el" 30)
            "src/sample.el")))
  (let ((diffs-file-icons nil)
        (diffs--nerd-icons-state 'available)
        called)
    (cl-letf (((symbol-function 'nerd-icons-icon-for-file)
               (lambda (&rest _)
                 (setq called t)
                 "λ")))
      (should
       (equal (diffs--file-label "src/sample.el" 30)
              "src/sample.el"))
      (should-not called))))

(ert-deftest diffs-changed-file-index-previews-and-visits-files ()
  (let ((owner (generate-new-buffer " *diffs index owner*"))
        index second)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer owner)
          (insert diffs-tests--two-files)
          (diff-mode)
          (diffs-minor-mode 1)
          (setq second (aref diffs--section-vector 1))
          (diffs-toggle-index)
          (setq index diffs--index-buffer)
          (should (buffer-live-p index))
          (should (get-buffer-window index))
          (with-current-buffer index
            (should (derived-mode-p 'diffs-index-mode))
            (should (= (count-lines (point-min) (point-max)) 2))
            (should (equal
                     (plist-get (get-text-property
                                 (point-min) 'diffs-index-section)
                                :file)
                     "foo.el")))
          (select-window (get-buffer-window index))
          (goto-char (point-min))
          (diffs-index-next-file)
          (should (eq (diffs--index-section-at-point) second))
          (should (= (overlay-start diffs--index-current-overlay)
                     (line-beginning-position)))
          (with-current-buffer owner
            (should (= (point) (plist-get second :beg))))
          (diffs-index-visit)
          (should (eq (current-buffer) owner))
          (diffs-toggle-index)
          (should-not (get-buffer-window index))
          (diffs-minor-mode -1)
          (should-not (buffer-live-p index)))
      (dolist (buffer (list index owner))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-index-visibility-survives-split-layout-restoration ()
  (let ((owner (generate-new-buffer " *diffs index split owner*"))
        (diffs-index-width 24)
        index)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer owner)
          (insert diffs-tests--two-files)
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-index)
          (setq index diffs--index-buffer)
          (diffs-toggle-split)
          (should (get-buffer-window index))
          (diffs-toggle-index)
          (should-not (get-buffer-window index))
          (diffs-split-quit)
          (should (eq (current-buffer) owner))
          (should-not (get-buffer-window index))
          (diffs-toggle-split)
          (diffs-toggle-index)
          (should (get-buffer-window index))
          (diffs-split-quit)
          (should (eq (current-buffer) owner))
          (should (get-buffer-window index))
          (diffs-toggle-index)
          (diffs-minor-mode -1))
      (dolist (buffer (list index owner))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-decoration-preserves-buffer-text ()
  (diffs-tests--with-diff diffs-tests--normal
    (let ((text (buffer-string)))
      (diffs-minor-mode 1)
      (should (equal (buffer-string) text))
      (diffs-minor-mode -1)
      (should (equal (buffer-string) text)))))

(ert-deftest diffs-unified-view-adds-theme-native-fringe-bars ()
  (let ((diffs-line-numbers nil))
    (diffs-tests--with-diff diffs-tests--normal
      (diffs-minor-mode 1)
      (should (fringe-bitmap-p 'diffs-fringe-bar))
      (goto-char (point-min))
      (re-search-forward "^-(message")
      (let ((prefix (get-text-property (line-beginning-position)
                                       'line-prefix)))
        (should (equal (get-text-property 0 'display prefix)
                       '(left-fringe diffs-fringe-bar
                         diff-indicator-removed))))
      (re-search-forward "^+(message")
      (let ((prefix (get-text-property (line-beginning-position)
                                       'line-prefix)))
        (should (equal (get-text-property 0 'display prefix)
                       '(left-fringe diffs-fringe-bar
                         diff-indicator-added)))))))

(ert-deftest diffs-unified-change-backgrounds-reach-the-fringe ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs-minor-mode 1)
    (dolist (spec '(("^-(message" diff-removed
                     diff-indicator-removed)
                    ("^+(message" diff-added
                     diff-indicator-added)))
      (goto-char (point-min))
      (re-search-forward (car spec))
      (let* ((prefix
              (get-text-property
               (line-beginning-position) 'line-prefix))
             (gutter-face
              (get-text-property (1- (length prefix)) 'face prefix)))
        (should
         (diffs-tests--face-includes-p gutter-face (cadr spec)))
        (should
         (diffs-tests--face-includes-p gutter-face (caddr spec)))))
    (let ((section (car diffs--sections)))
      (dolist (spec '((?- diff-removed diff-indicator-removed)
                      (?+ diff-added diff-indicator-added)))
        (let* ((prefix
                (diffs--review-resolution-prefix
                 section (car spec) 1 1 nil))
               (gutter-face
                (get-text-property
                 (1- (length prefix)) 'face prefix)))
          (should
           (diffs-tests--face-includes-p
            gutter-face (cadr spec)))
          (should
           (diffs-tests--face-includes-p
            gutter-face (caddr spec))))))))

(ert-deftest diffs-fringe-bars-can-be-disabled ()
  (let ((diffs-line-numbers nil)
        (diffs-fringe-bars nil))
    (diffs-tests--with-diff diffs-tests--normal
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (re-search-forward "^-(message")
      (should-not
       (get-text-property (line-beginning-position) 'line-prefix)))))

(ert-deftest diffs-split-full-width-backgrounds-can-be-disabled ()
  (let ((diffs-split-full-width-backgrounds nil))
    (with-temp-buffer
      (let ((diffs--split-unified (current-buffer))
            (section
             '(:file "foo.el" :item-type diff :width 2)))
        (cl-letf
            (((symbol-function 'diffs--token-section-for-row)
              (lambda (_owner _row) section)))
          (diffs-tests--split-insert-row
           "new" 1 1 'add "foo.el" 2 'new)
          (goto-char (point-min))
          (let* ((prefix (get-text-property (point) 'line-prefix))
                 (prefix-face
                  (get-text-property
                   (1- (length prefix)) 'face prefix)))
            (should
             (diffs-tests--face-includes-p
              prefix-face 'diff-indicator-added))
            (should-not
             (diffs-tests--face-includes-p prefix-face 'diff-added))
            (should-not
             (diffs-tests--face-includes-p
              (get-text-property (line-end-position) 'face)
              'diff-added))))))))

(ert-deftest diffs-split-keeps-refinement-above-the-line-background ()
  (with-temp-buffer
    (diffs-tests--split-insert-row
     (propertize "new" 'face 'diff-refine-added)
     1 1 'add "foo.el" 2 'new)
    (let ((faces (get-text-property (point-min) 'face)))
      (should (eq (car faces) 'diff-refine-added))
      (should (memq 'diffs-split-added-line faces)))))

(ert-deftest diffs-split-changed-lines-keep-source-syntax-faces ()
  (diffs-tests--with-diff
      (concat
       "diff --git a/sample.el b/sample.el\n"
       "--- a/sample.el\n"
       "+++ b/sample.el\n"
       "@@ -1 +1 @@\n"
       "-(defun answer () \"old\")\n"
       "+(defun answer () \"new\")\n")
    (diffs-minor-mode 1)
    (let* ((owner (current-buffer))
           (section (car diffs--sections))
           (hunk (car (plist-get section :hunks)))
           (logical (diffs--split-collect-hunk section hunk))
           (physical
            (diffs--split-physical-rows
             (nth 0 logical) (nth 1 logical) 80 nil)))
      (dolist
          (spec
           (list
            (list (aref (nth 0 physical) 0)
                  'old 'diffs-split-removed-line 'diff-removed)
            (list (aref (nth 1 physical) 0)
                  'new 'diffs-split-added-line 'diff-added)))
        (pcase-let ((`(,row ,role ,line-face ,patch-face) spec))
          (with-temp-buffer
            (let ((begin (point)))
              (insert (car row) "\n")
              (setq-local diffs--split-unified owner)
              (setq-local diffs--split-role role)
              (diffs--split-decorate-row
               begin (point) row (plist-get section :width) role)
              (goto-char begin)
              (search-forward "defun")
              (let ((faces
                     (get-text-property
                      (match-beginning 0) 'face)))
                (should
                 (diffs-tests--face-includes-p
                  faces 'font-lock-keyword-face))
                (should
                 (diffs-tests--face-includes-p faces line-face))
                (should-not
                 (diffs-tests--face-includes-p
                  faces patch-face))))))))
    (diffs-minor-mode -1)))

(ert-deftest diffs-decodes-git-quoted-file-name ()
  (diffs-tests--with-diff
      (concat
       "diff --git \"a/\\344\\270\\255 file.el\" \"b/\\344\\270\\255 file.el\"\n"
       "--- \"a/\\344\\270\\255 file.el\"\n"
       "+++ \"b/\\344\\270\\255 file.el\"\n"
       "@@ -1 +1 @@\n-old\n+new\n")
    (diffs--scan)
    (should (equal (plist-get (car diffs--sections) :file)
                   "中 file.el"))))

(ert-deftest diffs-keeps-metadata-only-details-visible ()
  (diffs-tests--with-diff diffs-tests--rename
    (diffs-minor-mode 1)
    (goto-char (point-min))
    (should (get-text-property (point) 'display))
    (forward-line 1)
    (should-not (get-text-property (point) 'display))
    (should (looking-at "similarity index 100%"))))

(ert-deftest diffs-combined-diff-remains-visible-as-a-fallback ()
  (diffs-tests--with-diff
      (concat
       "diff --cc foo.el\n"
       "index 1111111,2222222..3333333\n"
       "--- a/foo.el\n"
       "+++ b/foo.el\n"
       "@@@ -1,1 -1,1 +1,1 @@@\n"
       "--old\n"
       "++new\n")
    (diffs-minor-mode 1)
    (should (= (length diffs--sections) 1))
    (should (equal (plist-get (car diffs--sections) :file) "foo.el"))
    (goto-char (point-min))
    (re-search-forward "^@@@ ")
    (beginning-of-line)
    (should-not (get-text-property (point) 'display))))

(ert-deftest diffs-present-accepts-metadata-only-diff ()
  (let ((buf (generate-new-buffer " *diffs metadata test*"))
        (diffs-fullscreen nil)
        (diffs-default-view 'stacked))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert diffs-tests--rename))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (&rest _) buf)))
            (diffs--present buf 'Git "HEAD" nil nil))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (equal diffs--stats '(1 0 0)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest diffs-present-rejects-output-without-a-diff ()
  (let ((buf (generate-new-buffer " *diffs empty test*"))
        (diffs-fullscreen nil))
    (with-current-buffer buf
      (insert "commit abc123\n\n    A message, but no patch.\n"))
    (should-error
     (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
       (diffs--present buf 'Git "HEAD" nil nil))
     :type 'user-error)
    (should-not (buffer-live-p buf))))

(ert-deftest diffs-split-collect-preserves-metadata-only-details ()
  (diffs-tests--with-diff diffs-tests--rename
    (diffs--scan)
    (pcase-let ((`(,old ,new . ,_) (diffs--split-collect)))
      (should (= (length old) 4))
      (should (= (length old) (length new)))
      (should (equal (mapcar #'car (cdr old))
                     '("similarity index 100%"
                       "rename from old.el"
                       "rename to new.el"))))))

(ert-deftest diffs-wraps-split-rows-in-aligned-pairs ()
  (let* ((old (list (list "abcdefghij" 7 7 'del "foo.el")))
         (new (list (list "xy" 8 8 'add "foo.el")))
         (physical
          (diffs--split-physical-rows old new 4 t))
         (old-wrapped (append (nth 0 physical) nil))
         (new-wrapped (append (nth 1 physical) nil)))
    (should (= (length old-wrapped) 3))
    (should (= (length old-wrapped) (length new-wrapped)))
    (should (equal (mapcar #'car old-wrapped) '("abcd" "efgh" "ij")))
    (should (equal (mapcar #'car new-wrapped) '("xy" "" "")))
    (should (equal (nth 1 (car old-wrapped)) 7))
    (should-not (nth 1 (cadr old-wrapped)))
    (should (eq (nth 3 (cadr new-wrapped)) 'filler))))

(ert-deftest diffs-split-string-handles-wide-chars-and-properties ()
  (let* ((source (propertize "中abcd" 'face 'font-lock-string-face))
         (chunks (diffs--split-string source 3)))
    (should (equal chunks '("中a" "bcd")))
    (should (eq (get-text-property 0 'face (car chunks))
                'font-lock-string-face))))

(ert-deftest diffs-split-string-reuses-an-unwrapped-string ()
  (let* ((source (propertize "short" 'face 'font-lock-string-face))
         (chunks (diffs--split-string source 80)))
    (should (= (length chunks) 1))
    (should (eq (car chunks) source))))

(ert-deftest diffs-split-view-wraps-and-restores-window-layout ()
  (let ((buf (generate-new-buffer " *diffs split test*"))
        (diffs-split-wrap-lines t)
        old-buf new-buf old-tick new-tick)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert
           (concat
            "diff --git a/foo.el b/foo.el\n"
            "--- a/foo.el\n"
            "+++ b/foo.el\n"
            "@@ -1 +1 @@\n"
            "-" (make-string 120 ?a) "\n"
            "+" (make-string 120 ?b) "\n"))
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other)
          (should (derived-mode-p 'diffs-split-mode))
          (should (buffer-live-p old-buf))
          (should (= (with-current-buffer old-buf
                       (count-lines (point-min) (point-max)))
                     (with-current-buffer new-buf
                       (count-lines (point-min) (point-max)))))
          (should (> (with-current-buffer old-buf
                       (count-lines (point-min) (point-max)))
                     3))
          (with-current-buffer old-buf
            (goto-char (point-min))
            (re-search-forward "aaaa")
            (let ((prefix (get-text-property (line-beginning-position)
                                             'line-prefix)))
              (should (equal (get-text-property 0 'display prefix)
                             '(left-fringe diffs-fringe-bar
                               diff-indicator-removed)))
              (should
               (diffs-tests--face-includes-p
                (get-text-property (1- (length prefix)) 'face prefix)
                'diffs-split-removed-line)))
            (should
             (diffs-tests--face-includes-p
              (get-text-property (line-end-position) 'face)
              'diffs-split-removed-line))
            (should (equal (get-text-property (point) 'diffs-file)
                           "foo.el"))
            (should (get-text-property (point) 'diffs-hunk))
            (cl-letf (((symbol-function 'get-buffer-window)
                       (lambda (&rest _) nil)))
              (should (string-match-p
                       (regexp-quote "foo.el")
                       (diffs--split-header-line))))
            (should
             (eq (face-attribute
                  'diffs-split-removed-line :extend nil 'default)
                 t)))
          (with-current-buffer new-buf
            (goto-char (point-min))
            (re-search-forward "bbbb")
            (let ((prefix (get-text-property (line-beginning-position)
                                             'line-prefix)))
              (should (equal (get-text-property 0 'display prefix)
                             '(left-fringe diffs-fringe-bar
                               diff-indicator-added)))
              (should
               (diffs-tests--face-includes-p
                (get-text-property (1- (length prefix)) 'face prefix)
                'diffs-split-added-line)))
            (should
             (diffs-tests--face-includes-p
              (get-text-property (line-end-position) 'face)
              'diffs-split-added-line))
            (should
             (eq (face-attribute
                  'diffs-split-added-line :extend nil 'default)
                 t)))
          (setq old-tick
                (with-current-buffer old-buf
                  (buffer-chars-modified-tick))
                new-tick
                (with-current-buffer new-buf
                  (buffer-chars-modified-tick)))
          (diffs-split-quit)
          (should (eq (window-buffer) buf))
          (should (buffer-live-p old-buf))
          (should (buffer-live-p new-buf))
          (diffs-toggle-split)
          (should (eq (current-buffer) new-buf))
          (should (eq diffs--split-other old-buf))
          (should (= old-tick
                     (with-current-buffer old-buf
                       (buffer-chars-modified-tick))))
          (should (= new-tick
                     (with-current-buffer new-buf
                       (buffer-chars-modified-tick))))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1))
          (should-not (buffer-live-p old-buf))
          (should-not (buffer-live-p new-buf)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-split-synchronizes-horizontal-scroll-and-line-edges ()
  (let ((buf (generate-new-buffer " *diffs horizontal sync test*"))
        (diffs-split-wrap-lines nil)
        old-buf new-buf old-window new-window)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buf)
          (insert
           (concat
            "diff --git a/foo.el b/foo.el\n"
            "--- a/foo.el\n"
            "+++ b/foo.el\n"
            "@@ -1 +1 @@\n"
            "-" (make-string 120 ?a) "\n"
            "+" (make-string 150 ?a) "\n"))
          (diff-mode)
          (diffs-minor-mode 1)
          (diffs-toggle-split)
          (setq new-buf (current-buffer)
                old-buf diffs--split-other
                new-window (get-buffer-window new-buf)
                old-window (get-buffer-window old-buf))
          (re-search-forward "^aaaa")
          (beginning-of-line)
          (set-window-point new-window (point))
          (let ((this-command 'move-end-of-line))
            (move-end-of-line 1)
            (set-window-point new-window (point))
            (run-hooks 'post-command-hook))
          (should (> (window-hscroll new-window) 0))
          (should (= (window-hscroll old-window)
                     (window-hscroll new-window)))
          (with-current-buffer old-buf
            (goto-char (window-point old-window))
            (should (= (point) (line-end-position))))
          (let ((this-command 'move-beginning-of-line))
            (move-beginning-of-line 1)
            (set-window-point new-window (point))
            (run-hooks 'post-command-hook))
          (should (zerop (window-hscroll new-window)))
          (should (zerop (window-hscroll old-window)))
          (with-current-buffer old-buf
            (goto-char (window-point old-window))
            (should (= (point) (line-beginning-position))))
          (move-to-column 20)
          (set-window-point new-window (point))
          (set-window-hscroll new-window 7)
          (let ((this-command 'scroll-left))
            (run-hooks 'post-command-hook))
          (should (= (window-hscroll old-window) 7))
          (move-to-column 12)
          (should (= (current-column) 12))
          (set-window-point new-window (point))
          (let ((this-command 'forward-char))
            (run-hooks 'post-command-hook))
          (with-current-buffer old-buf
            (goto-char (window-point old-window))
            (should (= (current-column) 12)))
          ;; Mouse and trackpad events can scroll the non-selected
          ;; column while this buffer remains current.  Its changed
          ;; window state must win on the next post-command sync.
          (set-window-hscroll old-window 3)
          (let ((this-command 'mwheel-scroll))
            (run-hooks 'post-command-hook))
          (should (= (window-hscroll new-window) 3))
          (should (= (window-hscroll old-window) 3))
          (diffs-split-quit)
          (with-current-buffer buf
            (diffs-minor-mode -1)))
      (dolist (buffer (list old-buf new-buf buf))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest diffs-commit-uses-first-parent-diff ()
  (let (git-args)
    (cl-letf (((symbol-function 'vc-git-root) (lambda (_) default-directory))
              ((symbol-function 'diffs--prepare-buffer)
               (lambda (_) (generate-new-buffer " *diffs commit test*")))
              ((symbol-function 'vc-git-command)
               (lambda (_buf _ok _files &rest args)
                 (setq git-args args)))
              ((symbol-function 'diffs--present) #'ignore))
      (unwind-protect
          (diffs-commit "abc123")
        (when-let* ((buf (get-buffer " *diffs commit test*")))
          (kill-buffer buf))))
    (should (member "--first-parent" git-args))))

(provide 'diffs-tests)
;;; diffs-tests.el ends here
