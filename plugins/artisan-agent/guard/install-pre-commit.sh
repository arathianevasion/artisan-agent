#!/bin/bash
# Install guard/pre-commit.sh as a git pre-commit hook in a repo (setup runs this).
# Usage: install-pre-commit.sh [repo-dir]   (default: the current directory)
# Idempotent: a rerun changes nothing. It never overwrites a pre-commit hook it
# did not install (exit 1 and says so); an existing one is left for the person to
# merge by hand. Installs into the repo's shared hooks dir, so every worktree
# sees it; the hook itself lets worktrees through.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
repo=${1:-.}
hooks=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) \
  || { echo "install-pre-commit.sh: not a git repository: $repo" >&2; exit 1; }
mkdir -p "$hooks"
dest="$hooks/pre-commit"
if [ -e "$dest" ] && ! grep -q 'artisan-agent-pre-commit' "$dest"; then
  echo "install-pre-commit.sh: $dest exists and is not ours; left alone. Call $HERE/pre-commit.sh from it." >&2
  exit 1
fi
# A copy that calls the plugin's script would break when the plugin moves or updates;
# a self-contained copy of the hook body keeps working with the plugin disabled.
{ printf '#!/bin/bash\n# artisan-agent-pre-commit: installed by artisan-agent setup; remove this file to uninstall.\n'; sed '1d' "$HERE/pre-commit.sh"; } > "$dest.tmp"
if [ -f "$dest" ] && cmp -s "$dest.tmp" "$dest"; then rm -f "$dest.tmp"; else mv -f "$dest.tmp" "$dest"; fi
chmod +x "$dest"
echo "installed $dest"
