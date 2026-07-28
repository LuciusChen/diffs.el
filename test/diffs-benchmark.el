;;; diffs-benchmark.el --- Reproducible diffs.el benchmark -*- lexical-binding: t -*-

(require 'benchmark)
(require 'diffs)

(defvar diffs-benchmark--files
  (string-to-number (or (getenv "DIFFS_BENCH_FILES") "800")))

(defun diffs-benchmark--input ()
  "Build a representative multi-file Git diff."
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
    (goto-char (aref diffs--split-row-positions index))
    (when-let* ((window (get-buffer-window (current-buffer))))
      (diffs--split-materialize-window window))))

(let* ((text (diffs-benchmark--input))
       (buffer (generate-new-buffer " *diffs-benchmark*")))
  (unwind-protect
      (progn
        (with-current-buffer buffer
          (insert text)
          (diff-mode))
        (princ
         (format "Emacs %s; %d files; %d lines; %d bytes\n"
                 emacs-version diffs-benchmark--files
                 (with-current-buffer buffer
                   (count-lines (point-min) (point-max)))
                 (string-bytes text)))
        (diffs-benchmark--measure
         "scan" 30
         (lambda ()
           (with-current-buffer buffer
             (diffs--scan))))
        (with-current-buffer buffer
          (diffs-minor-mode 1))
        (switch-to-buffer buffer)
        (diffs-benchmark--measure
         "first split" 1
         (lambda ()
           (with-current-buffer buffer
             (switch-to-buffer buffer)
             (diffs--split-cache-clear)
             (diffs-toggle-split))
           (with-current-buffer (window-buffer)
             (diffs-split-quit))))
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
                       (aref diffs--split-row-positions index)))
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
