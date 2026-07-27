;;; diffs-tests.el --- Tests for diffs.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'diffs)
(require 'vc-git)

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

(defconst diffs-tests--rename
  (concat
   "diff --git a/old.el b/new.el\n"
   "similarity index 100%\n"
   "rename from old.el\n"
   "rename to new.el\n"))

(defmacro diffs-tests--with-diff (text &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (diff-mode)
     ,@body))

(ert-deftest diffs-scan-counts-files-and-lines ()
  (diffs-tests--with-diff diffs-tests--normal
    (diffs--scan)
    (should (equal diffs--stats '(1 2 1)))
    (should (equal (plist-get (car diffs--sections) :file) "foo.el"))
    (should (= (length (plist-get (car diffs--sections) :hunks)) 1))))

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

(ert-deftest diffs-fringe-bars-can-be-disabled ()
  (let ((diffs-line-numbers nil)
        (diffs-fringe-bars nil))
    (diffs-tests--with-diff diffs-tests--normal
      (diffs-minor-mode 1)
      (goto-char (point-min))
      (re-search-forward "^-(message")
      (should-not
       (get-text-property (line-beginning-position) 'line-prefix)))))

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
        (diffs-fullscreen nil))
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
         (wrapped (diffs--split-wrap-rows old new 4))
         (old-wrapped (car wrapped))
         (new-wrapped (cadr wrapped)))
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

(ert-deftest diffs-split-view-wraps-and-restores-window-layout ()
  (let ((buf (generate-new-buffer " *diffs split test*"))
        old-buf new-buf)
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
                               diff-indicator-removed)))))
          (with-current-buffer new-buf
            (goto-char (point-min))
            (re-search-forward "bbbb")
            (let ((prefix (get-text-property (line-beginning-position)
                                             'line-prefix)))
              (should (equal (get-text-property 0 'display prefix)
                             '(left-fringe diffs-fringe-bar
                               diff-indicator-added)))))
          (diffs-split-quit)
          (should (eq (window-buffer) buf))
          (should-not (buffer-live-p old-buf))
          (should-not (buffer-live-p new-buf)))
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
