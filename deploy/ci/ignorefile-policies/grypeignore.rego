# Rules of .grype.yaml, the vulnerabilities grype leaves out of the scan of each image's SBOM (grype -c of
# deploy/ci/scan-gate.sh --grype). grype reads the whole file, and several keys it knows leave a CRITICAL out with no
# entry and no date (only-fixed, only-notfixed and ignore-wontfix at the root, vex-documents, a rule naming only
# fix-state or package.type, or one without package); a key it does not know it ignores without a word. So the file
# holds only this shape, anything else is refused:
#   ignore:                            # the one root key, a list (ignore: [] when nothing is excepted)
#     - vulnerability: CVE-2026-12345  # exactly these keys in a rule
#       include-aliases: true          # covers the match grype reports under a related id (a GHSA for the CVE)
#       package:
#         name: ffmpeg                 # exactly name and version
#         version: 8.0.1-r0
# vulnerability, name and version must be YAML strings: grype drops a null from the rule, which then covers every
# vulnerability, package or version, reads a number as other text (1.10 as 1.1) and refuses to start on a date. In
# quotes such a value is text, but a date form (2026-1-2) is refused even in quotes: the parsed file no longer shows the
# quotes. conftest parses YAML 1.1, so a plain yes, no, on or off is a bool here (text to grype): quote it. Each is plain (letters, digits and @._:+~/-, the name once unescaped). grype reads package.name as a regex
# anchored at both ends when it holds one of *+?[](){}|^$\ (mini.* covers minimist), so the name must be the purl's
# name with each of .*+?[](){}|^$\ escaped by \ (socket\.io-parser, libstdc\+\+, golang\.org/x/net): that name covers
# its one package whether grype reads it as a regex or as text, and no entry and rule pair (pkg:npm/.*@1.2.5 and .*)
# covers every package at a version. Each rule must be exactly one purl of an entry of .trivyignore.yaml
# (trivyignore.packages): the same id, the purl's name as grype names the package, the same version; live (job config),
# of an entry still in force. So grype never has an exception trivy does not, with its reason and its date there.
package grypeignore

import data.ignorefiles
import data.trivyignore

file := ".grype.yaml"

doc := ignorefiles.contents(file)

list := ignorefiles.items(doc.ignore) if is_object(doc)

rules[i] := r if {
	some i, r in list
	is_object(r)
}

name(i) := ignorefiles.label(i, object.get(rules[i], "vulnerability", null))

# The values grype matches on, by name; undefined when the rule has none.
field(r, "vulnerability") := r.vulnerability

field(r, "package.name") := r.package.name

field(r, "package.version") := r.package.version

fields := ["vulnerability", "package.name", "package.version"]

deny contains sprintf("%s: the file must be a mapping of the one key ignore", [file]) if {
	ignorefiles.present(file)
	not is_object(doc)
}

deny contains msg if {
	is_object(doc)
	some k, _ in doc
	k != "ignore"
	msg := sprintf(
		"%s: only the key ignore may be set (grype reads every key of this file, and some leave a vulnerability out with no entry): %s",
		[file, k],
	)
}

deny contains sprintf("%s: ignore must be a list (ignore: [] when nothing is excepted)", [file]) if {
	is_object(doc)
	not is_array(object.get(doc, "ignore", null))
}

deny contains sprintf("%s: rule #%d is not a mapping", [file, i + 1]) if {
	some i, r in list
	not is_object(r)
}

deny contains msg if {
	some [i, k] in unexpected
	msg := sprintf(
		"%s: rule %s: unexpected key %s (a rule has only vulnerability, include-aliases, package.name, package.version)",
		[file, name(i), k],
	)
}

unexpected contains [i, k] if {
	some i, r in rules
	some k in ignorefiles.extra(r, {"vulnerability", "include-aliases", "package"})
}

unexpected contains [i, sprintf("package.%s", [k])] if {
	some i, r in rules
	is_object(r.package)
	some k in ignorefiles.extra(r.package, {"name", "version"})
}

deny contains sprintf("%s: rule %s needs include-aliases: true", [file, name(i)]) if {
	some i, r in rules
	object.get(r, "include-aliases", null) != true
}

deny contains sprintf("%s: rule %s has no %s", [file, name(i), key]) if {
	some i, r in rules
	some key in fields
	not has(r, key)
}

has(r, key) if _ = field(r, key)

deny contains msg if {
	some i, r in rules
	some key in fields
	v := field(r, key)
	not is_string(v)
	msg := sprintf(
		"%s: rule %s: %s %v is a null, a bool, a number or a date to YAML, not text (grype would drop it from the rule or read another value): put it in quotes",
		[file, name(i), key, v],
	)
}

deny contains msg if {
	some i, r in rules
	some key in fields
	v := field(r, key)
	date_form(v)
	msg := sprintf(
		"%s: rule %s: %s %s has the form of a date, which grype reads as a date unless it is quoted, and the check cannot see quotes: not accepted",
		[file, name(i), key, v],
	)
}

deny contains sprintf("%s: rule %s: %s %s is not plain (letters, digits, @._:+~/-)", [file, name(i), key, v]) if {
	some i, r in rules
	some key in ["vulnerability", "package.version"]
	v := field(r, key)
	is_string(v)
	not plain(v)
}

deny contains msg if {
	some i, r in rules
	v := r.package.name
	is_string(v)
	escape(unescape(v)) != v
	msg := sprintf(
		"%s: rule %s: package.name %s is not a purl name with each of .*+?[](){}|^$\\ escaped by \\ (grype reads the name as a regex, so it would cover other packages): write %s",
		[file, name(i), v, escape(unescape(v))],
	)
}

deny contains sprintf("%s: rule %s: package.name %s is not plain (letters, digits, @._:+~/- once unescaped)", [file, name(i), v]) if {
	some i, r in rules
	v := r.package.name
	is_string(v)
	escape(unescape(v)) == v
	not plain(unescape(v))
}

deny contains msg if {
	some i, r in rules
	sound(r)
	vuln := r.vulnerability
	pname := unescape(r.package.name)
	version := r.package.version
	n := count([e |
		some e in trivyignore.packages
		e.id == vuln
		e.name == pname
		e.version == version
		in_force(e)
	])
	n != 1
	msg := sprintf(
		"%s: rule %s %s@%s is %d entries of .trivyignore.yaml%s, not exactly one (same id, a purl of that name and version)",
		[file, vuln, pname, version, n, in_force_note],
	)
}

# sound(r): r names its vulnerability and package by values the rules accept; only such a rule is matched against the
# entries, so a refused value never passes for an entry of the same text.
sound(r) if {
	every key in fields {
		v := field(r, key)
		is_string(v)
		not date_form(v)
	}
	plain(r.vulnerability)
	plain(r.package.version)
	escape(unescape(r.package.name)) == r.package.name
	plain(unescape(r.package.name))
}

# in_force(e): live, the entry is not expired; otherwise any entry.
in_force(e) if not ignorefiles.expired(e.expired_at)

in_force_note := " in force" if {
	data.scan_gate.live == true
} else := ""

plain(v) if regex.match(`^[A-Za-z0-9@._:+~/-]+$`, v)

# date_form(v): v is written as YAML reads a date (2026-1-2, 2001-12-14T21:59:43Z).
date_form(v) if {
	is_string(v)
	regex.match(`^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt].*)?$`, v)
}

# escape(s): s with each character a regex reads as more than itself escaped by a backslash.
escape(s) := regex.replace(s, `[.*+?\[\](){}|^$\\]`, `\$0`)

# unescape(s): s with the backslash before each character dropped; escape(unescape(s)) == s only when s escapes every
# metacharacter and nothing else.
unescape(s) := regex.replace(s, `\\(.)`, "$1")
