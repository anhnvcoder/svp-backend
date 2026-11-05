# The rules of FF-3/FF-4 for every container (init and ephemeral ones too) of the pods in the input list (kubectl get pods
# -o json): one line "POD/CONTAINER ok|<broken rules> requests=... limits=...". A container's runAsNonRoot and seccomp
# profile override the pod's, so the pod's apply only where the container's are unset (null, never false). $tokens
# (--argjson) names the Secrets of type kubernetes.io/service-account-token: even with automountServiceAccountToken false,
# a token can reach a container at any path through a volume of such a Secret, of a projected serviceAccountToken or of
# a projected volume with such a Secret as a source, and through env or envFrom naming such a Secret.
# Used by chainsaw-test.yaml beside it on the pods of svp and on the two control pods, so the controls test this program.
def token_secret: . as $n | $n != null and any($tokens[]; . == $n);
.items[] | .metadata.name as $pod | .spec as $s | ($s.securityContext // {}) as $ps |
[$s.volumes[]? | select(any(.projected.sources[]?; .serviceAccountToken != null or (.secret.name | token_secret))
  or (.secret.secretName | token_secret)) | .name] as $tokenvols |
(($s.initContainers // []) + ($s.containers // []) + ($s.ephemeralContainers // []))[] |
. as $c | ($c.securityContext // {}) as $cs |
[
  (if ($c.resources.requests.cpu and $c.resources.requests.memory and $c.resources.limits.cpu and $c.resources.limits.memory) then empty else "resources" end),
  (if (if $cs.runAsNonRoot == null then $ps.runAsNonRoot else $cs.runAsNonRoot end) == true then empty else "runAsNonRoot" end),
  (if $cs.readOnlyRootFilesystem == true then empty else "readOnlyRootFilesystem" end),
  (if (($cs.capabilities.drop // []) | index("ALL")) then empty else "drop-ALL" end),
  (if (($cs.capabilities.add // []) | length) == 0 then empty else "capabilities-added" end),
  (if $cs.allowPrivilegeEscalation == false then empty else "allowPrivilegeEscalation" end),
  (if ($cs.seccompProfile.type // $ps.seccompProfile.type) == "RuntimeDefault" then empty else "seccomp" end),
  (if $cs.privileged == true then "privileged" else empty end),
  (if $s.automountServiceAccountToken == false then empty else "automountServiceAccountToken" end),
  (if ([$c.volumeMounts[]? | select((.mountPath | startswith("/var/run/secrets/kubernetes.io")) or (.name as $v | any($tokenvols[]; . == $v)))] | length) == 0 then empty else "token-mounted" end),
  (if ([($c.env[]? | .valueFrom.secretKeyRef.name), ($c.envFrom[]? | .secretRef.name)] | any(.[]; token_secret)) then "token-env" else empty end),
  (if ($s.hostNetwork or $s.hostPID or $s.hostIPC) then "host-namespaces" else empty end),
  (if ([$s.volumes[]? | select(.hostPath)] | length) == 0 then empty else "hostPath" end)
] as $bad |
"\($pod)/\($c.name) \(if ($bad | length) == 0 then "ok" else ($bad | join(",")) end) requests=\($c.resources.requests.cpu)/\($c.resources.requests.memory) limits=\($c.resources.limits.cpu)/\($c.resources.limits.memory)"
