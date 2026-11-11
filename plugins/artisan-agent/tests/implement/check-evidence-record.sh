#!/usr/bin/env bash
# check-evidence-record.sh FILE
#
# Checks that FILE is an evidence record in the shape documented in
# references/evidence-record.md. Prints one line per problem and exits 1 if
# there are any; exits 0 silently when the record is well formed.
#
# Needs jq. Portable to bash 3.2 (macOS) and Linux.

set -euo pipefail

file=${1:?usage: check-evidence-record.sh FILE}
command -v jq >/dev/null 2>&1 || { echo "check-evidence-record.sh: jq is required" >&2; exit 2; }
[ -f "$file" ] || { echo "no such file: $file"; exit 1; }
jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "not a JSON object: $file"; exit 1; }

problems=$(jq -r '
  def need($obj; $keys; $where):
    $keys[] as $k | select($obj | has($k) | not) | "\($where): missing \($k)";
  def oneof($v; $allowed; $where):
    select(($allowed | index($v)) == null) | "\($where): \($v | tojson) is not one of \($allowed | join(", "))";

  need(.; ["ticket","status","branch","commit","base","acceptance","tests","unsure","decisions","review","findings"]; "record"),
  (select(has("status")) | oneof(.status; ["complete","blocked","failed"]; "status")),
  (select(has("acceptance")) | .acceptance |
    if type != "array" or length == 0 then "acceptance: must be a non-empty array"
    else to_entries[] | .key as $i | .value |
      (need(.; ["criterion","met","evidence"]; "acceptance[\($i)]")),
      (select(has("met") and (.met | type) != "boolean") | "acceptance[\($i)]: met must be true or false"),
      (select(has("evidence") and (.evidence | type) != "object") | "acceptance[\($i)]: evidence must be an object")
    end),
  (select(has("tests")) | .tests |
    if (.suite_passed | type) != "boolean" then "tests: suite_passed must be true or false" else empty end),
  (["unsure","findings","decisions"][] as $k | select(has($k) and (.[$k] | type) != "array") | "\($k): must be an array"),
  (select((.decisions | type) == "array") | .decisions | to_entries[] | .key as $i | .value |
    (need(.; ["job","choice","by","question","alternative","kind","criterion"]; "decisions[\($i)]")),
    (select(has("kind")) | oneof(.kind; ["product taste","engineering taste","engineering"]; "decisions[\($i)].kind")),
    (select(has("confidence")) | oneof(.confidence; ["firm","provisional"]; "decisions[\($i)].confidence")),
    (select(has("reach")) | oneof(.reach; ["ticket","area","everywhere"]; "decisions[\($i)].reach"))),
  (select(has("review")) | .review |
    (select((.ran | type) != "boolean") | "review: ran must be true or false"),
    (if (.remarks | type) != "array" then "review: remarks must be an array"
     else .remarks | to_entries[] | .key as $i | .value |
       (need(.; ["axis","severity","note","disposition"]; "review.remarks[\($i)]")),
       (select(has("axis")) | oneof(.axis; ["standards","spec"]; "review.remarks[\($i)].axis")),
       (select(has("severity")) | oneof(.severity; ["bug","violation","missing","scope","judgement"]; "review.remarks[\($i)].severity")),
       (select(has("disposition")) | oneof(.disposition; ["fixed","decision","not_acted"]; "review.remarks[\($i)].disposition")),
       (select(.disposition == "not_acted" and ((.why // "") == "")) | "review.remarks[\($i)]: not_acted needs why")
     end))
' "$file")

if [ -n "$problems" ]; then
  printf '%s\n' "$problems"
  exit 1
fi
