#!/bin/bash
# Leave a run request as a `plan` issue on the tracker (gh, in the current repo).
# Usage: queue-plan.sh <request text>
# An open `plan` issue with the same title is reused, so a retried request
# does not pile up duplicates. Prints the issue's URL or title.
set -euo pipefail
request=${1:-}
[ -n "$request" ] || request="(no details given)"
title="Plan: $(printf '%s' "$request" | head -n 1 | cut -c1-80)"
existing=$(gh issue list --state open --label plan --json title --jq '.[].title' 2>/dev/null || true)
if grep -qxF -- "$title" <<EOH
$existing
EOH
then
  printf '%s\n' "$title (already queued)"; exit 0
fi
body="A run was requested while another run held the run lock, so it waits here.

Request: $request

Left by the artisan-agent run-lock hook."
gh issue create --title "$title" --body "$body" --label plan 2>/dev/null \
  || gh issue create --title "$title" --body "$body"
