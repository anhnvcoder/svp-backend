# Helpers of the policies on the ignore files of the scan gate (packages trivyignore, grypeignore, configignore).
# deploy/ci/scan-gate.sh runs them with conftest test --combine, so input is a list of {path, contents}, one per file
# passed, and gives data.scan_gate: today (yyyy-mm-dd, UTC) and live (true in job config, false in the image gates).
# make conftest-verify runs the tests beside them (*_test.rego).
package ignorefiles

# present(path): the file path is one of the inputs.
present(path) if {
	some d in input
	d.path == path
}

# contents(path): the contents of the file path as YAML reads it; undefined when the file is not an input.
contents(path) := d.contents if {
	some d in input
	d.path == path
}

# after(days): the day that many days after today (UTC), as yyyy-mm-dd.
after(days) := time.format([
	time.add_date(time.parse_ns("2006-01-02", data.scan_gate.today), 0, 0, days),
	"UTC", "2006-01-02",
])

# day(v): v is a date written yyyy-mm-dd.
day(v) if {
	is_string(v)
	regex.match(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`, v)
}

# expires_late(v, days): v is a date more than days days after today.
expires_late(v, days) if {
	day(v)
	v > after(days)
}

# expired(v): with data.scan_gate.live, v is a date trivy no longer applies the entry on (from that day on).
expired(v) if {
	data.scan_gate.live == true
	day(v)
	v <= data.scan_gate.today
}

# text(v): v is a string with more than blanks in it.
text(v) if {
	is_string(v)
	trim_space(v) != ""
}

# filled(v): v is a list with at least one item.
filled(v) if {
	is_array(v)
	count(v) > 0
}

# items(v): the items of v with their index, when v is a list; nothing otherwise (a mapping is not iterated).
items(v) := {i: x | some i, x in v} if is_array(v)

# extra(obj, keys): the keys of obj outside keys.
extra(obj, keys) := {k | some k, _ in obj; not k in keys}

# label(i, v): how a message names item i: v when it is a string (the item's id), its place in the list otherwise.
label(_, v) := v if is_string(v)

label(i, v) := sprintf("#%d", [i + 1]) if not is_string(v)
