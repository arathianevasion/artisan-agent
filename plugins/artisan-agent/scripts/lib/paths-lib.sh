# shellcheck shell=bash
# The one definition of how a ticket's expected_files entries are matched
# (skills/implement-plan/references/parallel-waves.md, "Expected files"):
# paths from the repo root; an entry ending in "/" covers everything under it;
# any other entry is a file. Sourced by wave-width.sh (wave width) and
# gate-plan.sh (areas, #77), so a path means the same to both. Prepend
# "$PATHS_JQ" to a jq filter.
#   path_under(a; b): a equals b, or b is a directory ("/"-ended) holding a
PATHS_JQ='
  def path_under($a; $b): $a == $b or ($b | endswith("/")) and ($a | startswith($b));
'
