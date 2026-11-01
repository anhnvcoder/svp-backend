#!/usr/bin/env bash
# scan-gate.sh: the gate between scanning an image and pushing or attesting it. The verdict is the scanners' own, from
# their flags; this script picks the flags, reads the exit codes and prints one line per scan for the job summary.
#
#   scan-gate.sh [--allow-critical] LABEL REPORT
#     REPORT is the JSON of `trivy image --scanners vuln,secret` with every severity and .trivyignore.yaml (the record
#     the vuln attestation and the SARIF are made from); LABEL names the image in the output (gateway linux/amd64).
#     trivy convert reads it twice: the vulnerabilities with --severity CRITICAL --ignorefile .trivyignore.yaml
#     --exit-code, the secrets with --exit-code and no --severity (a severity filter would hide a HIGH secret). Each
#     pass gets only its own part of the report, so neither counts the other's findings.
#   scan-gate.sh [--allow-critical] --grype LABEL DIR
#     Runs grype (grype_sbom of common.sh) on DIR/sbom.spdx.json, the SBOM syft wrote of the image, with
#     --fail-on critical and .grype.yaml, and writes DIR/grype.json and DIR/grype.sarif.raw. syft finds what was
#     installed without a package manager, such as the node binary of the web image, which trivy does not list.
#   scan-gate.sh --check-ignorefile
#     Checks the rules of .trivyignore.yaml and .grype.yaml (below), with no image and no report, and those of
#     deploy/ci/trivy-config-ignore.yaml, the misconfigurations make trivy-config leaves out. Job config of ci.yml runs it
#     on every pull request and push: a pull request that changes nothing but an ignore file builds no image.
#
# Blocks (exit 1) on:
#   - any secret, whatever its severity: a public package and its signature cannot be taken back, so a secret pushed
#     once is leaked for good. There is no way around it: .trivyignore.yaml may hold only vulnerabilities, and no
#     --skip-files, --skip-dirs or --secret-config is ever passed to trivy.
#   - any CRITICAL vulnerability left after the exceptions, fixed upstream or not, in trivy's report or grype's.
#     --allow-critical lets CRITICAL through (only for the drill image drill-vulnerable and for the daily rescan, which
#     records the real result); it never lets a secret through.
#   - an ignore file that breaks its rules (below; an expired entry aside, which only job config fails on).
# HIGH and below are only reported: counts in the job summary, details in the SARIF. Exit 2: the scan could not be
# read or run (REPORT is not a trivy image report, trivy or grype failed, the grype DB could not be fetched).
#
# Prints counts and, for findings that block, trivy's table of the CRITICAL vulnerabilities, and rule, file and line of
# each secret: never the matched text (trivy masks secrets in its findings anyway; the raw report is never printed).
#
# The exceptions are those of the tree being scanned (code_root of common.sh): this checkout's, or those of the checkout
# of another repository named by SVP_CODE_ROOT (its CI runs this script from a pinned checkout of this one), where both
# files must exist: a tree without them is the wrong tree, not one without exceptions.
set -euo pipefail

# shellcheck source=deploy/ci/common.sh
. "$(dirname "$0")/common.sh"
require_code_files .trivyignore.yaml .grype.yaml
config_ignore=$ci_dir/trivy-config-ignore.yaml

allow_critical=false
mode=trivy
if [ "${1:-}" = --check-ignorefile ]; then
  [ $# -eq 1 ] || fail "usage: scan-gate.sh --check-ignorefile"
  mode=check
else
  if [ "${1:-}" = --allow-critical ]; then
    allow_critical=true
    shift
  fi
  if [ "${1:-}" = --grype ]; then
    mode=grype
    shift
  fi
  [ $# -eq 2 ] || fail "usage: scan-gate.sh [--allow-critical] [--grype] LABEL REPORT|DIR | --check-ignorefile"
fi
label=${1:-} input=${2:-}
tmp=$(mktemp -d) || fail "create a temporary directory"
trap 'rm -rf "$tmp"' EXIT

# statement_awk: the awk function both checks below read a statement line with (sq is the single quote, passed with -v).
# read_statement(LINE) sets statement to the reason the line gives, as trivy's YAML parser reads it: plain text up to
# a " #" comment, or the text in one pair of quotes. A value YAML reads as empty (nothing, null, ~, "" or '', blanks,
# a lone comment) leaves statement empty, so the entry fails as having no reason. It returns 0 for a value it does not
# read, refused rather than guessed: an escape in quotes, or plain text that does not start with a letter or digit (a
# tag, an alias, a flow or block value).
statement_awk='
  function read_statement(line,   v, q, end, rest) {
    statement = ""
    v = line; sub(/^ *statement:[ ]*/, "", v)
    q = substr(v, 1, 1)
    if (q == "\"" || q == sq) {
      end = index(substr(v, 2), q)
      if (!end) return 0
      rest = substr(v, end + 2); v = substr(v, 2, end - 1)
      # A backslash escapes in double quotes, two single quotes make one in single quotes: neither is read here.
      if ((q == "\"" && index(v, "\\")) || (rest !~ /^[ ]*$/ && rest !~ /^[ ]+#/)) return 0
    } else {
      if (v ~ /^#/) v = ""
      sub(/[ \t]+#.*$/, "", v)
      if (v ~ /^(null|Null|NULL|~)[ ]*$/) v = ""
      else if (v != "" && v !~ /^[A-Za-z0-9]/) return 0
    }
    if (v ~ /[^ \t]/) statement = v
    return 1
  }'


# check_ignorefile [--live]: .trivyignore.yaml, when present, may only list vulnerabilities (the format also has secrets,
# misconfigurations and licenses sections, and trivy would apply them), each with an id, a statement giving the reason
# (plain text or in quotes, on its line), an expired_at (yyyy-mm-dd) at most 30 days after today (UTC), so no exception
# lives longer than 30 days without another reviewed change, and the package versions it covers as purls with a version
# (pkg:<type>/<name>@<version>): the same id in another package or version is still reported. With --live (job config),
# an entry trivy no longer applies (from its expired_at day on) breaks the rules too: grype reads no date, so the rule
# .grype.yaml has for it would go on covering the match until the entry is renewed or removed. Read line by line in the
# shape below; anything else is refused rather than guessed:
#   vulnerabilities:
#     - id: CVE-2026-12345
#       statement: why this cannot be fixed by a newer base yet
#       expired_at: 2026-11-19
#       purls:
#         - pkg:apk/alpine/ffmpeg@8.0.1-r0
# A tree with nothing to except writes `vulnerabilities: []`. Writes the entries to $tmp/entries for check_grypeignore,
# one line per purl: id, expired_at, purl (tab-separated).
check_ignorefile() {
  : >"$tmp/entries"
  [ -f "$trivyignore" ] || return 0
  local limit today=
  limit=$(date -u -d '+30 days' +%F 2>/dev/null || date -u -v+30d +%F)
  [ "${1:-}" != --live ] || today=$(date -u +%F)
  awk -v limit="$limit" -v today="$today" -v entries="$tmp/entries" -v sq="'" "$statement_awk"'
    function bad_at(line, msg) { printf "FAIL  .trivyignore.yaml:%d: %s\n", line, msg; failed = 1 }
    function bad(msg) { bad_at(NR, msg) }
    function close_item() {
      if (!item) return
      if (statement == "") bad_at(start, "entry " id " has no statement (the reason it is ignored)")
      if (!purls) bad_at(start, "entry " id " has no purls (the package versions it covers)")
      if (expired !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        bad_at(start, "entry " id " has no expired_at yyyy-mm-dd")
      else if (expired > limit)
        bad_at(start, "entry " id " expires " expired ", more than 30 days from today (" limit ")")
      else if (today != "" && expired <= today)
        bad_at(start, "entry " id " expired on " expired ": renew it with a reason, or remove it (and its rule in .grype.yaml)")
    }
    /^[ ]*(#.*)?$/ { next }
    /^vulnerabilities:[ ]*(\[\][ ]*)?$/ { if (root++) bad("vulnerabilities: twice"); empty = ($0 ~ /\[\]/); next }
    /^[^ ]/ { bad("only vulnerabilities may be ignored, never secrets or anything else: " $0); next }
    !root || empty { bad("entry outside vulnerabilities:"); next }
    /^  - id:[ ]*[^ ]/ {
      close_item()
      item = 1; start = NR; statement = ""; expired = ""; list = 0; purls = 0
      id = $0; sub(/^  - id:[ ]*/, "", id)
      next
    }
    !item { bad("unexpected line before the first - id: " $0); next }
    /^    statement:/ {
      list = 0
      if (!read_statement($0)) bad("statement is neither plain text nor text in quotes: " $0)
      next
    }
    /^    expired_at:/ {
      list = 0; expired = $0; sub(/^    expired_at:[ ]*/, "", expired); gsub(/"/, "", expired); next
    }
    /^    purls:[ ]*$/ { list = 1; next }
    /^      - [^ ]/ {
      if (!list) { bad("list item outside purls:"); next }
      purl = $0; sub(/^      - /, "", purl)
      if (purl !~ /^pkg:[a-z]+\/[^ @]+@[^ @]+$/) bad("purl " purl " is not pkg:<type>/<name>@<version>")
      else printf "%s\t%s\t%s\n", id, expired, purl > entries
      purls++
      next
    }
    { bad("unexpected line (only id, statement, expired_at, purls): " $0) }
    END { close_item(); exit failed }' "$trivyignore"
}

# check_grypeignore [--live]: .grype.yaml, when present, holds only the root key ignore, and each of its rules exactly
# vulnerability, include-aliases: true, package.name and package.version, in the shape below. grype reads the whole file
# (-c), and several keys it knows leave a CRITICAL out with no entry and no date: only-fixed, only-notfixed and
# ignore-wontfix at the root, vex-documents, a rule naming only fix-state or package.type, or one without package; a key
# it does not know it ignores without a word. So anything but this shape is refused. include-aliases makes the rule
# cover the match grype reports under a related id (a GHSA for the CVE the rule names). Each rule must be exactly one
# entry of .trivyignore.yaml (run check_ignorefile first): the same id, and a purl of it whose name and version are the
# rule's package, so grype never has an exception trivy does not; with --live, an entry still in force. The name of a
# purl is the one grype gives its package: the last segment for a package of a distribution (apk, deb, rpm), whose
# namespace is the distribution (pkg:apk/alpine/glib is glib), the namespace with it for any other type
# (pkg:npm/%40scope/foo is @scope/foo, pkg:golang/golang.org/x/net is golang.org/x/net), so a rule for foo or net never
# covers another package of that name. A value YAML reads as anything but text is refused in vulnerability, name and
# version, plain null, true, 1.10, 017, 0x1F, 1e5 or 2026-1-2: grype drops a null from the rule, which then covers every
# vulnerability, package or version, reads a number as other text (1.10 as 1.1) and refuses to start on a date; in quotes
# such a value is text. grype reads package.name as a regex anchored at both ends when it holds one of *+?[](){}|^$\ (mini.* covers
# minimist), so the name must be the purl's name with each of .*+?[](){}|^$\ escaped by \ (socket\.io-parser,
# libstdc\+\+, golang\.org/x/net): that name covers its one package whether grype reads it as a regex or as text; a name
# written any other way is refused, so no entry and rule pair (pkg:npm/.*@1.2.5 and .*) covers every package at a
# version.
#   ignore:
#     - vulnerability: CVE-2026-12345
#       include-aliases: true
#       package:
#         name: ffmpeg
#         version: 8.0.1-r0
# A tree with nothing to except writes `ignore: []`. A value is plain text or in quotes (a name such as @scope/pkg must
# be quoted in YAML; an escaped name is plain or in single quotes, as YAML reads \ as an escape in double quotes).
check_grypeignore() {
  [ -f "$grypeignore" ] || return 0
  local today=
  [ "${1:-}" != --live ] || today=$(date -u +%F)
  awk -v today="$today" -v entries="$tmp/entries" -v sq="'" '
    function bad_at(line, msg) { printf "FAIL  .grype.yaml:%d: %s\n", line, msg; failed = 1 }
    function bad(msg) { bad_at(FNR, msg) }
    # text(line): the text after "key:", out of one pair of quotes (no escape), with a " #" comment cut; quoted is the
    # quote it was in, empty when plain.
    function text(line,   v, q) {
      v = line; sub(/^[ -]*[a-z-]+:[ ]*/, "", v); sub(/[ ]+#.*$/, "", v); sub(/[ ]+$/, "", v)
      q = substr(v, 1, 1); quoted = ""
      if ((q == "\"" || q == sq) && length(v) > 1 && substr(v, length(v)) == q) { quoted = q; v = substr(v, 2, length(v) - 2) }
      return v
    }
    # value(line): text(line) when it is plain (letters, digits, @._:+~/-, starting with a letter or digit unless it
    # was quoted); empty when it is anything else.
    function value(line,   v) {
      v = text(line)
      if (quoted == "" && v !~ /^[A-Za-z0-9]/) return ""
      return v ~ /^[A-Za-z0-9@._:+~\/-]+$/ ? v : ""
    }
    # typed(key, v): 1, after a FAIL naming key, when v, as text() just read it, is plain and YAML reads it as a null,
    # a bool, a number (_ dropped, 017 octal, 0x1F, 1e5) or a date rather than as text.
    function typed(key, v,   n) {
      if (quoted != "") return 0
      n = v; gsub(/_/, "", n)
      if (v !~ /^(null|Null|NULL|true|True|TRUE|false|False|FALSE)$/ &&
        n !~ /^([0-9]+(\.[0-9]*)?([eE][-+]?[0-9]+)?|0[xX][0-9A-Fa-f]+|0[oO][0-7]+|0[bB][01]+)$/ &&
        v !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?([Tt].*)?$/) return 0
      bad(key " " v " is a null, a bool, a number or a date to YAML, not text (grype would drop it from the rule or read" \
        " another value): put it in quotes")
      return 1
    }
    # escape(s): s with each character a regex reads as more than itself escaped by a backslash (index, not a bracket
    # expression: awk implementations disagree on escapes inside one).
    function escape(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out (index(".*+?[](){}|^$\\", c) ? "\\" : "") c }
      return out
    }
    # unescape(s): s with the backslash before each character dropped; escape(unescape(s)) == s only when s escapes
    # every metacharacter and nothing else.
    function unescape(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) c = substr(s, ++i, 1)
        out = out c
      }
      return out
    }
    # decode(p): p with its %-escapes decoded (%40 is the @ of an npm scope).
    function decode(p,   out, i, h) {
      out = ""
      while ((i = index(p, "%")) > 0) {
        h = tolower(substr(p, i + 1, 2))
        out = out substr(p, 1, i - 1) sprintf("%c", (index("0123456789abcdef", substr(h, 1, 1)) - 1) * 16 \
          + index("0123456789abcdef", substr(h, 2, 1)) - 1)
        p = substr(p, i + 3)
      }
      return out p
    }
    function close_rule(   i, n) {
      if (!rule) return
      if (vuln == "") bad_at(start, "rule without a plain vulnerability id")
      if (aliases != 1) bad_at(start, "rule " vuln " needs include-aliases: true once")
      if (refused) return
      if (pkg != 1 || names != 1 || versions != 1 || name == "" || version == "")
        bad_at(start, "rule " vuln " needs one package with a plain name and version")
      else if (vuln != "") {
        n = 0
        for (i = 1; i <= count; i++)
          if (ids[i] == vuln && (today == "" || dates[i] > today) && pnames[i] == name && pversions[i] == version) n++
        if (n != 1)
          bad_at(start, "rule " vuln " " name "@" version " is " n " entries of .trivyignore.yaml" \
            (today == "" ? "" : " in force") ", not exactly one (same id, a purl of that name and version)")
      }
    }
    # An entry: its purl without qualifiers or subpath split into the name grype gives the package (above) and the
    # version, both decoded.
    FILENAME == entries {
      split($0, f, "\t"); count++; ids[count] = f[1]; dates[count] = f[2]
      p = f[3]; sub(/[?#].*$/, "", p); type = p; sub(/^pkg:/, "", type); sub(/\/.*$/, "", type)
      sub(/^pkg:[a-z]+\//, "", p); v = p; sub(/@.*$/, "", p); sub(/^[^@]*@/, "", v)
      if (type ~ /^(apk|deb|rpm)$/) sub(/^.*\//, "", p)
      pnames[count] = decode(p); pversions[count] = decode(v)
      next
    }
    /^[ ]*(#.*)?$/ { next }
    /^ignore:[ ]*(\[\][ ]*)?(#.*)?$/ { if (root++) bad("ignore: twice"); empty = ($0 ~ /\[\]/); next }
    /^[^ ]/ { bad("only the key ignore may be set (grype reads every key of this file, and some leave a vulnerability out with no entry): " $0); next }
    !root || empty { bad("rule outside ignore:"); next }
    /^  - vulnerability:/ {
      close_rule()
      rule = 1; start = FNR; vuln = value($0); refused = typed("vulnerability", vuln)
      aliases = 0; pkg = 0; names = 0; versions = 0; name = ""; version = ""; inpkg = 0
      next
    }
    !rule { bad("unexpected line before the first - vulnerability: " $0); next }
    /^    include-aliases:/ { inpkg = 0; aliases++; if (value($0) != "true") bad("include-aliases must be true"); next }
    /^    package:[ ]*$/ { inpkg = 1; pkg++; next }
    /^      name:/ {
      if (!inpkg) bad("name outside package:")
      names++; raw = text($0); name = unescape(raw)
      if (quoted == "\"" && index(raw, "\\")) {
        refused = 1
        bad("package.name " raw " is in double quotes, where YAML reads \\ as an escape: write it plain or in single quotes")
      } else if (escape(name) != raw) {
        refused = 1
        bad("package.name " raw " is not a purl name with each of .*+?[](){}|^$\\ escaped by \\ (grype reads the name as" \
          " a regex, so it would cover other packages): write " escape(name))
      } else if (typed("package.name", raw)) refused = 1
      else if (quoted == "" && raw !~ /^[A-Za-z0-9]/ || name !~ /^[A-Za-z0-9@._:+~\/-]+$/) name = ""
      next
    }
    /^      version:/ {
      if (!inpkg) bad("version outside package:")
      versions++; version = value($0)
      if (typed("package.version", version)) refused = 1
      next
    }
    { bad("unexpected line (a rule has only vulnerability, include-aliases, package.name, package.version): " $0) }
    END { close_rule(); exit failed }' "$tmp/entries" "$grypeignore"
}

# check_config_ignorefile: deploy/ci/trivy-config-ignore.yaml may only list misconfigurations, each with an id
# (DS-0026, KSV-0048, ...), the paths it applies to (files of the repository, no pattern: an id is never left out for
# the whole repository, and an entry whose file is gone fails until it is removed), a statement giving the reason and an
# expired_at (yyyy-mm-dd) at most 90 days after today (UTC): a misconfiguration changes only when the repository does,
# so it gets about one stage, not the 30 days of a vulnerability. The statement is on its line (plain text or in quotes)
# or folded (>-) onto the lines below it. Read line by line in the shape below; anything else is refused rather than
# guessed:
#   misconfigurations:
#     - id: DS-0026
#       paths:
#         - deploy/docker/service.Dockerfile
#       statement: >-
#         why this is a deliberate choice
#       expired_at: 2027-01-22
check_config_ignorefile() {
  [ -f "$config_ignore" ] || return 0
  local limit listed failed=0
  limit=$(date -u -d '+90 days' +%F 2>/dev/null || date -u -v+90d +%F)
  listed=$(mktemp)
  awk -v limit="$limit" -v file="${config_ignore#"$repo_root"/}" -v listed="$listed" -v sq="'" "$statement_awk"'
    function bad_at(line, msg) { printf "FAIL  %s:%d: %s\n", file, line, msg; failed = 1 }
    function bad(msg) { bad_at(NR, msg) }
    function close_item() {
      if (!item) return
      if (paths == 0) bad_at(start, "entry " id " has no paths (an id is never ignored for the whole repository)")
      if (statement == "") bad_at(start, "entry " id " has no statement (the reason it is ignored)")
      if (expired !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
        bad_at(start, "entry " id " has no expired_at yyyy-mm-dd")
      else if (expired > limit)
        bad_at(start, "entry " id " expires " expired ", more than 90 days from today (" limit ")")
    }
    /^[ ]*(#.*)?$/ { next }
    /^misconfigurations:[ ]*$/ { if (root++) bad("misconfigurations: twice"); next }
    /^[^ ]/ { bad("only misconfigurations may be ignored here: " $0); next }
    !root { bad("entry outside misconfigurations:"); next }
    /^  - id:[ ]*[^ ]/ {
      close_item()
      item = 1; start = NR; statement = ""; expired = ""; paths = 0; list = 0; folded = 0
      id = $0; sub(/^  - id:[ ]*/, "", id)
      if (id !~ /^[A-Z]+-[0-9]+$/) bad("id " id " is not a check id such as DS-0026 or KSV-0048")
      next
    }
    /^    statement:[ ]*[>|]-?[ ]*$/ { list = 0; folded = 1; statement = ""; next }
    /^    statement:/ {
      list = 0; folded = 0
      if (!read_statement($0)) bad("statement is not plain text, text in quotes or a folded block (>-): " $0)
      next
    }
    /^    expired_at:/ {
      list = 0; folded = 0; expired = $0; sub(/^    expired_at:[ ]*/, "", expired); gsub(/"/, "", expired); next
    }
    /^    paths:[ ]*$/ { list = 1; folded = 0; next }
    /^      - [^ ]/ {
      if (!list) { bad("list item outside paths:"); next }
      path = $0; sub(/^      - /, "", path)
      if (path !~ /^[A-Za-z0-9._\/-]+$/ || path ~ /(^|\/)\.\.?(\/|$)/)
        bad("path " path " is not a plain relative path; name each file, no pattern")
      else print NR "\t" path > listed
      paths++
      next
    }
    /^      [^ -]/ { if (folded) { statement = statement $0; next } }
    { bad("unexpected line (only id, paths, statement, expired_at): " $0) }
    END { close_item(); exit failed }' "$config_ignore" || failed=1
  # Each path must be a file of the repository: not a directory (which would cover a whole tree), not a file gone.
  while IFS=$'\t' read -r line path; do
    [ -f "$repo_root/$path" ] || {
      echo "FAIL  ${config_ignore#"$repo_root"/}:$line: path $path is not a file of the repository"
      failed=1
    }
  done <"$listed"
  rm -f "$listed"
  return "$failed"
}

if [ "$mode" = check ]; then
  checked=0
  if check_ignorefile --live; then echo "ok    .trivyignore.yaml keeps its rules"; else checked=1; fi
  if check_grypeignore --live; then echo "ok    .grype.yaml keeps its rules"; else checked=1; fi
  if check_config_ignorefile; then
    echo "ok    ${config_ignore#"$repo_root"/} keeps its rules"
  else checked=1; fi
  [ "$checked" -eq 0 ] || fail "an ignore file breaks its rules"
  exit 0
fi

blocked=0
if ! check_ignorefile || ! check_grypeignore; then
  echo "FAIL  an ignore file breaks its rules: fix it before anything is pushed" >&2
  blocked=1
fi

# summary LINE: one line of the job summary per scan; where the summary is a page of its own, in the log too.
summary() {
  ci_summary "- $1"
  if ci_has_summary; then echo "$1"; fi
}

if [ "$mode" = grype ]; then
  fail_on=()
  [ "$allow_critical" = true ] || fail_on=(--fail-on critical)
  rc=0
  grype_sbom "$input" ${fail_on[@]+"${fail_on[@]}"} || rc=$?
  # grype exits 2 when a match is at or above --fail-on, 1 when it could not scan.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] || ! jq -e '.descriptor.name == "grype"' "$input/grype.json" >/dev/null 2>&1; then
    echo "FAIL  $label: grype could not scan $input/sbom.spdx.json" >&2
    exit 2
  fi
  read -r critical high excepted < <(jq -r '[([.matches[] | select(.vulnerability.severity == "Critical")] | length),
    ([.matches[] | select(.vulnerability.severity == "High")] | length), (.ignoredMatches // [] | length)] | @tsv' \
    "$input/grype.json")
  summary "$label (grype): Critical $critical, High $high, excepted by .grype.yaml $excepted"
  if [ "$critical" -gt 0 ]; then
    jq -r '.matches[] | select(.vulnerability.severity == "Critical")
      | "critical  \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) \(.artifact.purl // "no purl")"
        + " (fixed: \(.vulnerability.fix.versions // [] | join(", ") | if . == "" then "none" else . end))"' \
      "$input/grype.json" | ci_summary_tee >&2
  fi
  if [ "$rc" -eq 2 ]; then
    echo "FAIL  $label (grype): Critical vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  elif [ "$critical" -gt 0 ]; then
    echo "note  $label (grype): $critical Critical vulnerabilities let through (--allow-critical)" >&2
  fi
  [ "$blocked" -eq 0 ] && echo "ok    $label (grype) passes the scan gate"
  exit "$blocked"
fi

report=$input
jq -e '.SchemaVersion == 2 and (.Metadata.ImageID | test("^sha256:[0-9a-f]{64}$"))' "$report" >/dev/null 2>&1 || {
  echo "FAIL  $label: $report is not a trivy image JSON report (SchemaVersion 2 with Metadata.ImageID)" >&2
  exit 2
}
read -r critical high secrets < <(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] as $s
  | [([$s[] | select(. == "CRITICAL")] | length), ([$s[] | select(. == "HIGH")] | length),
    ([.Results[]?.Secrets[]?] | length)] | @tsv' "$report")
summary "$label (trivy): CRITICAL $critical, HIGH $high, secrets $secrets"

# Each pass reads only its own findings: the vulnerabilities without the secrets, the secrets without the
# vulnerabilities. trivy exits 5 (--exit-code) for a finding, 1 when it fails.
jq 'del(.Results[]?.Secrets)' "$report" >"$tmp/vulnerabilities.json" &&
  jq 'del(.Results[]?.Vulnerabilities)' "$report" >"$tmp/secrets.json" || fail "split $report"
trivy_mounts=(-v "$tmp:/in:ro")
ignore=(--ignorefile '')
if [ -f "$trivyignore" ]; then
  trivy_mounts+=(-v "$trivyignore:/ignore.yaml:ro")
  ignore=(--ignorefile /ignore.yaml)
fi
# convert ARGS...: trivy convert with ARGS; sets rc to 0 (nothing found) or 5 (found), and stops (exit 2) when trivy
# failed.
convert() {
  rc=0
  trivy_ convert --exit-code 5 "$@" >&2 || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 5 ] || {
    echo "FAIL  $label: trivy could not read $report" >&2
    exit 2
  }
}
convert --format json --output /dev/null --ignorefile '' /in/secrets.json
if [ "$rc" -ne 0 ]; then
  echo "FAIL  $label: secrets found; nothing is pushed, signed or attested" >&2
  # Rule, file and line only: the matched text stays out of logs and summaries of a public repository.
  jq -r '.Results[]? | .Target as $t | .Secrets[]? | "secret  \(.RuleID) (\(.Severity)) in \($t) line \(.StartLine)"' \
    "$report" | ci_summary_tee >&2
  blocked=1
fi
convert --format table --table-mode detailed --severity CRITICAL "${ignore[@]}" /in/vulnerabilities.json
if [ "$rc" -ne 0 ]; then
  if [ "$allow_critical" = true ]; then
    echo "note  $label (trivy): CRITICAL vulnerabilities let through (--allow-critical)" >&2
  else
    echo "FAIL  $label (trivy): CRITICAL vulnerabilities; nothing is pushed, signed or attested" >&2
    blocked=1
  fi
fi
[ "$blocked" -eq 0 ] && echo "ok    $label (trivy) passes the scan gate"
exit "$blocked"
