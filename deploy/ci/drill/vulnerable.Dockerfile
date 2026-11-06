# Admission drill image with deliberate CRITICAL vulnerabilities: must never run or be released (refused by Kyverno).
# Deliberately old base (Alpine 3.12.0) pinned by digest for CRITICAL CVEs; no secrets added.
# Design notes: docs/reference/ci.md.
FROM alpine:3.12.0@sha256:185518070891758909c9f839cf4ca393ee977ac378609f700f60a771a2dfe321
# Not root, as a release: the user changes no package, so the CRITICAL findings stay what they are.
USER 65534:65534
# Exits at once if anything ever starts it.
ENTRYPOINT ["/bin/false"]
