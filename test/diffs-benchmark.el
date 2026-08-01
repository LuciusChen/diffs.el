;;; diffs-benchmark.el --- Reproducible diffs.el benchmark -*- lexical-binding: t -*-

(require 'benchmark)
(require 'cl-lib)
(require 'diffs)

(defvar diffs-benchmark--profile
  (intern (or (getenv "DIFFS_BENCH_PROFILE") "volume")))

(defvar diffs-benchmark--files
  (string-to-number
   (or (getenv "DIFFS_BENCH_FILES")
       (if (eq diffs-benchmark--profile 'complex) "16" "800"))))

(defvar diffs-benchmark--virtualization
  (intern
   (or (getenv "DIFFS_BENCH_VIRTUALIZATION") "auto")))

(defun diffs-benchmark--volume-input ()
  "Build a large Git diff that isolates scaling costs."
  (with-temp-buffer
    (dotimes (file diffs-benchmark--files)
      (let* ((contexts (+ 20 (if (< file (/ diffs-benchmark--files 2)) 1 0)))
             (count (1+ contexts)))
        (insert (format "diff --git a/src/f%d.el b/src/f%d.el\n" file file))
        (insert "index 1111111..2222222 100644\n")
        (insert (format "--- a/src/f%d.el\n+++ b/src/f%d.el\n" file file))
        (insert (format "@@ -1,%d +1,%d @@\n" count count))
        (dotimes (line contexts)
          (insert (format " (message \"context %02d\")\n" line)))
        ;; Keep replacements unique so the within-line cache cannot make
        ;; hundreds of files look like one comparison.
        (insert (format "-(message \"old value %04d\")\n" file))
        (insert (format "+(message \"new value %04d\")\n" file))))
    (buffer-string)))

(defun diffs-benchmark--complex-input ()
  "Build a Git diff with expensive, varied change blocks."
  (with-temp-buffer
    (cl-labels
        ((context-line
          (file hunk line)
          (format
           " (message \"context file=%02d hunk=%d line=%d / 上下文 café\")\n"
           file hunk line))
         (changed-line
          (marker file hunk line source old-p)
          (format
           (concat
            "%c    (setf (alist-get 'recordValue_%02d_%02d_%02d cache) "
            "(list :account-id \"acct/%02d/%02d/%02d\" "
            ":display-name \"%s 用户 café é 🙂\" "
            ":roles '(%s) :flags [active %s beta] "
            ":payload (format \"%%s::%%04d\" tenant-id %d)))\n")
           marker file hunk source file hunk source
           (if old-p "Legacy" "Revised")
           (if old-p "reader editor" "reader reviewer editor")
           (if old-p "nil" "t") line)))
      (dotimes (file diffs-benchmark--files)
        (insert (format "diff --git a/src/complex-%02d.el b/src/complex-%02d.el\n"
                        file file))
        (insert "index 1111111..2222222 100644\n")
        (insert (format "--- a/src/complex-%02d.el\n+++ b/src/complex-%02d.el\n"
                        file file))
        (dotimes (hunk 3)
          (let* ((old-lines (+ 10 (% (+ file hunk) 5)))
                 (new-lines (+ 9 (% (+ file (* 2 hunk)) 7)))
                 (old-start (+ 1 (* hunk 100)))
                 (new-start (+ 1 (* hunk 110)))
                 (old-count (+ old-lines 4))
                 (new-count (+ new-lines 4)))
            (insert (format "@@ -%d,%d +%d,%d @@ complex block %d\n"
                            old-start old-count new-start new-count hunk))
            (dotimes (line 2)
              (insert (context-line file hunk line)))
            (dotimes (line old-lines)
              (insert (changed-line ?- file hunk line line t)))
            (dotimes (line new-lines)
              (let ((source
                     (% (+ line (if (zerop (% hunk 2)) 1 2))
                        old-lines)))
                (insert
                 (changed-line ?+ file hunk line source nil))))
            (dotimes (line 2)
              (insert (context-line file hunk (+ line 2))))))
        ;; Exercise the long-line pairing and intraline guards once per
        ;; file without making every alignment compare thousand-character
        ;; strings.
        (insert "@@ -901,2 +931,2 @@ long replacement\n")
        (insert " (message \"tail context\")\n")
        (insert "-(message \"long legacy payload: ")
        (insert (make-string 1100 ?x))
        (insert " / 长行 🙂\")\n")
        (insert "+(message \"long revised payload: ")
        (insert (make-string 1100 ?x))
        (insert " / 长行 🙂\")\n")))
    (buffer-string)))

(defun diffs-benchmark--input ()
  "Build the Git diff selected by `diffs-benchmark--profile'."
  (pcase diffs-benchmark--profile
    ('volume (diffs-benchmark--volume-input))
    ('complex (diffs-benchmark--complex-input))
    (_ (error "Unknown benchmark profile: %S"
              diffs-benchmark--profile))))

(defun diffs-benchmark--measure (name repetitions function)
  "Print timings for calling FUNCTION REPETITIONS times under NAME."
  (garbage-collect)
  (let ((result (benchmark-call function repetitions)))
    (princ
     (format "%-20s %3d × %8.3f ms  GC %d / %.3f s\n"
             name repetitions
             (* 1000 (/ (nth 0 result) (float repetitions)))
             (nth 1 result) (nth 2 result)))))

(defun diffs-benchmark--goto-first-change ()
  "Move point to the first unresolved changed row in a split buffer."
  (let ((index
         (cl-position-if
          (lambda (row)
            (memq (nth 3 row) '(add del)))
          diffs--split-rows)))
    (unless index
      (error "Benchmark input has no split change row"))
    (goto-char (diffs--split-row-position index))
    (when-let* ((window (get-buffer-window (current-buffer))))
      (diffs--split-materialize-window window))))

(let* ((text (diffs-benchmark--input))
       (buffer (generate-new-buffer " *diffs-benchmark*"))
       (diffs-split-virtualization diffs-benchmark--virtualization)
       effective-model)
  (unwind-protect
      (progn
        (with-current-buffer buffer
          (insert text)
          (diff-mode)
          ;; Batch Emacs forcibly keeps `font-lock-mode' disabled.  Mark
          ;; the buffer as font-locked before diffs.el setup so this
          ;; exercises the lazy interactive path; `jit-lock-register'
          ;; installs the actual redisplay worker below.
          (setq-local font-lock-mode t))
        (princ
         (format (concat "Emacs %s; %s profile; %s split policy; "
                         "%d files; %d lines; %d bytes\n")
                 emacs-version diffs-benchmark--profile
                 diffs-benchmark--virtualization
                 diffs-benchmark--files
                 (with-current-buffer buffer
                   (count-lines (point-min) (point-max)))
                 (string-bytes text)))
        (diffs-benchmark--measure
         "scan" 30
         (lambda ()
           (with-current-buffer buffer
             (diffs--scan))))
        (diffs-benchmark--measure
         "stacked setup" 1
         (lambda ()
           (with-current-buffer buffer
             (diffs-minor-mode 1))))
        (princ
         (format "estimated change work: %d\n"
                 (with-current-buffer buffer
                   (diffs--estimated-change-work))))
        (when (eq diffs-benchmark--profile 'complex)
          (let* ((section
                  (with-current-buffer buffer
                    (car diffs--sections)))
                 (hunk (car (plist-get section :hunks)))
                 (end
                  (with-current-buffer buffer
                    (diffs--hunk-end hunk section))))
            (with-current-buffer buffer
              (diffs--clear-intraline))
            (diffs-benchmark--measure
             "cold hunk pairing" 1
             (lambda ()
               (with-current-buffer buffer
                 (diffs--split-collect-hunk section hunk t))))
            (with-current-buffer buffer
              (diffs--clear-intraline))
            (diffs-benchmark--measure
             "cold hunk refine" 1
             (lambda ()
               (with-current-buffer buffer
                 (diffs--refine-hunk hunk end))))
            (with-current-buffer buffer
              (diffs--clear-intraline))))
        (when (with-current-buffer buffer
                (memq #'diffs--jit-decorate jit-lock-functions))
          (diffs-benchmark--measure
           "stacked viewport" 1
           (lambda ()
             (with-current-buffer buffer
               (jit-lock-fontify-now
                (point-min)
                (save-excursion
                  (goto-char (point-min))
                  (forward-line 100)
                  (point)))))))
        (switch-to-buffer buffer)
        (diffs-benchmark--measure
         "first split" 1
         (lambda ()
           (with-current-buffer buffer
             (switch-to-buffer buffer)
             (diffs--split-cache-clear)
             (diffs-toggle-split)
             (setq effective-model
                   (if (buffer-local-value
                        'diffs--split-paged-p
                        (window-buffer))
                       'paged
                     'complete)))
           (with-current-buffer (window-buffer)
             (diffs-split-quit))))
        (princ (format "effective split model: %s\n" effective-model))
        (diffs-benchmark--measure
         "deep viewport" 1
         (lambda ()
           (with-current-buffer buffer
             (switch-to-buffer buffer)
             (diffs-toggle-split))
           (let* ((split (window-buffer))
                  (window (get-buffer-window split)))
             (with-current-buffer split
               (let* ((count (length diffs--split-rows))
                      (index (max 0 (- count 100)))
                      (position
                       (diffs--split-row-position index)))
                 (set-window-start window position)
                 (diffs--split-materialize-window window)
                 (diffs-split-quit))))))
        (diffs-benchmark--measure
         "cached split" 10
         (lambda ()
           (with-current-buffer buffer
             (switch-to-buffer buffer)
             (diffs-toggle-split))
           (with-current-buffer (window-buffer)
             (diffs-split-quit))))
        (when (eq effective-model 'paged)
          (with-current-buffer buffer
            (switch-to-buffer buffer)
            (diffs-toggle-split))
          (diffs-benchmark--measure
           "full projection" 1
           (lambda ()
             (with-current-buffer (window-buffer)
               (diffs--split-paged-materialize-all))))
          (with-current-buffer (window-buffer)
            (diffs-split-quit)))
        ;; Exercise the installed public commands from the primary split
        ;; workflow.  Each action invalidates and rebuilds the decision-aware
        ;; split, so these timings include the complete interactive path.
        (with-current-buffer buffer
          (switch-to-buffer buffer)
          (diffs-toggle-split))
        (with-current-buffer (window-buffer)
          (diffs-benchmark--goto-first-change))
        (diffs-benchmark--measure
         "decision A (split)" 1
         (lambda ()
           (with-current-buffer (window-buffer)
             (let ((inhibit-message t))
               (diffs-review-accept-change)))))
        (diffs-benchmark--measure
         "decision R (split)" 1
         (lambda ()
           (with-current-buffer (window-buffer)
             (let ((inhibit-message t))
               (diffs-review-reject-change)))))
        (with-current-buffer (window-buffer)
          (let ((inhibit-message t))
            (diffs-review-reset-change))
          (diffs-split-quit)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

;;; diffs-benchmark.el ends here
