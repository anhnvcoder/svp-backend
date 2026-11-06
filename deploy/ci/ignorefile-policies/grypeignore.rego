# Rules of .grype.yaml, the vulnerabilities grype leaves out of each image's SBOM scan; each deny message says why.
# grype reads every key of the file, and several leave a CRITICAL out with no entry or date: only `ignore` is accepted.
# Each rule must be one purl of an entry of .trivyignore.yaml (in force, in job config): no exception trivy has not.
# Design notes: docs/reference/ci.md.
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

deny contains $"{file}: the file must be a mapping of the one key ignore" if {
	ignorefiles.present(file)
	not is_object(doc)
}

deny contains msg if {
	is_object(doc)
	some k, _ in doc
	k != "ignore"
	msg := $"{file}: only the key ignore may be set (grype reads every key of this file, and some leave a vulnerability out with no entry): {k}"
}

deny contains $"{file}: ignore must be a list (ignore: [] when nothing is excepted)" if {
	is_object(doc)
	not is_array(object.get(doc, "ignore", null))
}

deny contains $"{file}: rule #{i + 1} is not a mapping" if {
	some i, r in list
	not is_object(r)
}

deny contains msg if {
	some [i, k] in unexpected
	msg := $"{file}: rule {name(i)}: unexpected key {k} (a rule has only vulnerability, include-aliases, package.name, package.version)"
}

unexpected contains [i, k] if {
	some i, r in rules
	some k in ignorefiles.extra(r, {"vulnerability", "include-aliases", "package"})
}

unexpected contains [i, $"package.{k}"] if {
	some i, r in rules
	is_object(r.package)
	some k in ignorefiles.extra(r.package, {"name", "version"})
}

deny contains $"{file}: rule {name(i)} needs include-aliases: true" if {
	some i, r in rules
	object.get(r, "include-aliases", null) != true
}

deny contains $"{file}: rule {name(i)} has no {key}" if {
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
	msg := $"{file}: rule {name(i)}: {key} {v} is a null, a bool, a number or a date to YAML, not text (grype would drop it from the rule or read another value): put it in quotes"
}

deny contains msg if {
	some i, r in rules
	some key in fields
	v := field(r, key)
	date_form(v)
	msg := $"{file}: rule {name(i)}: {key} {v} has the form of a date, which grype reads as a date unless it is quoted, and the check cannot see quotes: not accepted"
}

deny contains $"{file}: rule {name(i)}: {key} {v} is not plain (letters, digits, @._:+~/-)" if {
	some i, r in rules
	some key in ["vulnerability", "package.version"]
	v := field(r, key)
	is_string(v)
	not plain(v)
}

# grype reads package.name as a regex anchored at both ends (mini.* covers minimist): escape each metacharacter.
deny contains msg if {
	some i, r in rules
	v := r.package.name
	is_string(v)
	escape(unescape(v)) != v
	msg := concat("", [
		$"{file}: rule {name(i)}: package.name {v} is not a purl name with each of .*+?[]()\{}|^$\\ escaped ",
		$"by \\ (grype reads the name as a regex, so it would cover other packages): write {escape(unescape(v))}",
	])
}

deny contains $"{file}: rule {name(i)}: package.name {v} is not plain (letters, digits, @._:+~/- once unescaped)" if {
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
	msg := $"{file}: rule {vuln} {pname}@{version} is {n} entries of .trivyignore.yaml{in_force_note}, not exactly one (same id, a purl of that name and version)"
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

in_force(e) if not ignorefiles.expired(e.expired_at)

default in_force_note := ""

in_force_note := " in force" if data.scan_gate.live == true

plain(v) if regex.match(`^[A-Za-z0-9@._:+~/-]+$`, v)

# date_form(v): v is written as YAML reads a date (2026-1-2, 2001-12-14T21:59:43Z).
date_form(v) if {
	is_string(v)
	regex.match(`^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt].*)?$`, v)
}

escape(s) := regex.replace(s, `[.*+?\[\](){}|^$\\]`, `\$0`)

# unescape(s): s with the backslash before each character dropped; escape(unescape(s)) == s only when s escapes every
# metacharacter and nothing else.
unescape(s) := regex.replace(s, `\\(.)`, "$1")
