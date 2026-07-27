;;; diffs.el --- Fast, pretty file-level diff viewing -*- lexical-binding: t -*-

;; Copyright (C) 2026 Lucius Chen

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: vc, tools

;;; Commentary:

;; A rendering layer over `diff-mode' inspired by https://diffs.com/:
;; old/new line-number columns, no +/- marker noise, styled file and
;; hunk headers, full-width line backgrounds, word-level refinement,
;; source-language syntax highlighting, and a two-window side-by-side
;; view with synchronized scrolling.
;;
;; Everything is implemented with text properties on top of the
;; unmodified diff text, so `diff-goto-source', isearch, `diff-apply-hunk'
;; and the rest of the diff-mode machinery keep working.  Syntax
;; highlighting stays lazy through jit-lock, and on large diffs the
;; decorations themselves are applied lazily as well, so even huge
;; diffs open instantly.  No external processes are used for
;; rendering.
;;
;; Entry points:
;; - `diffs-file': current file against the reference revision.
;; - `diffs-project': whole project against the reference revision.
;; - `diffs-commit': show a commit.
;; - `diffs-commit-at-line': show the commit that last touched the
;;   current line (blame).
;; - `diffs-minor-mode': use the renderer in any diff-mode buffer.
;; - `s' in the view: toggle the side-by-side (split) view.
;;
;; The reference revision integrates with diff-hl: when
;; `diff-hl-reference-revision' is set, the same base is used here.

;;; Code:

(require 'diff-mode)
(require 'vc)
(require 'cl-lib)

(declare-function vc-git-command "vc-git")
(declare-function vc-git-root "vc-git")
(declare-function diff-hl-diff-buffer-with-reference "diff-hl")
(declare-function diff-hl-diff-skip-to "diff-hl")
(declare-function diff-hl-show-hunk-hide "diff-hl-show-hunk")
(defvar vc-git-program)
(defvar diff-hl-update-async)

(defgroup diffs nil
  "Pretty file-level diff viewing."
  :group 'vc)

(defcustom diffs-line-numbers t
  "When non-nil, show old and new line numbers beside diff lines."
  :type 'boolean)

(defcustom diffs-hide-markers t
  "When non-nil, hide the leading +/-/space markers of diff lines."
  :type 'boolean)

(defcustom diffs-prettify-headers t
  "When non-nil, replace file and hunk headers with a compact form."
  :type 'boolean)

(defcustom diffs-lazy-threshold 10000
  "Decorate lazily via jit-lock when the diff has more lines than this.
Lazy decoration makes huge diffs open instantly.  Set to 0 to
always decorate lazily, or to most-positive-fixnum to always
decorate eagerly."
  :type 'natnum)

(defcustom diffs-split-fontify-threshold 4000
  "Fully fontify before splitting only when the diff has fewer lines.
The side-by-side view copies text from the unified buffer, so
word-level refinement and syntax highlighting must be computed for
the whole diff up front.  Beyond this many lines that would be
slow; the split is built instantly with the diff colors only."
  :type 'natnum)

(defcustom diffs-fullscreen t
  "When non-nil, the diffs view takes over the whole frame.
`diffs-quit' (bound to \\`q') restores the previous window layout."
  :type 'boolean)

(defcustom diffs-buffer-name "*diffs*"
  "Name of the buffer used to display diffs."
  :type 'string)

(defface diffs-line-number
  '((t :inherit shadow))
  "Face for the line-number columns.")

(defface diffs-file-header
  '((t :inherit diff-file-header :extend t))
  "Face for the per-file header line.")

(defface diffs-file-stats-added
  '((t :inherit diff-indicator-added))
  "Face for the \"+N\" part of a file header.")

(defface diffs-file-stats-removed
  '((t :inherit diff-indicator-removed))
  "Face for the \"−N\" part of a file header.")

(defface diffs-hunk-separator
  '((t :inherit shadow :extend t))
  "Face for the hunk separator line.")

(defface diffs-filler
  '((t :inherit hl-line :extend t))
  "Face for alignment filler lines in the side-by-side view.
Inherits `hl-line': a tint close to, but distinguishable from,
the background in any theme.")

(defvar-local diffs--stats nil
  "List (FILES ADDED REMOVED) accumulated by the last scan.")

(defvar-local diffs--sections nil
  "List of file-section plists built by `diffs--scan'.
Each element: (:beg N :block-end N :end N :file S :adds N :dels N
:width N :hunks ((POS OLD-START NEW-START) ...)).")

(defvar-local diffs--revision nil
  "Reference revision this buffer was generated against, or nil.")

(defconst diffs--hunk-re "^@@ -\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@\\(.*\\)$")

;;;; Scanning

(defun diffs--section-end ()
  "Return the end position of the file section starting at point."
  (save-excursion
    (forward-line 1)
    (if (re-search-forward "^diff \\|^Index: " nil t)
        (line-beginning-position)
      (point-max))))

(defun diffs--header-block-end (limit)
  "Return the end of the header block starting at point, before LIMIT."
  (save-excursion
    (forward-line 1)
    (while (and (< (point) limit)
                (looking-at "^\\(?:old mode\\|new mode\\|deleted file\\|new file\\|copy \\|rename \\|similarity \\|dissimilarity \\|index \\|--- \\|\\+\\+\\+ \\|Binary files \\|GIT binary patch\\|=\\{4,\\}\\)"))
      (forward-line 1))
    (point)))

(defun diffs--file-name-at-header (block-end)
  "Extract the file name from the header block between point and BLOCK-END."
  (save-excursion
    (cond
     ((looking-at "^diff --git \"?a/\\(?:.*\\)\"? \"?b/\\(.*?\\)\"?$")
      (match-string-no-properties 1))
     ((re-search-forward "^\\+\\+\\+ \"?\\([^\t\n\"]+\\)\"?" block-end t)
      (let ((name (match-string-no-properties 1)))
        (if (string-match "\\`[ab]/" name)
            (substring name 2)
          name)))
     ((looking-at "^\\(?:diff\\|Index:\\) .*?\\([^ \t/]+\\)$")
      (match-string-no-properties 1)))))

(defun diffs--scan-section (section-end)
  "Scan the file section starting at point, up to SECTION-END.
Return a section plist; see `diffs--sections'."
  (let* ((beg (point))
         (block-end (diffs--header-block-end section-end))
         (file (diffs--file-name-at-header block-end))
         (adds 0) (dels 0) (max-line 1) hunks)
    (save-excursion
      (while (re-search-forward diffs--hunk-re section-end t)
        (let* ((old (string-to-number (match-string 1)))
               (oldc (if (match-string 2) (string-to-number (match-string 2)) 1))
               (new (string-to-number (match-string 3)))
               (newc (if (match-string 4) (string-to-number (match-string 4)) 1))
               (hend (save-excursion
                       (or (and (re-search-forward "^@@ \\|^diff \\|^Index: "
                                                   section-end t)
                                (line-beginning-position))
                           section-end))))
          (push (list (line-beginning-position) old new) hunks)
          (setq max-line (max max-line (+ old oldc) (+ new newc)))
          (cl-incf adds (count-matches "^\\+" (line-end-position) hend))
          (cl-incf dels (count-matches "^-" (line-end-position) hend)))))
    (list :beg beg :block-end block-end :end section-end :file file
          :adds adds :dels dels
          :width (max 2 (length (number-to-string max-line)))
          :hunks (nreverse hunks))))

(defun diffs--scan ()
  "Scan the buffer.  Sets `diffs--sections' and `diffs--stats'."
  (save-excursion
    (goto-char (point-min))
    (let (sections (nfiles 0) (nadds 0) (ndels 0))
      (while (not (eobp))
        (cond
         ((looking-at "^\\(?:diff \\|Index: \\|--- \\)")
          ;; A bare "--- " line is a header only when followed by +++.
          (if (and (looking-at "^--- ")
                   (not (save-excursion (forward-line 1)
                                        (looking-at "^\\+\\+\\+ "))))
              (forward-line 1)
            (let ((sec (diffs--scan-section (diffs--section-end))))
              (push sec sections)
              (cl-incf nfiles)
              (cl-incf nadds (plist-get sec :adds))
              (cl-incf ndels (plist-get sec :dels))
              (goto-char (plist-get sec :end)))))
         (t (forward-line 1))))
      (setq diffs--sections (nreverse sections)
            diffs--stats (list nfiles nadds ndels)))))

;;;; Rendering

(defun diffs--put (beg end &rest props)
  "Set PROPS on BEG..END, marking them as owned by diffs."
  (add-text-properties beg end (append '(diffs t) props)))

(defun diffs--undecorate ()
  "Remove all diffs decorations from the buffer."
  (with-silent-modifications
    (let ((pos (point-min)) next)
      (while (setq pos (text-property-any pos (point-max) 'diffs t))
        (setq next (or (text-property-not-all pos (point-max) 'diffs t)
                       (point-max)))
        (remove-list-of-text-properties
         pos next '(diffs display line-prefix wrap-prefix))
        (setq pos next)))))

(defun diffs--decorate-header (sec)
  "Display the header block of section SEC as one styled line."
  (let* ((line (concat
                (propertize (concat "── " (or (plist-get sec :file) "?") "  ")
                            'face 'diffs-file-header)
                (propertize (format "+%d" (plist-get sec :adds))
                            'face 'diffs-file-stats-added)
                " "
                (propertize (format "−%d" (plist-get sec :dels))
                            'face 'diffs-file-stats-removed)
                "\n")))
    (diffs--put (plist-get sec :beg) (plist-get sec :block-end)
                'display line)))

(defun diffs--hunk-end (hunk sec)
  "Return the end position of HUNK in section SEC."
  (let ((rest (cdr (memq hunk (plist-get sec :hunks)))))
    (if rest (caar rest) (plist-get sec :end))))

(defun diffs--decorate-hunk (hunk end width &optional rbeg rend)
  "Decorate HUNK (see `diffs--sections') ending at END.
WIDTH is the number-column width.  When RBEG and REND are
non-nil, only apply properties to lines intersecting that region."
  (save-excursion
    (goto-char (car hunk))
    (let ((old-line (nth 1 hunk))
          (new-line (nth 2 hunk))
          (fmt (format "%%%dd" width))
          (empty (make-string width ?\s)))
      (when (and diffs-prettify-headers
                 (or (null rend) (and (< (point) rend)
                                      (>= (line-end-position) (or rbeg 0))))
                 (looking-at diffs--hunk-re))
        (let ((context (string-trim (match-string 5))))
          (diffs--put (line-beginning-position) (line-end-position)
                      'display (propertize
                                (concat "⋯" (unless (string= context "")
                                              (concat " " context)))
                                'face 'diffs-hunk-separator))))
      (forward-line 1)
      (while (and (< (point) end) (not (eobp)))
        (let* ((c (char-after))
               (old (memq c '(?- ?\s ?\n)))
               (new (memq c '(?+ ?\s ?\n))))
          (when (and (memq c '(?+ ?- ?\s ?\n ?\\))
                     (not (eq c ?\\))
                     (or (null rend)
                         (and (< (point) rend)
                              (>= (1+ (line-end-position)) (or rbeg 0)))))
            (when diffs-line-numbers
              (diffs--put
               (point) (min (point-max) (1+ (line-end-position)))
               'line-prefix
               (propertize
                (concat (if old (format fmt old-line) empty) " "
                        (if new (format fmt new-line) empty) " ")
                'face 'diffs-line-number)
               'wrap-prefix
               (propertize (make-string (+ (* 2 width) 2) ?\s)
                           'face 'diffs-line-number)))
            (when (and diffs-hide-markers (memq c '(?+ ?- ?\s)))
              (diffs--put (point) (1+ (point)) 'display "")))
          (when (memq c '(?+ ?- ?\s ?\n ?\\))
            (unless (eq c ?\\)
              (when old (cl-incf old-line))
              (when new (cl-incf new-line)))))
        (forward-line 1)))))

(defun diffs--decorate-eagerly ()
  "Decorate all content lines from the section index."
  (with-silent-modifications
    (dolist (sec diffs--sections)
      (dolist (hunk (plist-get sec :hunks))
        (diffs--decorate-hunk hunk (diffs--hunk-end hunk sec)
                              (plist-get sec :width))))))

(defun diffs--jit-decorate (beg end)
  "Lazily decorate the lines between BEG and END, from jit-lock."
  (save-excursion
    (goto-char beg) (setq beg (line-beginning-position))
    (goto-char end) (setq end (min (point-max) (1+ (line-end-position)))))
  (with-silent-modifications
    (dolist (sec diffs--sections)
      (when (and (< (plist-get sec :beg) end)
                 (> (plist-get sec :end) beg))
        (dolist (hunk (plist-get sec :hunks))
          (let ((hend (diffs--hunk-end hunk sec)))
            (when (and (< (car hunk) end) (> hend beg))
              (diffs--decorate-hunk hunk hend (plist-get sec :width)
                                    beg end)))))))
  `(jit-lock-bounds ,beg . ,end))

(defun diffs--decorate ()
  "Scan and decorate the whole buffer eagerly.  Sets `diffs--stats'."
  (diffs--undecorate)
  (diffs--scan)
  (with-silent-modifications
    (when diffs-prettify-headers
      (dolist (sec diffs--sections)
        (diffs--decorate-header sec))))
  (diffs--decorate-eagerly))

(defun diffs--decorate-setup ()
  "Scan the buffer and set up eager or lazy content decoration."
  (diffs--undecorate)
  (diffs--scan)
  (with-silent-modifications
    (when diffs-prettify-headers
      (dolist (sec diffs--sections)
        (diffs--decorate-header sec))))
  (if (and font-lock-mode
           (> (count-lines (point-min) (point-max)) diffs-lazy-threshold))
      (jit-lock-register #'diffs--jit-decorate)
    (diffs--decorate-eagerly)))

;;;; Minor mode

(defvar diffs--window-configuration nil
  "Window layout in effect before the diffs view was shown.")

(defun diffs-quit ()
  "Quit the diffs view, restoring the previous window layout."
  (interactive)
  (if (window-configuration-p diffs--window-configuration)
      (progn
        (bury-buffer)
        (set-window-configuration diffs--window-configuration)
        (setq diffs--window-configuration nil))
    (quit-window)))

(defvar-keymap diffs-minor-mode-map
  "q" #'diffs-quit
  "n" #'diff-hunk-next
  "p" #'diff-hunk-prev
  "N" #'diff-file-next
  "P" #'diff-file-prev
  "s" #'diffs-toggle-split
  "g" #'diffs-refresh)

(defvar-local diffs--regenerator nil
  "Function that regenerates this buffer's diff, for `diffs-refresh'.")

;;;###autoload
(define-minor-mode diffs-minor-mode
  "Pretty rendering for `diff-mode' buffers.
Adds line-number columns, hides diff markers, prettifies file and
hunk headers, and enables outline folding (TAB on headings).
\\<diffs-minor-mode-map>Type \\[diffs-toggle-split] for a side-by-side view."
  :lighter " diffs"
  (unless (derived-mode-p 'diff-mode)
    (user-error "`diffs-minor-mode' only works in diff-mode buffers"))
  (if diffs-minor-mode
      (progn
        (setq-local diff-font-lock-prettify nil)
        (when (eq diff-font-lock-syntax t)
          (setq-local diff-font-lock-syntax 'hunk-also))
        (setq-local font-lock-extra-managed-props
                    (remq 'display font-lock-extra-managed-props))
        (diffs--decorate-setup)
        (setq-local outline-minor-mode-cycle t)
        (setq-local outline-minor-mode-highlight nil)
        (outline-minor-mode 1))
    (jit-lock-unregister #'diffs--jit-decorate)
    (outline-minor-mode -1)
    (diffs--undecorate)))

(defun diffs-refresh ()
  "Regenerate the diff shown in this buffer."
  (interactive)
  (if diffs--regenerator
      (funcall diffs--regenerator)
    (revert-buffer)))

;;;; Side-by-side view

(defvar diffs--split-window-configuration nil
  "Window configuration saved before showing the split view.")

(defvar-local diffs--split-other nil
  "The other buffer of a split-view pair.")

(defvar-local diffs--split-unified nil
  "The unified diffs buffer this split view was created from.")

(defvar-local diffs--split-anchors nil
  "Sorted list of hunk anchor line numbers in a split buffer.")

(defvar diffs--split-syncing nil)

(defun diffs--bake-overlay-faces ()
  "Copy overlay faces (refine, syntax) into text properties."
  (with-silent-modifications
    (dolist (o (overlays-in (point-min) (point-max)))
      (when-let* ((face (overlay-get o 'face)))
        (add-face-text-property (overlay-start o) (overlay-end o) face nil)))))

(defun diffs--split-line (pos)
  "Return the line at POS as a string, without marker, with properties."
  (save-excursion
    (goto-char pos)
    (buffer-substring (min (1+ (line-beginning-position)) (line-end-position))
                      (line-end-position))))

(defun diffs--split-collect ()
  "Collect aligned row lists from the current unified diffs buffer.
Returns (OLD-ROWS NEW-ROWS ANCHORS); each row is
\(STRING NUMBER SRC-LINE KIND).  NUMBER is the side's line number
or nil (fillers, headers), SRC-LINE the target line in the file
for RET, KIND one of header, sep, ctx, del, add, filler."
  (let (old-rows new-rows anchors (row 0))
    (cl-flet ((emit (o n)
                (push o old-rows) (push n new-rows) (cl-incf row)))
      (dolist (sec diffs--sections)
        (let* ((file (plist-get sec :file))
               (header (concat
                        (propertize (concat "── " (or file "?") "  ")
                                    'face 'diffs-file-header)
                        (propertize (format "+%d" (plist-get sec :adds))
                                    'face 'diffs-file-stats-added)
                        " "
                        (propertize (format "−%d" (plist-get sec :dels))
                                    'face 'diffs-file-stats-removed))))
          (emit (list header nil nil 'header file)
                (list header nil nil 'header file))
          (dolist (hunk (plist-get sec :hunks))
            (push (1+ row) anchors)
            (let ((sep (propertize "⋯" 'face 'diffs-hunk-separator)))
              (emit (list sep nil nil 'sep file) (list sep nil nil 'sep file)))
            (let ((end (diffs--hunk-end hunk sec))
                  (old-line (nth 1 hunk))
                  (new-line (nth 2 hunk))
                  dels adds)
              (cl-flet ((flush ()
                          (let ((d (nreverse dels)) (a (nreverse adds)))
                            (while (or d a)
                              (emit (or (pop d) (list "" nil new-line 'filler file))
                                    (or (pop a) (list "" nil nil 'filler file)))))
                          (setq dels nil adds nil)))
                (save-excursion
                  (goto-char (car hunk))
                  (forward-line 1)
                  (while (and (< (point) end) (not (eobp)))
                    (let ((c (char-after)))
                      (cond
                       ((memq c '(?\s ?\n))
                        (flush)
                        (let ((s (diffs--split-line (point))))
                          (emit (list s old-line new-line 'ctx file)
                                (list s new-line new-line 'ctx file)))
                        (cl-incf old-line) (cl-incf new-line))
                       ((eq c ?-)
                        (push (list (diffs--split-line (point))
                                    old-line new-line 'del file)
                              dels)
                        (cl-incf old-line))
                       ((eq c ?+)
                        (push (list (diffs--split-line (point))
                                    new-line new-line 'add file)
                              adds)
                        (cl-incf new-line))))
                    (forward-line 1))
                  (flush))))))))
    (list (nreverse old-rows) (nreverse new-rows) (nreverse anchors))))

(defun diffs--split-render (rows width role)
  "Insert ROWS into the current buffer.
WIDTH is the number-column width; ROLE is `old' or `new'."
  (let ((fmt (format "%%%dd " width))
        (empty (make-string (1+ width) ?\s)))
    (pcase-dolist (`(,str ,num ,src ,kind ,file) rows)
      (let ((beg (point)))
        (insert str)
        (let ((face (pcase kind
                      ('del (and (eq role 'old) 'diff-removed))
                      ('add (and (eq role 'new) 'diff-added))
                      ('filler 'diffs-filler))))
          (when face
            (add-face-text-property beg (point) face t)))
        (insert (if (eq kind 'filler)
                    (propertize "\n" 'face 'diffs-filler)
                  "\n"))
        (when (memq kind '(ctx del add filler))
          (put-text-property
           beg (point) 'line-prefix
           (propertize (if num (format fmt num) empty)
                       'face (if (eq kind 'filler)
                                 '(diffs-line-number diffs-filler)
                               'diffs-line-number))))
        (when src
          (put-text-property beg (point) 'diffs-src (cons file src)))))))

(defun diffs--split-sync-from (window &optional start)
  "Align the window(s) paired with WINDOW to its scroll position.
START overrides WINDOW's start position (used from
`window-scroll-functions', which runs before it is committed).
Mirrors the pixel-level vscroll as well, so pixel scrolling stays
in lockstep."
  (let* ((buf (window-buffer window))
         (other (and (buffer-live-p buf)
                     (buffer-local-value 'diffs--split-other buf))))
    (when (buffer-live-p other)
      (let* ((start (or start (window-start window)))
             (vscroll (window-vscroll window t))
             (state (cons start vscroll)))
        (unless (equal state (window-parameter window 'diffs--sync))
          (set-window-parameter window 'diffs--sync state)
          (let* ((line (with-current-buffer buf
                         (count-lines (point-min) start)))
                 (pos (with-current-buffer other
                        (save-excursion
                          (goto-char (point-min))
                          (forward-line line)
                          (point)))))
            (dolist (w (get-buffer-window-list other nil t))
              (set-window-start w pos)
              (set-window-vscroll w vscroll t)
              (set-window-parameter w 'diffs--sync (cons pos vscroll)))))))))

(defun diffs--split-scroll-hook (window start)
  "Member of `window-scroll-functions' while a split view is shown."
  (unless diffs--split-syncing
    (let ((diffs--split-syncing t))
      (with-demoted-errors "diffs split sync: %S"
        (diffs--split-sync-from window start)))))

(defun diffs--split-post-command ()
  "Sync the paired window after commands in a split buffer."
  (unless diffs--split-syncing
    (let ((diffs--split-syncing t)
          (w (selected-window)))
      (when (eq (window-buffer w) (current-buffer))
        (with-demoted-errors "diffs split sync: %S"
          (diffs--split-sync-from w))))))

(defvar-keymap diffs-split-mode-map
  "n" #'diffs-split-next-hunk
  "p" #'diffs-split-prev-hunk
  "RET" #'diffs-split-goto-source
  "s" #'diffs-split-quit
  "q" #'diffs-split-quit)

(define-derived-mode diffs-split-mode special-mode "diffs-split"
  "Major mode for one side of the diffs side-by-side view."
  (setq truncate-lines t)
  (setq-local cursor-in-non-selected-windows nil)
  (add-hook 'post-command-hook #'diffs--split-post-command nil t))

(defun diffs--split-move-to-anchor (next)
  "Move point to the next hunk anchor (previous when NEXT is nil)."
  (let* ((line (line-number-at-pos))
         (target (if next
                     (cl-find-if (lambda (l) (> l line)) diffs--split-anchors)
                   (cl-find-if (lambda (l) (< l line))
                               (reverse diffs--split-anchors)))))
    (unless target (user-error "No more hunks"))
    (goto-char (point-min))
    (forward-line (1- target))
    (dolist (w (get-buffer-window-list diffs--split-other nil t))
      (set-window-point
       w (with-current-buffer diffs--split-other
           (save-excursion
             (goto-char (point-min)) (forward-line (1- target)) (point)))))
    (recenter)
    (diffs--split-sync-from (selected-window))))

(defun diffs-split-next-hunk ()
  "Move to the next hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor t))

(defun diffs-split-prev-hunk ()
  "Move to the previous hunk in the side-by-side view."
  (interactive)
  (diffs--split-move-to-anchor nil))

(defun diffs-split-goto-source ()
  "Visit the source location of the line at point."
  (interactive)
  (let ((src (get-text-property (point) 'diffs-src))
        (dir default-directory))
    (unless src (user-error "No source location on this line"))
    (diffs-split-quit)
    (let ((default-directory dir))
      (find-file (car src)))
    (goto-char (point-min))
    (forward-line (1- (cdr src)))))

(defun diffs-split-quit ()
  "Leave the side-by-side view and return to the unified view."
  (interactive)
  (let ((old (current-buffer))
        (other diffs--split-other))
    (remove-hook 'window-scroll-functions #'diffs--split-scroll-hook)
    (when (window-configuration-p diffs--split-window-configuration)
      (set-window-configuration diffs--split-window-configuration)
      (setq diffs--split-window-configuration nil))
    (when (buffer-live-p other) (kill-buffer other))
    (when (buffer-live-p old) (kill-buffer old))))

(defun diffs-toggle-split ()
  "Toggle between the unified and the side-by-side view."
  (interactive)
  (unless diffs-minor-mode
    (user-error "Not in a diffs buffer"))
  (if (<= (count-lines (point-min) (point-max)) diffs-split-fontify-threshold)
      (progn (font-lock-ensure)
             (diffs--bake-overlay-faces))
    (message "diffs: large diff — splitting without refine/syntax faces"))
  (let* ((unified (current-buffer))
         (width (apply #'max 2 (mapcar (lambda (s) (plist-get s :width))
                                       diffs--sections)))
         (collected (diffs--split-collect))
         (anchors (nth 2 collected))
         (old-buf (get-buffer-create (concat diffs-buffer-name ":old")))
         (new-buf (get-buffer-create (concat diffs-buffer-name ":new")))
         (dir default-directory))
    (dolist (spec (list (list old-buf (nth 0 collected) 'old)
                        (list new-buf (nth 1 collected) 'new)))
      (with-current-buffer (nth 0 spec)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (diffs--split-render (nth 1 spec) width (nth 2 spec)))
        (goto-char (point-min))
        (diffs-split-mode)
        (setq default-directory dir)
        (setq-local diffs--split-unified unified)
        (setq-local diffs--split-anchors anchors)
        (setq header-line-format
              (list (format " %s" (if (eq (nth 2 spec) 'old)
                                      (or (buffer-local-value 'diffs--revision
                                                              unified)
                                          "old")
                                    "new"))))))
    (with-current-buffer old-buf (setq-local diffs--split-other new-buf))
    (with-current-buffer new-buf (setq-local diffs--split-other old-buf))
    (setq diffs--split-window-configuration (current-window-configuration))
    (add-hook 'window-scroll-functions #'diffs--split-scroll-hook)
    (let* ((w1 (or (get-buffer-window unified) (selected-window)))
           (w2 (progn (set-window-buffer w1 old-buf)
                      (split-window w1 nil 'right))))
      (set-window-buffer w2 new-buf)
      (select-window w2)
      (diffs--split-sync-from w2))))

;;;; Diff generation

(defun diffs--reference-revision ()
  "Return the reference revision to diff against, or nil for the default."
  (bound-and-true-p diff-hl-reference-revision))

(defun diffs--header-line ()
  (cl-destructuring-bind (&optional (files 0) (adds 0) (dels 0)) diffs--stats
    (concat
     " "
     (if (= files 1) "1 file" (format "%d files" files))
     " · "
     (propertize (format "+%d" adds) 'face 'diffs-file-stats-added)
     " "
     (propertize (format "−%d" dels) 'face 'diffs-file-stats-removed)
     (when diffs--revision
       (format " · vs %s" diffs--revision)))))

(defun diffs--present (buf backend rev &optional line regenerator)
  "Set up and display the diff in BUF.
BACKEND and REV are used for revision-aware syntax highlighting.
LINE, if non-nil, is the source line to move to.  REGENERATOR is
stored for `diffs-refresh'."
  (with-current-buffer buf
    (goto-char (point-min))
    (unless (re-search-forward "^@@ \\|^Binary files " nil t)
      (kill-buffer buf)
      (user-error "No changes"))
    (goto-char (point-min))
    (diff-mode)
    (setq-local diff-vc-backend backend)
    (when rev
      (setq-local diff-vc-revisions (list rev nil)))
    (setq buffer-read-only t)
    (setq-local diffs--revision rev)
    (setq-local diffs--regenerator regenerator)
    (diffs-minor-mode 1)
    (setq header-line-format '((:eval (diffs--header-line)))))
  (unless (get-buffer-window buf)
    (setq diffs--window-configuration (current-window-configuration)))
  (pop-to-buffer buf)
  (when diffs-fullscreen
    (delete-other-windows))
  (when line
    (require 'diff-hl nil t)
    (when (fboundp 'diff-hl-diff-skip-to)
      (ignore-errors (diff-hl-diff-skip-to line)))))

(defun diffs--prepare-buffer (dir)
  "Return the diffs buffer, emptied, with `default-directory' DIR."
  (let ((buf (get-buffer-create diffs-buffer-name)))
    (with-current-buffer buf
      (when diffs-minor-mode (diffs-minor-mode -1))
      (fundamental-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (setq default-directory dir))
    buf))

;;;###autoload
(defun diffs-file ()
  "Show a pretty diff of the current file against the reference revision.
Unsaved changes are included when diff-hl is available.  The
reference is `diff-hl-reference-revision' when set, otherwise the
last revision."
  (interactive)
  (let* ((file (or (buffer-file-name)
                   (user-error "Buffer is not visiting a file")))
         (backend (or (vc-backend file)
                      (user-error "File is not under version control")))
         (rev (diffs--reference-revision))
         (line (line-number-at-pos))
         (unsaved (and (buffer-modified-p)
                       (require 'diff-hl nil t)
                       (fboundp 'diff-hl-diff-buffer-with-reference)))
         ;; The unsaved diff labels files with their base name; the
         ;; VC diff uses root-relative names.
         (buf (diffs--prepare-buffer
               (if unsaved
                   (file-name-directory file)
                 (vc-call-backend backend 'root
                                  (file-name-directory file))))))
    (if unsaved
        (let ((diff-hl-update-async nil))
          (diff-hl-diff-buffer-with-reference file buf backend 3))
      (vc-call-backend backend 'diff (list file) rev nil buf nil))
    (diffs--present buf backend rev line
                    (lambda ()
                      (if-let* ((b (find-buffer-visiting file)))
                          (with-current-buffer b (diffs-file))
                        (user-error "Source buffer was killed"))))))

;;;###autoload
(defun diffs-project ()
  "Show a pretty diff of the whole project against the reference revision."
  (interactive)
  (let* ((backend (or (ignore-errors (vc-deduce-backend))
                      (ignore-errors (vc-responsible-backend default-directory))
                      (user-error "Not in a version-controlled directory")))
         (root (vc-call-backend backend 'root default-directory))
         (rev (diffs--reference-revision))
         (buf (diffs--prepare-buffer root))
         (default-directory root))
    (vc-call-backend backend 'diff nil rev nil buf nil)
    (diffs--present buf backend rev nil #'diffs-project)))

;;;###autoload
(defun diffs-commit (rev &optional file)
  "Show a pretty diff of commit REV, limited to FILE when non-nil.
Only supports Git."
  (interactive (list (read-string "Commit: " nil nil
                                  (thing-at-point 'symbol t))))
  (require 'vc-git)
  (let* ((default-directory
          (or (vc-git-root default-directory)
              (user-error "Not in a Git repository")))
         (buf (diffs--prepare-buffer default-directory)))
    (apply #'vc-git-command buf 1 nil
           `("show" ,rev "--" ,@(and file (list (file-relative-name file)))))
    (diffs--present buf 'Git (format "%s^" rev) nil
                    (lambda () (diffs-commit rev file)))))

;;;###autoload
(defun diffs-commit-at-line (&optional file-only)
  "Show the commit that last modified the current line.
With prefix argument FILE-ONLY, limit the diff to the current file.
Blames the saved file, so save first for accurate results."
  (interactive "P")
  (require 'vc-git)
  (let* ((file (or (buffer-file-name)
                   (user-error "Buffer is not visiting a file")))
         (line (line-number-at-pos))
         (default-directory (file-name-directory file))
         (sha
          (with-temp-buffer
            (unless (zerop (call-process vc-git-program nil t nil
                                         "blame" "-L" (format "%d,%d" line line)
                                         "--porcelain" "--"
                                         (file-name-nondirectory file)))
              (user-error "git blame failed (file not committed?)"))
            (goto-char (point-min))
            (car (split-string (buffer-substring-no-properties
                                (point) (line-end-position)))))))
    (when (or (null sha) (string-match-p "\\`0+\\'" sha))
      (user-error "Line is not committed yet"))
    (diffs-commit sha (and file-only file))))

;;;###autoload
(defun diffs-file-from-hunk ()
  "Open the file-level diffs view from the diff-hl show-hunk popup."
  (interactive)
  (when (fboundp 'diff-hl-show-hunk-hide)
    (diff-hl-show-hunk-hide))
  (diffs-file))

(provide 'diffs)
;;; diffs.el ends here
