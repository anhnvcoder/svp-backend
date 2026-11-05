# Rules of .trivyignore.yaml, the vulnerabilities trivy leaves out of every image scan of the tree (trivy convert
# --ignorefile of deploy/ci/scan-gate.sh, the daily rescan):
#   - only the section vulnerabilities, a list (vulnerabilities: [] when nothing is excepted): the format also has
#     secrets, misconfigurations and licenses, and trivy would apply them, so a secret could be let through;
#   - each entry exactly id, statement (the reason, text), expired_at (yyyy-mm-dd) at most 30 days after today (UTC), so
#     no exception lives longer than 30 days without another reviewed change, and purls: the package versions it covers,
#     each pkg:<type>/<name>@<version> (a purl with no version is every version to trivy; the same id in another
#     package or version is still reported). No paths;
#   - live (job config): an entry trivy no longer applies (from its expired_at day on) breaks the rules too, since grype
#     reads no date and the rule .grype.yaml has for it would go on covering the match until the entry is renewed or
#     removed. The image gates leave an expired entry to trivy, which drops it.
# packages hands the purls to the rules of .grype.yaml (grypeignore.rego), each rule of which must be one of them.
package trivyignore

import data.ignorefiles

file := ".trivyignore.yaml"

keys := {"id", "statement", "expired_at", "purls"}

doc := ignorefiles.contents(file)

list := ignorefiles.items(doc.vulnerabilities) if is_object(doc)

entries[i] := e if {
	some i, e in list
	is_object(e)
}

name(i) := ignorefiles.label(i, object.get(entries[i], "id", null))

deny contains $"{file}: the file must be a mapping of the one key vulnerabilities" if {
	ignorefiles.present(file)
	not is_object(doc)
}

deny contains $"{file}: only vulnerabilities may be ignored, never secrets or anything else: {k}" if {
	is_object(doc)
	some k, _ in doc
	k != "vulnerabilities"
}

deny contains $"{file}: vulnerabilities must be a list (vulnerabilities: [] when nothing is excepted)" if {
	is_object(doc)
	not is_array(object.get(doc, "vulnerabilities", null))
}

deny contains $"{file}: entry #{i + 1} is not a mapping" if {
	some i, e in list
	not is_object(e)
}

deny contains $"{file}: entry {name(i)}: unexpected key {k} (only id, statement, expired_at, purls)" if {
	some i, e in entries
	some k in ignorefiles.extra(e, keys)
}

deny contains $"{file}: entry {name(i)} has no id" if {
	some i, e in entries
	not ignorefiles.text(object.get(e, "id", null))
}

deny contains $"{file}: entry {name(i)} has no statement (the reason it is ignored)" if {
	some i, e in entries
	not ignorefiles.text(object.get(e, "statement", null))
}

deny contains $"{file}: entry {name(i)} has no purls (the package versions it covers)" if {
	some i, e in entries
	not ignorefiles.filled(object.get(e, "purls", null))
}

deny contains $"{file}: entry {name(i)}: purl {p} is not pkg:<type>/<name>@<version>" if {
	some i, e in entries
	some p in ignorefiles.items(e.purls)
	not purl(p)
}

deny contains $"{file}: entry {name(i)} has no expired_at yyyy-mm-dd" if {
	some i, e in entries
	not ignorefiles.day(object.get(e, "expired_at", null))
}

deny contains msg if {
	some i, e in entries
	ignorefiles.expires_late(e.expired_at, 30)
	msg := $"{file}: entry {name(i)} expires {e.expired_at}, more than 30 days from today ({ignorefiles.after(30)})"
}

deny contains msg if {
	some i, e in entries
	ignorefiles.expired(e.expired_at)
	msg := $"{file}: entry {name(i)} expired on {e.expired_at}: renew it with a reason, or remove it (and its rule in .grype.yaml)"
}

purl(p) if {
	is_string(p)
	regex.match(`^pkg:[a-z]+/[^ @]+@[^ @]+$`, p)
}

distributions := {"apk", "deb", "rpm"}

# packages: one row per well-formed purl of an entry: the entry's id and expired_at, and the package as grype names it.
# A list, not a set: two entries for the same package version are two rows, and a rule matching both is refused.
packages := [object.union({"id": e.id, "expired_at": e.expired_at}, pkg(p)) |
	some e in entries
	some p in ignorefiles.items(e.purls)
	purl(p)
]

# pkg(p): name and version of the package of purl p as grype names it, both %-decoded (%40 is the @ of an npm scope),
# the qualifiers and subpath dropped: the name with its namespace (pkg:npm/%40scope/foo is @scope/foo,
# pkg:golang/golang.org/x/net is golang.org/x/net), except for a distribution's package, whose namespace is the
# distribution (pkg:apk/alpine/glib is glib). So a rule for foo or net never covers another package of that name.
pkg(p) := {"name": decode(name), "version": decode(version)} if {
	[_, type, path, version] := regex.find_all_string_submatch_n(`^pkg:([a-z]+)/([^@]*)@([^?#]*)`, p, 1)[0]
	name := grype_name(type, path)
}

grype_name(type, path) := regex.replace(path, `^.*/`, "") if type in distributions

grype_name(type, path) := path if not type in distributions

# decode(s): s with its %-escapes decoded; a + stays a + (urlquery.decode alone reads it as a blank).
decode(s) := urlquery.decode(replace(s, "+", "%2B"))
