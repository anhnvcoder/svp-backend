# Rules of deploy/ci/trivy-config-ignore.yaml, the misconfigurations make trivy-config leaves out:
#   - only the section misconfigurations, a list;
#   - each entry exactly id (a check id: DS-0026, KSV-0048), paths, statement (the reason, text; folded with >- or not)
#     and expired_at (yyyy-mm-dd) at most 90 days after today (UTC): a misconfiguration changes only when the
#     repository does, so it gets about 90 days, not the 30 of a vulnerability;
#   - paths: at least one, each a plain relative path of a file (letters, digits, ._/-; no pattern, no . or ..), so an
#     id is never left out for the whole repository. That each path is a file of the repository (not a directory,
#     which would cover a tree, not a file gone) deploy/ci/scan-gate.sh checks after these rules: Rego sees no files.
package configignore

import data.ignorefiles

file := "deploy/ci/trivy-config-ignore.yaml"

keys := {"id", "paths", "statement", "expired_at"}

doc := ignorefiles.contents(file)

list := ignorefiles.items(doc.misconfigurations) if is_object(doc)

entries[i] := e if {
	some i, e in list
	is_object(e)
}

name(i) := ignorefiles.label(i, object.get(entries[i], "id", null))

deny contains $"{file}: the file must be a mapping of the one key misconfigurations" if {
	ignorefiles.present(file)
	not is_object(doc)
}

deny contains $"{file}: only misconfigurations may be ignored here: {k}" if {
	is_object(doc)
	some k, _ in doc
	k != "misconfigurations"
}

deny contains $"{file}: misconfigurations must be a list" if {
	is_object(doc)
	not is_array(object.get(doc, "misconfigurations", null))
}

deny contains $"{file}: entry #{i + 1} is not a mapping" if {
	some i, e in list
	not is_object(e)
}

deny contains $"{file}: entry {name(i)}: unexpected key {k} (only id, paths, statement, expired_at)" if {
	some i, e in entries
	some k in ignorefiles.extra(e, keys)
}

deny contains $"{file}: entry {name(i)}: id is not a check id such as DS-0026 or KSV-0048" if {
	some i, e in entries
	not check_id(object.get(e, "id", null))
}

deny contains $"{file}: entry {name(i)} has no paths (an id is never ignored for the whole repository)" if {
	some i, e in entries
	not ignorefiles.filled(object.get(e, "paths", null))
}

deny contains msg if {
	some i, e in entries
	some p in ignorefiles.items(e.paths)
	not plain_path(p)
	msg := $"{file}: entry {name(i)}: path {p} is not a plain relative path; name each file, no pattern"
}

deny contains $"{file}: entry {name(i)} has no statement (the reason it is ignored)" if {
	some i, e in entries
	not ignorefiles.text(object.get(e, "statement", null))
}

deny contains $"{file}: entry {name(i)} has no expired_at yyyy-mm-dd" if {
	some i, e in entries
	not ignorefiles.day(object.get(e, "expired_at", null))
}

deny contains msg if {
	some i, e in entries
	ignorefiles.expires_late(e.expired_at, 90)
	msg := $"{file}: entry {name(i)} expires {e.expired_at}, more than 90 days from today ({ignorefiles.after(90)})"
}

check_id(v) if {
	is_string(v)
	regex.match(`^[A-Z]+-[0-9]+$`, v)
}

plain_path(p) if {
	is_string(p)
	regex.match(`^[A-Za-z0-9._/-]+$`, p)
	not regex.match(`(^|/)\.\.?(/|$)`, p)
}
