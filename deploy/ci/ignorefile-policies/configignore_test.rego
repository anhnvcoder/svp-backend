# Tests of configignore.rego (make conftest-verify). Today is fixed at 2026-11-05: the limit is 2027-02-03.
package configignore_test

import data.configignore

today := {"today": "2026-11-05", "live": true}

file := "deploy/ci/trivy-config-ignore.yaml"

# deny(text): the messages of the rules on deploy/ci/trivy-config-ignore.yaml holding text.
deny(text) := msgs if {
	msgs := configignore.deny with input as [{"path": file, "contents": yaml.unmarshal(text)}]
		with data.scan_gate as today
}

# entry(id, path, statement, expired_at): a file of one entry with one path.
entry(id, path, statement, expired_at) := $"misconfigurations:\n  - id: {id}\n    paths:\n      - {path}\n    statement: {statement}\n    expired_at: {expired_at}\n"

says(msgs, want) if {
	some m in msgs
	contains(m, want)
}

test_an_entry_passes if count(deny(entry("DS-0026", "deploy/docker/service.Dockerfile", "a reason", "2027-01-22"))) == 0

test_a_folded_statement_and_several_paths_pass if count(deny(concat("", [
	"misconfigurations:\n  - id: KSV-0048\n    paths:\n      - deploy/a.yaml\n      - deploy/b.yaml\n",
	"    statement: >-\n      a reason\n      on two lines\n    expired_at: 2027-02-03\n",
]))) == 0

test_an_entry_for_more_than_90_days if says(
	deny(entry("DS-0026", "Dockerfile", "a reason", "2027-02-04")),
	"deploy/ci/trivy-config-ignore.yaml: entry DS-0026 expires 2027-02-04, more than 90 days from today (2027-02-03)",
)

test_an_entry_without_expired_at if {
	says(
		deny("misconfigurations:\n  - id: DS-0026\n    paths:\n      - Dockerfile\n    statement: a reason\n"),
		"entry DS-0026 has no expired_at yyyy-mm-dd",
	)
	says(deny(entry("DS-0026", "Dockerfile", "a reason", "'2027-1-2'")), "entry DS-0026 has no expired_at yyyy-mm-dd")
}

test_an_id_that_is_no_check_id if {
	every id in ["ds-0026", "DS0026", "17", "'*'"] {
		says(deny(entry(id, "Dockerfile", "a reason", "2027-01-22")), "id is not a check id such as DS-0026 or KSV-0048")
	}
}

test_an_entry_without_paths if {
	says(
		deny("misconfigurations:\n  - id: DS-0026\n    statement: a reason\n    expired_at: 2027-01-22\n"),
		"entry DS-0026 has no paths (an id is never ignored for the whole repository)",
	)
	says(
		deny("misconfigurations:\n  - id: DS-0026\n    paths: []\n    statement: a reason\n    expired_at: 2027-01-22\n"),
		"entry DS-0026 has no paths",
	)
}

# A path names one file: no pattern, no . or .. segment.
test_a_path_that_is_not_plain if {
	every path in ["'deploy/*.Dockerfile'", "'**'", "../Dockerfile", "./Dockerfile", "deploy/../Dockerfile", "deploy/.", "'a b'", "17"] {
		says(deny(entry("DS-0026", path, "a reason", "2027-01-22")), "is not a plain relative path; name each file, no pattern")
	}
}

test_an_entry_without_a_statement if {
	every statement in ["''", "null", "'  '", ">-\n      \n"] {
		says(deny(entry("DS-0026", "Dockerfile", statement, "2027-01-22")), "entry DS-0026 has no statement (the reason it is ignored)")
	}
}

test_another_key if {
	says(
		deny(concat("", [entry("DS-0026", "Dockerfile", "a reason", "2027-01-22"), "    severity: LOW\n"])),
		"entry DS-0026: unexpected key severity (only id, paths, statement, expired_at)",
	)
	says(
		deny(concat("", [entry("DS-0026", "Dockerfile", "a reason", "2027-01-22"), "vulnerabilities: []\n"])),
		"deploy/ci/trivy-config-ignore.yaml: only misconfigurations may be ignored here: vulnerabilities",
	)
}

test_a_file_of_another_shape if {
	says(deny("- id: DS-0026\n"), "the file must be a mapping of the one key misconfigurations")
	says(deny("misconfigurations:\n"), "misconfigurations must be a list")
	says(deny("misconfigurations:\n  - DS-0026\n"), "entry #1 is not a mapping")
}
