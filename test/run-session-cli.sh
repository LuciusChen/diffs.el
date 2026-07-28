#!/bin/sh

set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
server_name="diffs-cli-test-$$"
EMACS=${EMACS:-emacs}
EMACSCLIENT=${EMACSCLIENT:-emacsclient}
export EMACS EMACSCLIENT

cleanup() {
  "$EMACSCLIENT" -s "$server_name" \
    --eval '(kill-emacs)' >/dev/null 2>&1 || true
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
     (diffs-review-add-annotation
      "Human CLI test note."
      "This note exists only in the live owner buffer."))' >/dev/null

sessions=$("$repo_dir/bin/diffs" \
  --server "$server_name" session list --json)
case $sessions in
  *'"annotations":1'*) ;;
  *) echo "session list omitted the live human note" >&2; exit 1 ;;
esac

human=$("$repo_dir/bin/diffs" \
  --server "$server_name" session comment list \
  --repo "$repo_dir" --type user --json)
case $human in
  *'"summary":"Human CLI test note."'*) ;;
  *) echo "comment list could not read the live human note" >&2; exit 1 ;;
esac

applied=$(
  printf '%s\n' \
    '{"comments":[{"filePath":"live.el","oldLine":1,"summary":"Agent CLI test reply.","author":"cli-test"}]}' |
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
  *'"summary":"Agent CLI test reply."'*) ;;
  *) echo "comment list could not read the live Agent reply" >&2; exit 1 ;;
esac
