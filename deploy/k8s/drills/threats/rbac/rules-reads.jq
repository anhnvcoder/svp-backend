# Of a SelfSubjectRulesReview (its JSON on stdin), the rules that let its subject read secrets or pods: get, list or
# watch (a watch streams every object, as a list does), in the core group or every group, on all objects or on named ones
# (resourceNames); one "RESOURCE[/NAMES]:VERBS" per rule and resource, sorted and joined by commas, "none" when there is
# none, "incomplete: ..." when the server could not list every rule (which proves nothing), "error: ..." when the JSON is
# no review status at all: an empty rule list read from it would pass as "none".
# Used by chainsaw-test.yaml beside it on the reviews of the ServiceAccounts and on the control's sample review.
.status as $s |
if ($s | type) != "object" or ($s.resourceRules | type) != "array" then "error: the response holds no rules review status"
elif ($s.incomplete // false) or (($s.evaluationError // "") != "") then "incomplete: \($s.evaluationError // "")"
else
  [$s.resourceRules[]? | select(any(.apiGroups[]?; . == "" or . == "*")) as $r |
    [$r.verbs[]? | select(. == "get" or . == "list" or . == "watch" or . == "*")] as $v |
    select($v | length > 0) |
    $r.resources[]? | select(. == "secrets" or . == "pods" or . == "*") |
    "\(.)\(if ($r.resourceNames // []) | length > 0 then "/" + ($r.resourceNames | join("|")) else "" end):\($v | join("|"))"]
  | unique | if length == 0 then "none" else join(",") end
end
