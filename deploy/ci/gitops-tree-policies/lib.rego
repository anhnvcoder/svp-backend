# Helpers of the policies on a tree of the deployment repository svp-gitops (packages gitops.layout, gitops.envs,
# gitops.platforms, gitops.author). deploy/ci/gitops-check.sh runs them with conftest test on one JSON document it
# builds from the tree, the code repository and the pull request (step 1 of the check):
#   worktree      true for gitops-check.sh --worktree, where the working tree of the code repository stands for the
#                 revision of every environment, so the revision and the values charts.yaml derives from it are not
#                 checked (svp-gitops's own check does)
#   tree          every entry of the tree but .git, by its path from the top: type, what the path resolves to (file, dir
#                 or other, as test -f and test -d of the shell see it); link, the target of a symbolic link; text, the
#                 contents of a file
#   charts        by environment, what the commit its envs/<env>/charts.yaml pins gives: revision, podSecurityVersion
#                 (of deploy/helm/svp-cluster/values.yaml there) and collectorConfigSha256 (the sha256 of
#                 deploy/observability/otelcol/k8s-config.yaml there); an environment whose revision is no commit on
#                 main of the code repository is left out, and the script names why
#   sources       by environment, revision (empty with worktree) and sources, the table of release sources
#                 (deploy/helm/svp-policy/files/sources.json) of the code repository at that revision, of its working
#                 tree with worktree; left out when it cannot be read, and the script names why
#   pull_request  only for a pull request: author and sender (logins: who opened it, who caused the event checked), and
#                 for a bot's, changes: [{status, path}], the files git diff --name-status --no-renames lists from its base
# data.gitops_check: environments (["prd", "stg"]) and services (the seven services with a release image).
# make conftest-verify runs the tests beside them (*_test.rego).
package gitops

environments := data.gitops_check.environments

services := data.gitops_check.services

# The release source whose repository holds the charts: its bot also promotes charts.yaml and the whole set of prd.
chart_source := "backend"

# The chart of the seven releases.
service_chart := "deploy/helm/svp-service"

is_file(path) if input.tree[path].type == "file"

is_dir(path) if input.tree[path].type == "dir"

# links_to(path, target): path is a symbolic link to target.
links_to(path, target) if input.tree[path].link == target

text(path) := input.tree[path].text

# lines(path): the lines of file path, as sed and awk read them.
lines(path) := split(text(path), "\n")

# names(dir): the names of the entries directly inside dir, dot files included (ls -A).
names(dir) := {name |
	some path, _ in input.tree
	startswith(path, concat("", [dir, "/"]))
	name := trim_prefix(path, concat("", [dir, "/"]))
	not contains(name, "/")
}

# visible(dir): the names the glob * of the shell gives in dir (no dot files).
visible(dir) := {name | some name in names(dir); not startswith(name, ".")}

# folders(dir): the folders the glob */ of the shell gives in dir, sorted and joined by spaces, as messages list them.
folders(dir) := concat(" ", sort([name | some name in visible(dir); is_dir(concat("/", [dir, name]))]))

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

# components_doc: argocd/apps/components.json, when it is JSON.
components_doc := json.unmarshal(text(components_file)) if json.is_valid(text(components_file))

# components: its list of components (each a map with a name).
components := [c | some c in components_doc.components; is_object(c)]

# component(name): the component named name.
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
