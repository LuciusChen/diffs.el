;;; diffs-diff-hl.el --- Diff-hl presentation adapter for diffs.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.13.0
;; Keywords: vc, tools

;;; Commentary:

;; Optional diff-hl show-hunk presentation using diffs.el's stacked or
;; side-by-side renderer.  Diff-hl retains placement, actions, and cleanup.

;;; Code:

(require 'diffs)

(declare-function diff-hl-show-hunk-inline "diff-hl-show-hunk-inline")
(declare-function diff-hl-show-hunk-posframe "diff-hl-show-hunk-posframe")

(defvar diff-hl-show-hunk-function)
(defvar diff-hl-show-hunk-inline-smart-lines)

(defvar diffs--diff-hl-show-hunk-function-before-mode nil
  "Value of `diff-hl-show-hunk-function' before integration is enabled.")

(defvar diffs--diff-hl-show-hunk-function-saved-p nil
  "Non-nil when the prior diff-hl renderer has been saved.")

(defconst diffs--diff-hl-split-buffer-name " *diffs diff-hl split*"
  "Hidden carrier buffer for a side-by-side diff-hl hunk.")

(defun diffs--diff-hl-line-display (begin end)
  "Return the diffs-rendered replacement for line BEGIN through END.
The current buffer must be an eagerly decorated complete diff."
  (let* ((prefix
          (copy-sequence
           (or (get-text-property begin 'line-prefix) "")))
         (prefix-width (length prefix))
         (line (buffer-substring begin end))
         (rendered (concat prefix line)))
    ;; The prefix is now literal content of the replacement string.
    ;; Retaining these properties on LINE would ask redisplay to add it
    ;; a second time.
    (remove-list-of-text-properties
     prefix-width (length rendered) '(line-prefix wrap-prefix) rendered)
    ;; Source modes can express syntax through overlays.  Materialize
    ;; those faces before the word refinement, which must remain the
    ;; highest visual layer.
    (dolist (overlay (overlays-in begin end))
      (when-let* (((not (overlay-get overlay 'diffs-intraline)))
                  ((not (overlay-get overlay 'diffs-review)))
                  (face (overlay-get overlay 'face)))
        (add-face-text-property
         (+ prefix-width (- (max begin (overlay-start overlay)) begin))
         (+ prefix-width (- (min end (overlay-end overlay)) begin))
         face nil rendered)))
    (dolist (overlay (overlays-in begin end))
      (when-let* (((overlay-get overlay 'diffs-intraline))
                  (face (overlay-get overlay 'face)))
        (add-face-text-property
         (+ prefix-width (- (max begin (overlay-start overlay)) begin))
         (+ prefix-width (- (min end (overlay-end overlay)) begin))
         face nil rendered)))
    rendered))

(defun diffs--diff-hl-split-side
    (row role width content-width unified scratch &optional pad)
  "Render one split ROW for ROLE into a string.
WIDTH is the line-number width, CONTENT-WIDTH is the minimum code
column width, UNIFIED owns source faces, and SCRATCH is reusable.
When PAD is non-nil, pad the code to CONTENT-WIDTH."
  (with-current-buffer scratch
    (let* ((inhibit-read-only t)
           (diffs-fringe-bars nil)
           (text (car row))
           (padding
            (if pad
                (make-string
                 (max 0 (- content-width (string-width text))) ?\s)
              "")))
      (erase-buffer)
      (insert text padding)
      (setq-local diffs--split-unified unified)
      (setq-local diffs--split-role role)
      (diffs--split-decorate-row
       (point-min) (point-max) row width role)
      (let* ((prefix
              (copy-sequence
               (or (get-text-property (point-min) 'line-prefix) "")))
             (line (buffer-substring (point-min) (point-max))))
        (remove-list-of-text-properties
         0 (length line) '(line-prefix wrap-prefix) line)
        (concat prefix line)))))

(defun diffs--diff-hl-split-buffer
    (section hunk available-width)
  "Return a carrier buffer rendering HUNK in SECTION side by side.
AVAILABLE-WIDTH is the source window width in columns.  The current
buffer is the decorated unified owner."
  (let* ((unified (current-buffer))
         (number-width (plist-get section :width))
         (separator (propertize " │ " 'face 'shadow))
         ;; Diff-hl's posframe backend asks posframe to enable wrapping.
         ;; Leave room before the parent window edge: a replacement
         ;; string that exactly fills it otherwise produces an empty
         ;; continuation row after every logical diff row.
         (total-width (max 20 (- available-width 2)))
         (column-width
          (max 12 (/ (- total-width (string-width separator)) 2)))
         (gutter-width (if diffs-line-numbers (1+ number-width) 0))
         (content-width (max 4 (- column-width gutter-width)))
         (logical (diffs--split-collect-hunk section hunk))
         (physical
          (diffs--split-physical-rows
           (nth 0 logical) (nth 1 logical)
           content-width diffs-split-wrap-lines))
         (old-rows (nth 0 physical))
         (new-rows (nth 1 physical))
         (old-scratch (generate-new-buffer " *diffs old hunk row*"))
         (new-scratch (generate-new-buffer " *diffs new hunk row*"))
         lines)
    (unwind-protect
        (dotimes (index (length old-rows))
          (push
           (concat
            (diffs--diff-hl-split-side
             (aref old-rows index) 'old number-width content-width
             unified old-scratch t)
            separator
            (diffs--diff-hl-split-side
             (aref new-rows index) 'new number-width content-width
             unified new-scratch))
           lines))
      (kill-buffer old-scratch)
      (kill-buffer new-scratch))
    (let ((carrier
           (get-buffer-create diffs--diff-hl-split-buffer-name)))
      (with-current-buffer carrier
        (let ((inhibit-read-only t))
          (fundamental-mode)
          (erase-buffer)
          (remove-overlays)
          (setq default-directory
                (buffer-local-value 'default-directory unified))
          (dolist (line (nreverse lines))
            (let ((begin (point)))
              ;; Keeping the rendered row inside a display replacement
              ;; protects its layered faces from diff-hl backends that
              ;; apply a carrier-wide `face' property.
              (insert " ")
              (put-text-property begin (point) 'display line)
              (insert "\n")))
          (setq-local truncate-lines (not diffs-split-wrap-lines))
          (setq buffer-read-only t)
          (goto-char (point-min))))
      carrier)))

(defun diffs--diff-hl-render-current-hunk (buffer)
  "Render BUFFER's narrowed hunk without changing its patch text.
Diff-hl supplies BUFFER narrowed to the current hunk while retaining the
complete patch outside the restriction.  The complete patch is used for
diffs.el's scan and matching.  `diffs-default-view' selects a stacked
replacement in BUFFER or a separate side-by-side carrier."
  (unless (buffer-live-p buffer)
    (user-error "Diff-hl supplied a dead diff buffer"))
  (let* ((directory default-directory)
         (layout diffs-default-view)
         (available-width (window-body-width))
         (hunk-begin (with-current-buffer buffer (point-min)))
         (hunk-end (with-current-buffer buffer (point-max)))
         (patch
          (with-current-buffer buffer
            (save-restriction
              (widen)
              (buffer-substring-no-properties
               (point-min) (point-max)))))
         replacements
         rendered-buffer)
    (with-temp-buffer
      (setq default-directory directory)
      (insert patch)
      (delay-mode-hooks
        (diff-mode))
      (setq-local diff-refine nil)
      (setq-local diff-font-lock-syntax 'hunk-also)
      (font-lock-mode 1)
      (diffs--undecorate)
      (diffs--scan)
      (let* ((section (diffs--section-at-pos hunk-begin))
             (hunk (and section
                        (diffs--hunk-at-pos section hunk-begin))))
        (unless hunk
          (error "Diff-hl's narrowed region is not inside a diff hunk"))
        (font-lock-ensure (car hunk) (diffs--hunk-end hunk section))
        (with-silent-modifications
          (diffs--decorate-hunk
           hunk (diffs--hunk-end hunk section) section
           hunk-begin hunk-end))
        (if (eq layout 'split)
            (setq rendered-buffer
                  (diffs--diff-hl-split-buffer
                   section hunk available-width))
          (save-excursion
            (goto-char hunk-begin)
            (while (< (point) hunk-end)
              (let ((begin (point))
                    (end (min hunk-end (line-end-position))))
                (push (list begin end
                            (diffs--diff-hl-line-display begin end))
                      replacements))
              (forward-line 1))))))
    (if rendered-buffer
        rendered-buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (with-silent-modifications
            (save-restriction
              (widen)
              (dolist (replacement replacements)
                (pcase-let ((`(,begin ,end ,display) replacement))
                  (when (< begin end)
                    ;; Some diff-hl releases add their own line-number
                    ;; prefix before invoking a backend.  Diffs.el's
                    ;; replacement already contains its old/new columns.
                    (remove-list-of-text-properties
                     begin end '(line-prefix wrap-prefix))
                    (add-text-properties
                     begin end
                     (list 'diffs-diff-hl t 'display display)))))))))
      buffer)))

(defun diffs--diff-hl-display-backend ()
  "Return the public diff-hl backend for the rendered current hunk."
  (let ((backend
         (or diffs-diff-hl-display-function
             (and diffs--diff-hl-show-hunk-function-saved-p
                  (not (eq diffs--diff-hl-show-hunk-function-before-mode
                           #'diffs-diff-hl-show-hunk))
                  diffs--diff-hl-show-hunk-function-before-mode)
             #'diff-hl-show-hunk-inline)))
    (when (eq backend #'diffs-diff-hl-show-hunk)
      (user-error "Diffs.el cannot use its adapter as a display backend"))
    (pcase backend
      ('diff-hl-show-hunk-inline
       (unless (require 'diff-hl-show-hunk-inline nil t)
         (user-error "Diff-hl's inline hunk backend is not available")))
      ('diff-hl-show-hunk-posframe
       (unless (require 'diff-hl-show-hunk-posframe nil t)
         (user-error "Diff-hl's posframe hunk backend is not available"))))
    (unless (functionp backend)
      (user-error "Diff-hl hunk display backend is not callable: %S" backend))
    backend))

;;;###autoload
(defun diffs-diff-hl-show-hunk (buffer &optional line)
  "Render diff-hl's current hunk BUFFER with diffs.el.
LINE is the hunk-relative source line supplied to the selected public
diff-hl display backend.  `diffs-default-view' selects the hunk's split
or stacked content layout.  Diffs.el changes only display properties;
diff-hl retains placement, navigation, actions, and cleanup."
  (let ((backend (diffs--diff-hl-display-backend))
        (rendered (diffs--diff-hl-render-current-hunk buffer)))
    (if (eq backend #'diff-hl-show-hunk-inline)
        ;; Upstream's smart-lines default sizes the popup to deleted
        ;; lines and replaces a pure-addition hunk with a message.
        ;; A diffs-rendered preview shows the complete current hunk.
        (let ((diff-hl-show-hunk-inline-smart-lines nil))
          (funcall backend rendered line))
      (funcall backend rendered line))))

;;;###autoload
(define-minor-mode diffs-diff-hl-mode
  "Use diffs.el as diff-hl's show-hunk renderer.
This global opt-in saves and restores `diff-hl-show-hunk-function'.
It does not change diff-hl keymaps or enable diff-hl mouse handling."
  :global t
  :group 'diffs
  (if diffs-diff-hl-mode
      (condition-case error-data
          (progn
            (unless (require 'diff-hl-show-hunk nil t)
              (user-error "Diff-hl-show-hunk is not available"))
            (unless diffs--diff-hl-show-hunk-function-saved-p
              (setq diffs--diff-hl-show-hunk-function-before-mode
                    diff-hl-show-hunk-function
                    diffs--diff-hl-show-hunk-function-saved-p t))
            (setq diff-hl-show-hunk-function
                  #'diffs-diff-hl-show-hunk))
        (error
         (setq diffs-diff-hl-mode nil)
         (signal (car error-data) (cdr error-data))))
    (when diffs--diff-hl-show-hunk-function-saved-p
      (setq diff-hl-show-hunk-function
            diffs--diff-hl-show-hunk-function-before-mode
            diffs--diff-hl-show-hunk-function-before-mode nil
            diffs--diff-hl-show-hunk-function-saved-p nil))))

(provide 'diffs-diff-hl)
;;; diffs-diff-hl.el ends here
