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
        (insert "-(message \"old value\")\n")
        (insert "+(message \"new value\")\n")))
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
         "cached split" 10
         (lambda ()
           (with-current-buffer buffer
             (switch-to-buffer buffer)
             (diffs-toggle-split))
           (with-current-buffer (window-buffer)
             (diffs-split-quit)))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

;;; diffs-benchmark.el ends here
