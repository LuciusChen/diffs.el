#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
server_name="diffs-cli-test-$$"
EMACS=${EMACS:-emacs}
EMACSCLIENT=${EMACSCLIENT:-emacsclient}
export EMACS EMACSCLIENT
attachment_dir=

cleanup() {
  "$EMACSCLIENT" -s "$server_name" \
    --eval '(kill-emacs)' >/dev/null 2>&1 || true
  if [ -n "$attachment_dir" ]; then
    rm -f "$attachment_dir/image.png"
    rmdir "$attachment_dir" 2>/dev/null || true
  fi
}

trap cleanup EXIT HUP INT TERM

"$EMACS" -Q --daemon="$server_name" \
  -L "$repo_dir" -l "$repo_dir/diffs.el" >/dev/null

"$EMACSCLIENT" -s "$server_name" --eval \
  '(with-current-buffer (get-buffer-create "*diffs-cli-test*")
     (let ((inhibit-read-only t))
       (erase-buffer)
       (insert "diff --git a/live.el b/live.el\n--- a/live.el\n+++ b/live.el\n@@ -1 +1 @@\n-old\n+new\n"))
     (setq default-directory "'"$repo_dir"'/")
     (diff-mode)
     (diffs-minor-mode 1)
     (goto-char (point-min))
     (search-forward "+new")
     (beginning-of-line)
     (let* ((data
             (base64-decode-string
              "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            (attachment
             (list :id "diffs-attachment:cli-test"
                   :label "Image #1"
                   :mime "image/png"
                   :bytes (string-bytes data)
                   :sha256 (secure-hash (quote sha256) data)
                   :data data)))
       (diffs--review-store-annotation
        (current-buffer) (diffs--review-range-at-point)
        "中文 CLI 测试评论 😺"
        "仅存在于 live owner buffer 中。\n\n[Image #1]"
        "cli-test" "user" (list attachment))))' >/dev/null

sessions=$("$repo_dir/bin/diffs" \
  --server "$server_name" session list --json)
case $sessions in
  *'"annotations":1'*) ;;
  *) echo "session list omitted the live human note" >&2; exit 1 ;;
esac
case $sessions in
  *'"attachments":1'*) ;;
  *) echo "session list omitted the live image attachment" >&2; exit 1 ;;
esac

human=$("$repo_dir/bin/diffs" \
  --server "$server_name" session comment list \
  --repo "$repo_dir" --type user --json)
case $human in
  *'"summary":"中文 CLI 测试评论 😺"'*) ;;
  *) echo "comment list corrupted the live UTF-8 human note" >&2; exit 1 ;;
esac
case $human in
  *'"id":"diffs-attachment:cli-test"'*) ;;
  *) echo "comment list omitted attachment metadata" >&2; exit 1 ;;
esac
case $human in
  *'"data":'*) echo "comment list embedded binary attachment data" >&2; exit 1 ;;
  *) ;;
esac

attachment_dir=$(mktemp -d "${TMPDIR:-/tmp}/diffs-cli-attachment.XXXXXX")
attachment_file=$attachment_dir/image.png
"$repo_dir/bin/diffs" --server "$server_name" \
  session attachment get --repo "$repo_dir" \
  diffs-attachment:cli-test --output "$attachment_file" >/dev/null
if [ "$(cksum < "$attachment_file")" != "1749131364 68" ]; then
  echo "attachment get wrote the wrong image bytes" >&2
  exit 1
fi
if "$repo_dir/bin/diffs" --server "$server_name" \
  session attachment get --repo "$repo_dir" \
  diffs-attachment:cli-test --output "$attachment_file" >/dev/null 2>&1; then
  echo "attachment get overwrote an existing file" >&2
  exit 1
fi

applied=$(
  printf '%s\n' \
    '{"comments":[{"filePath":"live.el","oldLine":1,"summary":"Agent 中文回复 🧪","author":"cli-test"}]}' |
    "$repo_dir/bin/diffs" --server "$server_name" \
      session comment apply --repo "$repo_dir" --stdin --json
)
case $applied in
  *'"applied":['*) ;;
  *) echo "comment apply did not report the live Agent note" >&2; exit 1 ;;
esac

agent=$("$repo_dir/bin/diffs" \
  --server "$server_name" session comment list \
  --repo "$repo_dir" --type agent --json)
case $agent in
  *'"summary":"Agent 中文回复 🧪"'*) ;;
  *) echo "comment list corrupted the live UTF-8 Agent reply" >&2; exit 1 ;;
esac
