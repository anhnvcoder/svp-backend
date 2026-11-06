# Helpers of the policies on a tree of svp-gitops (packages gitops.*); gitops-check.sh builds their one JSON input.
# Input keys: worktree, tree, charts, sources, pull_request; data.gitops_check holds environments and services.
# Design notes: docs/reference/ci.md.
package gitops

environments := data.gitops_check.environments

services := data.gitops_check.services

# The release source whose repository holds the charts: its bot also promotes charts.yaml and the whole set of prd.
chart_source := "backend"

# The chart of the seven releases.
service_chart := "deploy/helm/svp-service"

is_file(path) if input.tree[path].type == "file"

is_dir(path) if input.tree[path].type == "dir"

links_to(path, target) if input.tree[path].link == target

text(path) := input.tree[path].text

# lines(path): the lines of file path, as sed and awk read them.
lines(path) := split(text(path), "\n")

# names(dir): the names of the entries directly inside dir, dot files included (ls -A).
names(dir) := {name |
	some path, _ in input.tree
	startswith(path, $"{dir}/")
	name := trim_prefix(path, $"{dir}/")
	not contains(name, "/")
}

# visible(dir): the names the glob * of the shell gives in dir (no dot files).
visible(dir) := {name | some name in names(dir); not startswith(name, ".")}

# folders(dir): the folders the glob */ of the shell gives in dir, sorted and joined by spaces, as messages list them.
folders(dir) := concat(" ", sort([name | some name in visible(dir); is_dir($"{dir}/{name}")]))

# yaml_map(path): file path as YAML reads it when it is a mapping, an empty one for a file of comments alone; undefined
# for a file that is no YAML or holds something else.
yaml_map(path) := doc if {
	yaml.is_valid(text(path))
	doc := yaml.unmarshal(text(path))
	is_object(doc)
}

yaml_map(path) := {} if {
	yaml.is_valid(text(path))
	yaml.unmarshal(text(path)) == null
}

# overlay_keys(values): the keys of a release's values that only envs/<env>/images/ (image) and the base (canary,
# httpRoute.name, mirrored by canaryRoute of components.json) may set, those values sets, joined by ", ".
overlay_keys(values) := concat(", ", [key |
	some key in ["image", "canary", "httpRoute.name"]
	sets(values, key)
])

sets(values, "image") if "image" in object.keys(values)

sets(values, "canary") if "canary" in object.keys(values)

sets(values, "httpRoute.name") if {
	is_object(values.httpRoute)
	"name" in object.keys(values.httpRoute)
}

components_file := "argocd/apps/components.json"

components_doc := json.unmarshal(text(components_file)) if json.is_valid(text(components_file))

components := [c | some c in components_doc.components; is_object(c)]

component(name) := c if {
	some c in components
	c.name == name
}

# runs_on(name, platform): component name runs on platform: its platforms lists it, or it has no platforms.
runs_on(name, _) if {
	c := component(name)
	not "platforms" in object.keys(c)
}

runs_on(name, platform) if {
	is_array(component(name).platforms)
	platform in component(name).platforms
}
