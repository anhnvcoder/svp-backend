# Tests of grypeignore.rego (make conftest-verify), each on a .grype.yaml and the .trivyignore.yaml beside it. Today is
# fixed at 2026-11-05.
package grypeignore_test

import data.grypeignore

live := {"today": "2026-11-05", "live": true}

gate := {"today": "2026-11-05", "live": false}

# deny(trivy, grype, mode): the messages of the rules on .grype.yaml holding grype, beside a .trivyignore.yaml holding
# trivy, in mode (live or gate).
deny(trivy, grype, mode) := msgs if {
	msgs := grypeignore.deny with input as [
		{"path": ".trivyignore.yaml", "contents": yaml.unmarshal(trivy)},
		{"path": ".grype.yaml", "contents": yaml.unmarshal(grype)},
	]
		with data.scan_gate as mode
}

# entry(id, expired_at, purl): a .trivyignore.yaml of one entry.
entry(id, expired_at, purl) := sprintf(
	"vulnerabilities:\n  - id: %s\n    statement: Accepted for the test.\n    expired_at: %s\n    purls:\n      - %s\n",
	[id, expired_at, purl],
)

# rule(id, name, version): a .grype.yaml of one rule, each value written as given.
rule(id, name, version) := sprintf(
	"ignore:\n  - vulnerability: %s\n    include-aliases: true\n    package:\n      name: %s\n      version: %s\n",
	[id, name, version],
)

left_pad := entry("CVE-2026-1111", "2026-11-15", "pkg:npm/left-pad@1.0.0")

says(msgs, want) if {
	some m in msgs
	contains(m, want)
}

# matched(msgs): a message says the rule was matched against the entries.
matched(msgs) if says(msgs, "entries of .trivyignore.yaml")

test_an_entry_and_its_rule_pass if count(deny(left_pad, rule("CVE-2026-1111", "left-pad", "1.0.0"), live)) == 0

test_nothing_to_except_passes if count(deny("vulnerabilities: []\n", "ignore: []\n", live)) == 0

test_a_scoped_npm_package_quoted_with_its_scope_in_percent if count(deny(
	entry("CVE-2026-3333", "2026-11-15", "pkg:npm/%40scope/pkg@1.0.0"),
	rule("CVE-2026-3333", `"@scope/pkg"`, "1.0.0"),
	live,
)) == 0

test_a_root_key_other_than_ignore if says(
	deny(left_pad, concat("", ["only-notfixed: true\n", rule("CVE-2026-1111", "left-pad", "1.0.0")]), gate),
	".grype.yaml: only the key ignore may be set (grype reads every key of this file, and some leave a vulnerability out with no entry): only-notfixed",
)

test_a_rule_without_include_aliases if {
	says(
		deny(left_pad, "ignore:\n  - vulnerability: CVE-2026-1111\n    package:\n      name: left-pad\n      version: 1.0.0\n", gate),
		".grype.yaml: rule CVE-2026-1111 needs include-aliases: true",
	)
	says(
		deny(left_pad, "ignore:\n  - vulnerability: CVE-2026-1111\n    include-aliases: false\n    package:\n      name: left-pad\n      version: 1.0.0\n", gate),
		"rule CVE-2026-1111 needs include-aliases: true",
	)
}

test_a_rule_with_fix_state_and_no_package if {
	msgs := deny(left_pad, "ignore:\n  - vulnerability: CVE-2026-1111\n    include-aliases: true\n    fix-state: fixed\n", gate)
	says(msgs, "rule CVE-2026-1111: unexpected key fix-state (a rule has only vulnerability, include-aliases, package.name, package.version)")
	says(msgs, "rule CVE-2026-1111 has no package.name")
	says(msgs, "rule CVE-2026-1111 has no package.version")
	not matched(msgs)
}

test_a_rule_with_package_type if says(
	deny(left_pad, concat("", [rule("CVE-2026-1111", "left-pad", "1.0.0"), "      type: npm\n"]), gate),
	"rule CVE-2026-1111: unexpected key package.type",
)

test_a_rule_for_another_version_than_the_entry if says(
	deny(left_pad, rule("CVE-2026-1111", "left-pad", "1.0.1"), live),
	".grype.yaml: rule CVE-2026-1111 left-pad@1.0.1 is 0 entries of .trivyignore.yaml in force, not exactly one (same id, a purl of that name and version)",
)

test_a_rule_whose_id_no_entry_has if says(
	deny(left_pad, rule("CVE-2026-9999", "left-pad", "1.0.0"), gate),
	"rule CVE-2026-9999 left-pad@1.0.0 is 0 entries of .trivyignore.yaml, not exactly one",
)

test_a_rule_without_a_trivyignore_yaml if {
	msgs := grypeignore.deny with input as [{"path": ".grype.yaml", "contents": yaml.unmarshal(rule("CVE-2026-1111", "left-pad", "1.0.0"))}]
		with data.scan_gate as live
	says(msgs, "rule CVE-2026-1111 left-pad@1.0.0 is 0 entries")
}

test_a_rule_two_entries_cover if says(
	deny(
		concat("", [left_pad, "  - id: CVE-2026-1111\n    statement: Again.\n    expired_at: 2026-11-20\n    purls:\n      - pkg:npm/left-pad@1.0.0\n"]),
		rule("CVE-2026-1111", "left-pad", "1.0.0"),
		gate,
	),
	"rule CVE-2026-1111 left-pad@1.0.0 is 2 entries of .trivyignore.yaml, not exactly one",
)

# grype reads package.name as a regex anchored at both ends: a name must be the purl's name with each metacharacter
# escaped by a backslash. Written any other way it is refused even when an entry of that very name exists (.* would
# cover every package at the version, mini.* and minimis[t] cover minimist), and is not matched against the entries.
test_a_name_that_is_not_the_escaped_purl_name if {
	every name in [".*", `"mini.*"`, "minimis.", "minimis[t]", "libstdc++", "socket.io-parser", `mini\st`] {
		plain := trim(name, `"`)
		msgs := deny(entry("CVE-2021-44906", "2026-11-15", sprintf("pkg:npm/%s@1.2.5", [plain])), rule("CVE-2021-44906", name, "1.2.5"), live)
		says(msgs, sprintf(`package.name %s is not a purl name with each of .*+?[](){}|^$\ escaped by \`, [plain]))
		not matched(msgs)
	}
}

test_the_refusal_gives_the_name_to_write if says(
	deny(entry("CVE-2021-44906", "2026-11-15", "pkg:npm/minist@1.2.5"), rule("CVE-2021-44906", `mini\st`, "1.2.5"), live),
	"write minist",
)

# The purl's name escaped, plain or quoted, matches its entry (in double quotes YAML reads \\ as one backslash).
test_an_escaped_name_matches_its_entry if {
	every case in [
		[`socket\.io-parser`, "pkg:npm/socket.io-parser"],
		[`'libstdc\+\+'`, "pkg:apk/alpine/libstdc++"],
		[`"libstdc\\+\\+"`, "pkg:apk/alpine/libstdc++"],
		[`golang\.org/x/net`, "pkg:golang/golang.org/x/net"],
	] {
		count(deny(entry("CVE-2021-44906", "2026-11-15", sprintf("%s@1.2.5", [case[1]])), rule("CVE-2021-44906", case[0], "1.2.5"), live)) == 0
	}
}

test_an_escaped_name_that_is_not_the_entry if says(
	deny(entry("CVE-2021-44906", "2026-11-15", "pkg:npm/socket.io-parser@1.2.5"), rule("CVE-2021-44906", `socket\.io-parsers`, "1.2.5"), live),
	"rule CVE-2021-44906 socket.io-parsers@1.2.5 is 0 entries",
)

# The name of a purl is the one grype gives its package: with its namespace (an npm scope, a Go module path), except for
# a distribution's package (apk, deb, rpm), whose namespace is the distribution. A rule for foo would cover the
# unscoped foo too, one for net any package named net.
test_a_name_without_the_namespace_grype_gives if {
	every case in [["foo", "pkg:npm/%40scope/foo"], ["net", "pkg:golang/golang.org/x/net"], ["alpine/glib", "pkg:apk/alpine/glib"]] {
		says(
			deny(entry("CVE-2026-1111", "2026-11-15", sprintf("%s@1.0.0", [case[1]])), rule("CVE-2026-1111", case[0], "1.0.0"), live),
			sprintf("rule CVE-2026-1111 %s@1.0.0 is 0 entries", [case[0]]),
		)
	}
}

test_a_distribution_package_with_qualifiers_and_percent_escapes if {
	every case in [
		["glib", "2.88.1-r1", "pkg:apk/alpine/glib@2.88.1-r1?arch=aarch64&distro=3.24.0"],
		["libc6", "2.36-9+deb12u4", "pkg:deb/debian/libc6@2.36-9%2Bdeb12u4?arch=amd64&distro=debian-12"],
	] {
		count(deny(entry("CVE-2026-1111", "2026-11-15", case[2]), rule("CVE-2026-1111", case[0], case[1]), live)) == 0
	}
}

# A plain value YAML reads as a null, a bool or a number is not the text it shows: grype drops a null from the rule (as
# the version it covers every version of the package, as the name every package) and reads 1.10 as 1.1. Refused in
# vulnerability, name and version even with an entry of that very text, and not matched; quoted it is text.
test_a_version_that_is_no_text if {
	every value in ["null", "NULL", "~", "true", "False", "1.10", "017", "0x1F", "0o17", "0b101", "1e5", "1_000"] {
		msgs := deny(entry("CVE-2021-44906", "2026-11-15", sprintf("pkg:npm/minimist@%s", [value])), rule("CVE-2021-44906", "minimist", value), live)
		says(msgs, "rule CVE-2021-44906: package.version ")
		says(msgs, "is a null, a bool, a number or a date to YAML, not text")
		not matched(msgs)
		count(deny(entry("CVE-2021-44906", "2026-11-15", sprintf("pkg:npm/minimist@%s", [value])), rule("CVE-2021-44906", "minimist", sprintf("'%s'", [value])), live)) == 0
	}
}

# A date grype refuses to start on. The parsed file no longer shows whether it was quoted, so the date form is refused
# quoted or not.
test_a_version_of_the_form_of_a_date if {
	every value in ["2026-1-2", "'2026-1-2'", "2001-12-14T21:59:43Z"] {
		msgs := deny(entry("CVE-2021-44906", "2026-11-15", "pkg:npm/minimist@2026-1-2"), rule("CVE-2021-44906", "minimist", value), live)
		says(msgs, "has the form of a date")
		not matched(msgs)
	}
}

test_a_name_that_is_no_text if {
	every value in ["null", "true", "017"] {
		msgs := deny(entry("CVE-2021-44906", "2026-11-15", sprintf("pkg:npm/%s@1.2.5", [value])), rule("CVE-2021-44906", value, "1.2.5"), live)
		says(msgs, "rule CVE-2021-44906: package.name ")
		says(msgs, "is a null, a bool, a number or a date to YAML, not text")
		not matched(msgs)
		count(deny(entry("CVE-2021-44906", "2026-11-15", sprintf("pkg:npm/%s@1.2.5", [value])), rule("CVE-2021-44906", sprintf("'%s'", [value]), "1.2.5"), live)) == 0
	}
}

test_a_vulnerability_that_is_no_text if {
	every value in ["null", "False"] {
		msgs := deny(entry(value, "2026-11-15", "pkg:npm/lodash@4.17.15"), rule(value, "lodash", "4.17.15"), live)
		says(msgs, ": vulnerability ")
		says(msgs, "is a null, a bool, a number or a date to YAML, not text")
		not matched(msgs)
	}
}

# 1:20 is text to every parser here (no base 60). yes is text to grype and to yaml.unmarshal of these tests, but a bool
# to the parser conftest reads the files with (YAML 1.1), so a name yes is quoted.
test_a_version_with_a_colon_passes if count(deny(
	entry("CVE-2021-44906", "2026-11-15", "pkg:deb/debian/yes@1:20"),
	rule("CVE-2021-44906", "'yes'", "1:20"),
	live,
)) == 0

test_a_value_that_is_not_plain if {
	says(
		deny(left_pad, rule("CVE-2026-1111", "left-pad", "'1.0.0 extra'"), gate),
		"rule CVE-2026-1111: package.version 1.0.0 extra is not plain",
	)
	says(
		deny(left_pad, rule("'CVE 2026'", "left-pad", "1.0.0"), gate),
		"rule CVE 2026: vulnerability CVE 2026 is not plain",
	)
}

# Live (job config) a rule must be an entry still in force: grype reads no date, so the rule of an expired entry would
# go on covering the match. The image gates leave the expired entry to trivy.
test_the_rule_of_an_expired_entry if {
	expired := entry("CVE-2026-1111", "2026-11-05", "pkg:npm/left-pad@1.0.0")
	says(
		deny(expired, rule("CVE-2026-1111", "left-pad", "1.0.0"), live),
		"rule CVE-2026-1111 left-pad@1.0.0 is 0 entries of .trivyignore.yaml in force",
	)
	count(deny(expired, rule("CVE-2026-1111", "left-pad", "1.0.0"), gate)) == 0
}

test_a_file_of_another_shape if {
	says(deny(left_pad, "- vulnerability: CVE-2026-1111\n", gate), ".grype.yaml: the file must be a mapping of the one key ignore")
	says(deny(left_pad, "ignore:\n", gate), ".grype.yaml: ignore must be a list (ignore: [] when nothing is excepted)")
	says(deny(left_pad, "ignore:\n  vulnerability: CVE-2026-1111\n", gate), "ignore must be a list")
	says(deny(left_pad, "ignore:\n  - CVE-2026-1111\n", gate), ".grype.yaml: rule #1 is not a mapping")
	says(deny(left_pad, "ignore:\n  - include-aliases: true\n", gate), ".grype.yaml: rule #1 has no vulnerability")
	says(
		deny(left_pad, "ignore:\n  - vulnerability: CVE-2026-1111\n    include-aliases: true\n    package: left-pad\n", gate),
		"rule CVE-2026-1111 has no package.name",
	)
}
