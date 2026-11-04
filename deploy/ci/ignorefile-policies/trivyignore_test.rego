# Tests of trivyignore.rego (make conftest-verify). Today is fixed at 2026-11-05: the limit is 2026-12-05.
package trivyignore_test

import data.trivyignore

live := {"today": "2026-11-05", "live": true}

gate := {"today": "2026-11-05", "live": false}

# deny(text, mode): the messages of the rules on .trivyignore.yaml holding text, in mode (live or gate).
deny(text, mode) := msgs if {
	msgs := trivyignore.deny with input as [{"path": ".trivyignore.yaml", "contents": yaml.unmarshal(text)}]
		with data.scan_gate as mode
}

# entry(id, expired_at, purl): one entry with a statement.
entry(id, expired_at, purl) := sprintf(
	"  - id: %s\n    statement: Accepted for the test.\n    expired_at: %s\n    purls:\n      - %s\n",
	[id, expired_at, purl],
)

one(expired_at, purl) := concat("", ["vulnerabilities:\n", entry("CVE-2026-1111", expired_at, purl)])

says(msgs, want) if {
	some m in msgs
	contains(m, want)
}

test_an_entry_passes if count(deny(one("2026-11-15", "pkg:npm/left-pad@1.0.0"), live)) == 0

test_nothing_to_except_passes if count(deny("vulnerabilities: []\n", live)) == 0

test_an_entry_of_30_days_passes if count(deny(one("2026-12-05", "pkg:npm/left-pad@1.0.0"), live)) == 0

test_an_entry_for_more_than_30_days if says(
	deny(one("2026-12-15", "pkg:npm/left-pad@1.0.0"), gate),
	".trivyignore.yaml: entry CVE-2026-1111 expires 2026-12-15, more than 30 days from today (2026-12-05)",
)

test_a_purl_without_its_version if says(
	deny(one("2026-11-15", "pkg:npm/left-pad"), gate),
	"entry CVE-2026-1111: purl pkg:npm/left-pad is not pkg:<type>/<name>@<version>",
)

test_a_purl_that_is_no_text if says(
	deny(one("2026-11-15", "17"), gate),
	"entry CVE-2026-1111: purl 17 is not pkg:<type>/<name>@<version>",
)

test_an_entry_without_purls if {
	says(
		deny("vulnerabilities:\n  - id: CVE-2026-1111\n    statement: Accepted.\n    expired_at: 2026-11-15\n", gate),
		"entry CVE-2026-1111 has no purls (the package versions it covers)",
	)
	says(
		deny("vulnerabilities:\n  - id: CVE-2026-1111\n    statement: Accepted.\n    expired_at: 2026-11-15\n    purls: []\n", gate),
		"entry CVE-2026-1111 has no purls",
	)
}

test_a_secrets_section if says(
	deny(concat("", [one("2026-11-15", "pkg:npm/left-pad@1.0.0"), "secrets:\n  - id: aws-access-key-id\n"]), gate),
	".trivyignore.yaml: only vulnerabilities may be ignored, never secrets or anything else: secrets",
)

test_an_entry_without_a_statement if {
	every statement in ["", "    statement:\n", "    statement: null\n", "    statement: ''\n", "    statement: '   '\n"] {
		says(
			deny(sprintf("vulnerabilities:\n  - id: CVE-2026-1111\n%s    expired_at: 2026-11-15\n    purls:\n      - pkg:npm/a@1\n", [statement]), gate),
			"entry CVE-2026-1111 has no statement (the reason it is ignored)",
		)
	}
}

test_a_folded_statement_passes if count(deny(
	"vulnerabilities:\n  - id: CVE-2026-1111\n    statement: >-\n      a reason\n      on two lines\n    expired_at: 2026-11-15\n    purls:\n      - pkg:npm/a@1\n",
	live,
)) == 0

test_an_entry_without_expired_at if {
	says(
		deny("vulnerabilities:\n  - id: CVE-2026-1111\n    statement: Accepted.\n    purls:\n      - pkg:npm/a@1\n", gate),
		"entry CVE-2026-1111 has no expired_at yyyy-mm-dd",
	)
	says(deny(one("2026-11-1", "pkg:npm/a@1"), gate), "entry CVE-2026-1111 has no expired_at yyyy-mm-dd")
}

test_an_entry_without_an_id if says(
	deny("vulnerabilities:\n  - statement: Accepted.\n    expired_at: 2026-11-15\n    purls:\n      - pkg:npm/a@1\n", gate),
	".trivyignore.yaml: entry #1 has no id",
)

test_paths_or_another_key if says(
	deny(concat("", [one("2026-11-15", "pkg:npm/a@1"), "    paths:\n      - Dockerfile\n"]), gate),
	"entry CVE-2026-1111: unexpected key paths (only id, statement, expired_at, purls)",
)

# Live (job config) an entry fails from its expired_at day on; the image gates leave it to trivy.
test_an_expired_entry if {
	says(
		deny(one("2026-11-05", "pkg:npm/left-pad@1.0.0"), live),
		".trivyignore.yaml: entry CVE-2026-1111 expired on 2026-11-05: renew it with a reason, or remove it (and its rule in .grype.yaml)",
	)
	count(deny(one("2026-11-05", "pkg:npm/left-pad@1.0.0"), gate)) == 0
	count(deny(one("2026-11-06", "pkg:npm/left-pad@1.0.0"), live)) == 0
}

test_a_file_of_another_shape if {
	says(deny("- id: CVE-2026-1111\n", gate), ".trivyignore.yaml: the file must be a mapping of the one key vulnerabilities")
	says(deny("# nothing\n", gate), "the file must be a mapping of the one key vulnerabilities")
	says(deny("misconfigurations: []\n", gate), "vulnerabilities must be a list (vulnerabilities: [] when nothing is excepted)")
	says(deny("vulnerabilities:\n", gate), "vulnerabilities must be a list")
	says(deny("vulnerabilities:\n  id: CVE-2026-1111\n", gate), "vulnerabilities must be a list")
	says(deny("vulnerabilities:\n  - CVE-2026-1111\n", gate), ".trivyignore.yaml: entry #1 is not a mapping")
}

# The package of each purl as grype names it, for the rules of .grype.yaml.
test_the_packages_grype_names if {
	packages := trivyignore.packages with input as [{"path": ".trivyignore.yaml", "contents": yaml.unmarshal(concat("", [
		"vulnerabilities:\n",
		entry("CVE-1", "2026-11-15", "pkg:npm/%40scope/foo@1.0.0"),
		entry("CVE-2", "2026-11-15", "pkg:golang/golang.org/x/net@0.1.0"),
		entry("CVE-3", "2026-11-15", "pkg:apk/alpine/glib@2.88.1-r1?arch=aarch64&distro=3.24.0"),
		entry("CVE-4", "2026-11-15", "pkg:deb/debian/libc6@2.36-9%2Bdeb12u4?arch=amd64&distro=debian-12"),
		entry("CVE-5", "2026-11-15", "pkg:apk/alpine/libstdc++@14.2.0-r6"),
		entry("CVE-6", "2026-11-15", "pkg:npm/left-pad"),
	]))}]
	packages == [
		{"id": "CVE-1", "expired_at": "2026-11-15", "name": "@scope/foo", "version": "1.0.0"},
		{"id": "CVE-2", "expired_at": "2026-11-15", "name": "golang.org/x/net", "version": "0.1.0"},
		{"id": "CVE-3", "expired_at": "2026-11-15", "name": "glib", "version": "2.88.1-r1"},
		{"id": "CVE-4", "expired_at": "2026-11-15", "name": "libc6", "version": "2.36-9+deb12u4"},
		{"id": "CVE-5", "expired_at": "2026-11-15", "name": "libstdc++", "version": "14.2.0-r6"},
	]
}
