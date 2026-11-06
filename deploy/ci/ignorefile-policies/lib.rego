# Helpers of the policies on the ignore files of the scan gate (packages trivyignore, grypeignore, configignore).
# Input: a list of {path, contents} from deploy/ci/scan-gate.sh (conftest --combine); data.scan_gate: today, live.
# Design notes: docs/reference/ci.md.
package ignorefiles

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

day(v) if {
	is_string(v)
	regex.match(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`, v)
}

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

text(v) if {
	is_string(v)
	trim_space(v) != ""
}

filled(v) if {
	is_array(v)
	count(v) > 0
}

# items(v): the items of v with their index, when v is a list; nothing otherwise (a mapping is not iterated).
items(v) := {i: x | some i, x in v} if is_array(v)

extra(obj, keys) := {k | some k, _ in obj; not k in keys}

# label(i, v): how a message names item i: v when it is a string (the item's id), its place in the list otherwise.
label(_, v) := v if is_string(v)

label(i, v) := $"#{i + 1}" if not is_string(v)
