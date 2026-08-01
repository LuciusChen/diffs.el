;;; diffs-review-compose.el --- Multiline review comment composer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Lucius Chen
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Lucius Chen
;; URL: https://github.com/LuciusChen/diffs.el
;; Version: 0.13.0
;; Keywords: vc, tools

;;; Commentary:

;; Editable multiline comment drafts and live-session image attachments for
;; diffs.el.  This module is loaded only when the interactive composer opens.

;;; Code:

(require 'cl-lib)
(require 'diffs)
(require 'image)
(require 'subr-x)
(require 'yank-media)

(defface diffs-review-attachment
  '((t :inherit shadow))
  "Face for an image attachment placeholder in a comment draft."
  :group 'diffs)

(defvar diffs--review-compose-media-attempted nil
  "Non-nil while a media yank has reached the image handler.")

(defvar-local diffs--review-compose-owner nil
  "Live unified review owner for this comment draft.")

(defvar-local diffs--review-compose-selection nil
  "Stable source selection captured for this comment draft.")

(defvar-local diffs--review-compose-attachments nil
  "Binary image attachments currently owned by this draft.")

(defvar-local diffs--review-compose-image-number 0
  "Last visible image number allocated in this draft.")

(defvar-local diffs--review-compose-window-configuration nil
  "Window configuration to restore after this draft closes.")

(defvar-local diffs--review-compose-finishing nil
  "Non-nil while this draft is being submitted or cancelled.")

(defvar-keymap diffs-review-compose-mode-map
  :doc "Keymap for editing a diffs review comment."
  :parent text-mode-map
  "C-c C-c" #'diffs-review-compose-submit
  "C-c C-k" #'diffs-review-compose-cancel
  "C-c C-d" #'diffs-review-compose-delete-attachment
  "<remap> <yank>" #'diffs-review-compose-yank)

(defun diffs--review-compose-autoselect-images (types)
  "Return image MIME TYPES in their existing clipboard order."
  (cl-remove-if-not
   (lambda (type)
     (string-prefix-p "image/" (symbol-name type)))
   types))

(defun diffs--review-compose-image-mime (mime type)
  "Return canonical MIME when MIME agrees with detected image TYPE."
  (let ((name (and (symbolp mime) (symbol-name mime))))
    (pcase type
      ('png (and (equal name "image/png") name))
      ('jpeg (and (member name '("image/jpeg" "image/jpg" "image/pjpeg"))
                  "image/jpeg"))
      ('gif (and (equal name "image/gif") name))
      ('webp (and (equal name "image/webp") name))
      ('tiff (and (member name '("image/tiff" "image/x-tiff"))
                  "image/tiff"))
      ('svg (and (equal name "image/svg+xml") name))
      ('heic (and (member name '("image/heic" "image/heif"
                                 "image/heic-sequence"
                                 "image/heif-sequence"))
                  name))
      ('pbm (and (member name '("image/x-portable-bitmap"
                                "image/x-portable-graymap"
                                "image/x-portable-pixmap"
                                "image/x-portable-anymap"))
                 name))
      ('xbm (and (equal name "image/x-xbitmap") name))
      ('xpm (and (equal name "image/x-xpixmap") name)))))

(defun diffs--review-compose-image-container-complete-p (data type)
  "Return non-nil when image DATA has a complete TYPE container."
  (let ((length (length data)))
    (pcase type
      ('png
       (and (>= length 33)
            (equal (substring data 8 16) "\0\0\0\rIHDR")
            (not (equal (substring data 16 20) (make-string 4 0)))
            (not (equal (substring data 20 24) (make-string 4 0)))
            (string-suffix-p "\0\0\0\0IEND\256B\140\202" data)))
      ('jpeg
       (and (>= length 10)
            (string-prefix-p "\377\330" data)
            (string-suffix-p "\377\331" data)
            (cl-loop for marker in '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6
                                     #xc7 #xc9 #xca #xcb #xcd #xce #xcf)
                     thereis
                     (string-match-p
                      (unibyte-string #xff marker) data))))
      ('gif
       (and (>= length 14)
            (> (+ (aref data 6) (aref data 7)) 0)
            (> (+ (aref data 8) (aref data 9)) 0)
            (= (aref data (1- length)) #x3b)))
      ('webp
       (and (>= length 20)
            (= (+ 8
                  (aref data 4)
                  (ash (aref data 5) 8)
                  (ash (aref data 6) 16)
                  (ash (aref data 7) 24))
               length)))
      ('tiff
       (and
        (>= length 10)
        (let* ((little (equal (substring data 0 2) "II"))
               (big (equal (substring data 0 2) "MM")))
          (and
           (or little big)
           (cl-labels
               ((u16 (offset)
                  (if little
                      (+ (aref data offset)
                         (ash (aref data (1+ offset)) 8))
                    (+ (ash (aref data offset) 8)
                       (aref data (1+ offset)))))
                (u32 (offset)
                  (if little
                      (+ (aref data offset)
                         (ash (aref data (+ offset 1)) 8)
                         (ash (aref data (+ offset 2)) 16)
                         (ash (aref data (+ offset 3)) 24))
                    (+ (ash (aref data offset) 24)
                       (ash (aref data (+ offset 1)) 16)
                       (ash (aref data (+ offset 2)) 8)
                       (aref data (+ offset 3))))))
             (let ((offset (u32 4)))
               (and (= (u16 2) 42)
                    (>= offset 8)
                    (<= (+ offset 2) length)
                    (<= (+ offset 6 (* 12 (u16 offset))) length))))))))
      ('svg
       (or (string-match-p
            "</[Ss][Vv][Gg][ \t\r\n]*>[ \t\r\n]*\\'" data)
           (string-match-p
            "<[Ss][Vv][Gg][^>]*?/[ \t\r\n]*>[ \t\r\n]*\\'" data)))
      ('heic
       (and (>= length 16)
            (let ((box-size
                   (+ (ash (aref data 0) 24)
                      (ash (aref data 1) 16)
                      (ash (aref data 2) 8)
                      (aref data 3))))
              (and (>= box-size 16) (<= box-size length)))))
      ((or 'pbm 'xbm 'xpm) (> length 16)))))

(defun diffs--review-compose-image-decodes-p (data type)
  "Return non-nil when image DATA of TYPE can be decoded."
  (and
   (diffs--review-compose-image-container-complete-p data type)
   (or
    (not (display-graphic-p))
    (condition-case nil
        (when-let* ((image (create-image data type t)))
          (unwind-protect
              (pcase-let ((`(,width . ,height)
                           (image-size image t)))
                (and (numberp width) (> width 0)
                     (numberp height) (> height 0)))
            (ignore-errors (image-flush image))))
      (error nil)))))

(defun diffs--review-compose-normalize-image-data (mime data)
  "Return validated (DATA TYPE MIME) for clipboard MIME and image DATA."
  (unless (and (stringp data) (> (string-bytes data) 0))
    (user-error "The clipboard image has no data"))
  (let* ((binary
          (if (multibyte-string-p data)
              (encode-coding-string data 'binary)
            data))
         (bytes (string-bytes binary))
         (type (image-type-from-data binary))
         (normalized-mime (and type
                               (diffs--review-compose-image-mime mime type))))
    (unless (and type (image-type-available-p type))
      (user-error "The clipboard does not contain a supported image"))
    (unless normalized-mime
      (user-error "Clipboard MIME %s does not match detected %s image data"
                  mime type))
    (when (> bytes diffs-review-image-max-bytes)
      (user-error "Image is %s; the per-image limit is %s"
                  (file-size-human-readable bytes)
                  (file-size-human-readable
                   diffs-review-image-max-bytes)))
    (unless (diffs--review-compose-image-decodes-p binary type)
      (user-error "The clipboard contains an incomplete or invalid image"))
    (list binary type normalized-mime)))

(defun diffs--review-compose-insert-attachment (attachment)
  "Insert the visible placeholder for ATTACHMENT at point."
  (insert
   (propertize
    (format "[%s]" (plist-get attachment :label))
    'diffs-review-attachment-id (plist-get attachment :id)
    'face 'diffs-review-attachment
    'rear-nonsticky '(diffs-review-attachment-id face))))

(defun diffs-review-compose-yank-image (mime data)
  "Attach clipboard image DATA of MIME type MIME to this draft."
  (setq diffs--review-compose-media-attempted t)
  (unless (derived-mode-p 'diffs-review-compose-mode)
    (user-error "Image comments require a diffs comment draft"))
  (unless (and (buffer-live-p diffs--review-compose-owner)
               (symbolp mime)
               (string-prefix-p "image/" (symbol-name mime)))
    (user-error "The target diffs review is no longer live"))
  (pcase-let* ((`(,binary ,_type ,normalized-mime)
                (diffs--review-compose-normalize-image-data mime data))
               (bytes (string-bytes binary))
               (owner-bytes
                (diffs--review-attachment-total-bytes
                 (buffer-local-value
                  'diffs--review-attachments diffs--review-compose-owner)))
               (draft-bytes
                (diffs--review-attachment-total-bytes
                 diffs--review-compose-attachments)))
    (when (> (+ owner-bytes draft-bytes bytes)
             diffs-review-image-total-max-bytes)
      (user-error "Review images would exceed the %s session limit"
                  (file-size-human-readable
                   diffs-review-image-total-max-bytes)))
    (cl-incf diffs--review-compose-image-number)
    (let ((attachment
           (list
            :id (diffs--review-new-attachment-id)
            :label (format "Image #%d"
                           diffs--review-compose-image-number)
            :mime normalized-mime
            :bytes bytes
            :sha256 (secure-hash 'sha256 binary)
            :data binary)))
      (setq diffs--review-compose-attachments
            (append diffs--review-compose-attachments
                    (list attachment)))
      (diffs--review-compose-insert-attachment attachment)
      (message "Attached %s (%s)"
               (plist-get attachment :label)
               (file-size-human-readable bytes))
      attachment)))

(define-derived-mode diffs-review-compose-mode text-mode "Diffs-Comment"
  "Major mode for composing one multiline diffs review comment.
Use `diffs-review-compose-submit' to submit the draft or
`diffs-review-compose-cancel' to discard it."
  (setq-local require-final-newline nil)
  (setq-local yank-media-autoselect-function
              #'diffs--review-compose-autoselect-images)
  (yank-media-handler "^image/" #'diffs-review-compose-yank-image)
  (add-hook 'kill-buffer-hook #'diffs--review-compose-killed nil t))

(defun diffs--review-compose-existing-buffer (owner)
  "Return the live comment draft for OWNER, if any."
  (cl-find-if
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (eq (buffer-local-value
               'diffs--review-compose-owner buffer)
              owner)))
   (buffer-list)))

(defun diffs--review-compose-display (buffer)
  "Display BUFFER in the comment side window and select it."
  (let ((window
         (display-buffer-in-side-window
          buffer
          '((side . bottom)
            (slot . 0)
            (window-height . 0.3)))))
    (select-window window)
    window))

(defun diffs--review-compose-owner-killed ()
  "Discard the comment draft owned by the buffer being killed."
  (when-let* ((draft
               (diffs--review-compose-existing-buffer
                (current-buffer))))
    (with-current-buffer draft
      (setq diffs--review-compose-finishing t)
      (set-buffer-modified-p nil)
      (kill-buffer draft))))

(defun diffs--review-compose-header (selection)
  "Return the composer header for stable SELECTION."
  (let ((start (plist-get selection :start))
        (end (plist-get selection :end)))
    (format
     " Comment · %s %s%d%s   C-c C-c submit · C-c C-k cancel"
     (diffs--short-display-path (plist-get selection :file) 48)
     (if (eq (plist-get selection :side) 'old) "L" "R")
     start
     (if (= start end) "" (format "–%d" end)))))

(defun diffs-review-compose ()
  "Open the single editable comment draft for the current review.
The current stable selection is preferred; otherwise the changed line at
point becomes the target.  An existing draft for the same review is
shown without replacing its text or target."
  (interactive)
  (let* ((owner (diffs--review-owner-buffer))
         (selection
          (or (and owner
                   (buffer-local-value 'diffs--review-selection owner))
              (diffs--review-range-at-point))))
    (unless (buffer-live-p owner)
      (user-error "Not in a diffs review view"))
    (if-let* ((existing
               (diffs--review-compose-existing-buffer owner)))
        (progn
          (diffs--review-compose-display existing)
          existing)
      (diffs--review-ensure-session-state owner)
      (let* ((configuration (current-window-configuration))
             (session
              (buffer-local-value 'diffs--review-session-id owner))
             (buffer
              (generate-new-buffer
               (format "*diffs comment:%s*"
                       (substring session
                                  (length "diffs-session:"))))))
        (with-current-buffer buffer
          (setq default-directory
                (buffer-local-value 'default-directory owner))
          (diffs-review-compose-mode)
          (setq diffs--review-compose-owner owner
                diffs--review-compose-selection (copy-tree selection)
                diffs--review-compose-window-configuration configuration
                header-line-format
                (diffs--review-compose-header selection))
          (set-buffer-modified-p nil))
        (with-current-buffer owner
          (add-hook 'kill-buffer-hook
                    #'diffs--review-compose-owner-killed nil t))
        (diffs--review-compose-display buffer)
        (goto-char (point-min))
        buffer))))

(defun diffs--review-compose-yank-text ()
  "Yank text while preserving the ordinary `yank-pop' protocol."
  (setq this-command 'yank)
  (yank))

(defun diffs-review-compose-yank (&optional argument)
  "Yank an image when available, otherwise yank ordinary text.
With prefix ARGUMENT, bypass media detection and perform a normal text
yank."
  (interactive "*P")
  (if argument
      (diffs--review-compose-yank-text)
    (let ((diffs--review-compose-media-attempted nil))
      (condition-case error-data
          (yank-media)
        (user-error
         (when diffs--review-compose-media-attempted
           (signal (car error-data) (cdr error-data)))))
      (unless diffs--review-compose-media-attempted
        (diffs--review-compose-yank-text)))))

(defun diffs--review-compose-referenced-attachments ()
  "Return draft attachments referenced by visible placeholders."
  (let ((position (point-min)) ids)
    (while (< position (point-max))
      (when-let* ((id
                   (get-text-property
                    position 'diffs-review-attachment-id)))
        (unless (member id ids)
          (push id ids)))
      (setq position
            (next-single-property-change
             position 'diffs-review-attachment-id nil (point-max))))
    (mapcar
     (lambda (id)
       (or (cl-find id diffs--review-compose-attachments
                    :key (lambda (attachment)
                           (plist-get attachment :id))
                    :test #'equal)
           (user-error "Image placeholder %s has no live attachment" id)))
     (nreverse ids))))

(defun diffs-review-compose-delete-attachment ()
  "Delete the image attachment placeholder at or adjacent to point."
  (interactive)
  (let* ((position
          (if (get-text-property
               (point) 'diffs-review-attachment-id)
              (point)
            (max (point-min) (1- (point)))))
         (id (get-text-property
              position 'diffs-review-attachment-id)))
    (unless id
      (user-error "Point is not on an image attachment"))
    (let ((begin position)
          (end (1+ position)))
      (while (and (> begin (point-min))
                  (equal id
                         (get-text-property
                          (1- begin) 'diffs-review-attachment-id)))
        (cl-decf begin))
      (while (and (< end (point-max))
                  (equal id
                         (get-text-property
                          end 'diffs-review-attachment-id)))
        (cl-incf end))
      (delete-region begin end))
    (setq diffs--review-compose-attachments
          (cl-remove id diffs--review-compose-attachments
                     :key (lambda (attachment)
                            (plist-get attachment :id))
                     :test #'equal))
    (message "Removed image attachment")))

(defun diffs--review-compose-comment-text ()
  "Return (SUMMARY . RATIONALE) parsed from the current draft."
  (let ((text
         (string-trim
          (buffer-substring-no-properties (point-min) (point-max)))))
    (when (string-empty-p text)
      (user-error "A review comment requires content"))
    (if (string-match "\n[ \t]*\n" text)
        (cons
         (string-trim-right (substring text 0 (match-beginning 0)))
         (let ((rationale
                (string-trim (substring text (match-end 0)))))
           (unless (string-empty-p rationale) rationale)))
      (cons text nil))))

(defun diffs--review-compose-restore-window (configuration)
  "Restore window CONFIGURATION when it is still usable."
  (when (window-configuration-p configuration)
    (set-window-configuration configuration)))

(defun diffs--review-compose-finish ()
  "Kill the current draft and restore its original windows."
  (let ((configuration diffs--review-compose-window-configuration)
        (owner diffs--review-compose-owner)
        (buffer (current-buffer)))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (remove-hook 'kill-buffer-hook
                     #'diffs--review-compose-owner-killed t)))
    (setq diffs--review-compose-finishing t)
    (set-buffer-modified-p nil)
    (kill-buffer buffer)
    (diffs--review-compose-restore-window configuration)))

(defun diffs-review-compose-submit ()
  "Submit this comment draft to its captured live review location."
  (interactive)
  (unless (derived-mode-p 'diffs-review-compose-mode)
    (user-error "Not in a diffs comment draft"))
  (pcase-let* ((`(,summary . ,rationale)
                (diffs--review-compose-comment-text))
               (attachments
                (diffs--review-compose-referenced-attachments)))
    (diffs--review-store-annotation
     diffs--review-compose-owner
     diffs--review-compose-selection
     summary rationale
     (or user-full-name user-login-name)
     "user" attachments)
    (diffs--review-compose-finish)))

(defun diffs-review-compose-cancel ()
  "Discard this comment draft and restore its original windows."
  (interactive)
  (unless (derived-mode-p 'diffs-review-compose-mode)
    (user-error "Not in a diffs comment draft"))
  (diffs--review-compose-finish)
  (message "Review comment cancelled"))

(defun diffs--review-compose-killed ()
  "Restore windows when a draft is killed outside its own commands."
  (when (buffer-live-p diffs--review-compose-owner)
    (with-current-buffer diffs--review-compose-owner
      (remove-hook 'kill-buffer-hook
                   #'diffs--review-compose-owner-killed t)))
  (unless diffs--review-compose-finishing
    (diffs--review-compose-restore-window
     diffs--review-compose-window-configuration)))

(provide 'diffs-review-compose)
;;; diffs-review-compose.el ends here
