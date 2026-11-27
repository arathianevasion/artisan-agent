# shellcheck shell=bash
# Shared reading of `plan` issues (resolve-scope.sh, plan-done.sh). Sourced,
# never run. Needs gh and jq; the caller defines die(). Bash 3.2-safe.

# plan_members repo plan: the plan's tickets as a JSON array of
# {number, title, state} (state lower-case): its sub-issues, or, when it has
# none, the `- [ ] #<n>` task list in its body, each ticket read in turn. An
# empty array when it has neither. Dies when a read fails.
plan_members() {
  local repo=$1 n=$2 subs= members= body= t= m=
  subs=$(gh api "repos/$repo/issues/$n/sub_issues") || die "cannot read the sub-issues of plan #$n"
  members=$(jq -c '[.[] | {number, title, state: (.state | ascii_downcase)}]' <<<"$subs")
  if [ "$(jq length <<<"$members")" -eq 0 ]; then
    body=$(gh issue view "$n" -R "$repo" --json body --jq '.body // ""') || die "cannot read plan #$n"
    for t in $(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*[-*][[:space:]]*\[[ xX]\][[:space:]]*#\([0-9][0-9]*\).*/\1/p'); do
      m=$(gh issue view "$t" -R "$repo" --json number,title,state) || die "cannot read #$t (listed in plan #$n)"
      members=$(jq -c --argjson m "$m" '. + [$m | {number, title, state: (.state | ascii_downcase)}]' <<<"$members")
    done
  fi
  printf '%s\n' "$members"
}
