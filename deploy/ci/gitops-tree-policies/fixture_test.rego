# The input the tests of the policies change one thing of: a tree of svp-gitops as deploy/ci/gitops-check.sh gives it
# (see lib.rego), shaped as the real one, that passes every policy, with the helpers that change it.
package gitops.fixture_test

envs := ["prd", "stg"]

services := ["gateway", "user-service", "video-service", "engagement-service", "feed-service", "media-worker", "web"]

six := [svc | some svc in services; svc != "web"]

cfg := {"environments": envs, "services": services}

revision := "0b4c089951cf29976dc675a9be5e01201469435c"

sha := "75a5cdbf3f89b2c26b2631c4ae9d1a7767146ee34eb82ea3e27cca6e373f72cc"

digest := "sha256:4f5c048eb90e6728ee82073bc7b0c422ca2111fb45471e58d92e70dc54942c87"

backend := {
	"name": "backend",
	"imagePrefix": "ghcr.io/anhnvcoder/svp-backend/",
	"services": six,
	"promoter": "svp-gitops-promoter",
}

web := {
	"name": "web",
	"imagePrefix": "ghcr.io/anhnvcoder/svp-frontend/",
	"services": ["web"],
	"promoter": "svp-web-promoter",
}

# The two sources a table kept after the repositories were renamed, without promoter: an environment may still pin it.
retired := [
	{"name": "oldbackend", "imagePrefix": "ghcr.io/anhnvcoder/short-video-platform/", "services": six},
	{"name": "oldweb", "imagePrefix": "ghcr.io/anhnvcoder/svp-web/", "services": ["web"]},
]

table := [backend, web]

repository("web") := "ghcr.io/anhnvcoder/svp-frontend/web"

repository(svc) := $"ghcr.io/anhnvcoder/svp-backend/{svc}" if svc != "web"

charts_text := $"# The commit of the code repository whose charts this environment runs.\nrevision: {revision}\npodSecurityVersion: v1.36\ncollectorConfigSha256: {sha}\n"

# image_text(repo): an image file as the promote writes it, comments included.
image_text(repo) := $"# The release image, nothing else.\nimage:\n  repository: {repo}\n  tag: \"0b4c089951cf\"\n  digest: \"{digest}\"\n"

components := {
	"components": [
		{"name": "cert-manager", "namespace": "cert-manager", "repo": "https://charts.jetstack.io", "chart": "cert-manager", "version": "v1.0.0", "values": "base/cert-manager.yaml"},
		{"name": "external-secrets", "namespace": "external-secrets", "repo": "https://charts.external-secrets.io", "chart": "external-secrets", "version": "1.0.0", "values": "base/external-secrets.yaml"},
		{"name": "aws-load-balancer-controller", "namespace": "kube-system", "repo": "https://aws.github.io/eks-charts", "chart": "aws-load-balancer-controller", "version": "1.0.0", "platforms": ["eks"]},
		{"name": "cloudnative-pg", "namespace": "cnpg-system", "repo": "https://cloudnative-pg.github.io/charts", "chart": "cloudnative-pg", "version": "0.1.0", "platforms": ["k3d"]},
		{"name": "keda", "namespace": "keda", "repo": "https://kedacore.github.io/charts", "chart": "keda", "version": "2.0.0"},
		{"name": "svp-policy", "namespace": "kyverno", "path": "deploy/helm/svp-policy"},
		{"name": "loki", "namespace": "observability", "repo": "https://grafana.github.io/helm-charts", "chart": "loki", "version": "6.0.0", "values": "base/loki.yaml"},
		{"name": "gateway", "namespace": "svp", "path": "deploy/helm/svp-service", "values": "base/services/gateway.yaml"},
		{"name": "web", "namespace": "svp", "path": "deploy/helm/svp-service", "values": "base/services/web.yaml"},
	],
	"platforms": {"k3d": {"envs": ["stg"], "localHosts": true}, "eks": {"envs": ["stg", "prd"]}},
}

bootstrap := {"repo": "https://argoproj.github.io/argo-helm", "chart": "argo-cd", "version": "9.0.0", "values": "base/argo-cd.yaml"}

dir := {"type": "dir"}

file(text) := {"type": "file", "text": text}

tree := object.union_n([
	{
		"argocd": dir,
		"argocd/apps": dir,
		"argocd/apps/Chart.yaml": file("apiVersion: v2\nname: svp-root\nversion: 0.1.0\n"),
		"argocd/apps/values.yaml": file("# The root's values.\ntargetRevision: refs/heads/main\n"),
		"argocd/apps/templates": dir,
		"argocd/apps/templates/applications.yaml": file("{{- range .Values.components }}{{- end }}\n"),
		"argocd/apps/components.json": file(json.marshal(components)),
		"argocd/apps/files": dir,
		"argocd/apps/files/envs": {"type": "dir", "link": "../../../envs"},
		"argocd/apps/files/platforms": {"type": "dir", "link": "../../../platforms"},
		"argocd/project.yaml": file("kind: AppProject\n"),
		"argocd/bootstrap.json": file(json.marshal(bootstrap)),
		"base": dir,
		"base/argo-cd.yaml": file("server:\n  replicas: 1\n"),
		"base/loki.yaml": file("loki:\n  auth_enabled: false\n"),
		"base/services": dir,
		"base/services/gateway.yaml": file("canary:\n  steps: []\n"),
		"envs": dir,
		"platforms": dir,
		"platforms/README.md": file("# Platforms\n"),
		"platforms/k3d": dir,
		"platforms/k3d/README.md": file("# k3d\n"),
		"platforms/eks": dir,
		"platforms/eks/gateway.values.tpl": file("serviceAccount:\n  annotations: {}\n"),
		"platforms/eks/loki.yaml": file("# Loki on S3.\nloki:\n  storage:\n    type: s3\n"),
		"platforms/eks/aws-load-balancer-controller.values.tpl": file("clusterName: x\n"),
	},
	{path: entry |
		some env in envs
		some [name, entry] in [
			["", dir],
			["/charts.yaml", file(charts_text)],
			["/gateway.yaml", file("replicas: 2\n")],
			["/images", dir],
		]
		path := $"envs/{env}{name}"
	},
	{path: file(image_text(repository(svc))) |
		some env in envs
		some svc in services
		path := $"envs/{env}/images/{svc}.yaml"
	},
])

# tree_input: what gitops-check.sh gives for the tree, both environments on main at revision.
tree_input := {
	"worktree": false,
	"tree": tree,
	"charts": {env: {"revision": revision, "podSecurityVersion": "v1.36", "collectorConfigSha256": sha} | some env in envs},
	"sources": {env: {"revision": revision, "sources": table} | some env in envs},
}

# with_file(given, path, text): given with the file path holding text.
with_file(given, path, text) := object.union(given, {"tree": {path: file(text)}})

# with_entry(given, path, entry): given with the entry path of the tree.
with_entry(given, path, entry) := object.union(given, {"tree": {path: entry}})

# without(given, path): given without the entry path of the tree and what lies under it.
without(given, path) := object.union(object.remove(given, ["tree"]), {"tree": {p: e |
	some p, e in given.tree
	p != path
	not startswith(p, $"{path}/")
}})

# with_components(given, doc): given with argocd/apps/components.json holding doc.
with_components(given, doc) := with_file(given, "argocd/apps/components.json", json.marshal(doc))

# with_component(given, name, fields): given with component name of components.json merged with fields.
with_component(given, name, fields) := with_components(given, object.union(components, {"components": [merged(c, name, fields) |
	some c in components.components
]}))

merged(c, name, fields) := object.union(c, fields) if c.name == name

merged(c, name, _) := c if c.name != name

# pull_request(given, author, sender, changes): given for a pull request of author, whose event sender caused, changing
# changes ([status, path] each).
pull_request(given, author, sender, changes) := object.union(given, {"pull_request": {
	"author": author,
	"sender": sender,
	"changes": [{"status": s, "path": p} | some [s, p] in changes],
}})

says(msgs, want) if {
	some m in msgs
	contains(m, want)
}
