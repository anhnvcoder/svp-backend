# The layout of the tree: the files the root chart argocd/apps and the bootstrap read, and the settings of those files
# that no render shows.
#   - argocd/apps/Chart.yaml, values.yaml, templates/applications.yaml, components.json, argocd/project.yaml and
#     argocd/bootstrap.json are files; argocd/apps/files/envs is a symbolic link to ../../../envs, through which the root
#     chart reads envs/.
#   - components.json is JSON with a list of components, external-secrets among them (step 3 of the check validates
#     the External Secrets of chart svp-cluster against its CRDs); component svp-policy names no values file, since the
#     release checks read its settings from the chart's values and envs/<env>/svp-policy.yaml alone.
#   - argocd/bootstrap.json installs chart argo-cd of https://argoproj.github.io/argo-helm with a values file of the tree.
#   - argocd/apps/values.yaml is a YAML map that sets no value cluster (an empty map at most): the bootstrap alone sets
#     it, from the values of the session (the infrastructure repository's output cluster_values), which never go to git.
package gitops.layout

import data.gitops

required := [
	"argocd/apps/Chart.yaml",
	"argocd/apps/values.yaml",
	"argocd/apps/templates/applications.yaml",
	gitops.components_file,
	"argocd/project.yaml",
	"argocd/bootstrap.json",
]

deny contains sprintf("%s is missing", [path]) if {
	some path in required
	not gitops.is_file(path)
}

deny contains "argocd/apps/files/envs must be a symlink to ../../../envs, through which the root chart reads envs/" if {
	not gitops.links_to("argocd/apps/files/envs", "../../../envs")
}

deny contains sprintf("%s cannot be read: it is no JSON", [gitops.components_file]) if {
	gitops.is_file(gitops.components_file)
	not json.is_valid(gitops.text(gitops.components_file))
}

deny contains sprintf("%s lists no component", [gitops.components_file]) if {
	gitops.components_doc
	not listed
}

listed if {
	is_array(gitops.components_doc.components)
	count(gitops.components_doc.components) > 0
}

deny contains sprintf("no component external-secrets in %s", [gitops.components_file]) if {
	listed
	not gitops.component("external-secrets")
}

deny contains msg if {
	"values" in object.keys(gitops.component("svp-policy"))
	msg := "component svp-policy names a values file: its settings are the chart's values and envs/<env>/svp-policy.yaml, the only ones the release checks read"
}

bootstrap_file := "argocd/bootstrap.json"

bootstrap := json.unmarshal(gitops.text(bootstrap_file)) if json.is_valid(gitops.text(bootstrap_file))

deny contains "argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm" if {
	gitops.is_file(bootstrap_file)
	not installs_argo_cd
}

installs_argo_cd if {
	bootstrap.repo == "https://argoproj.github.io/argo-helm"
	bootstrap.chart == "argo-cd"
}

deny contains sprintf("argocd/bootstrap.json: values file %v is missing", [values]) if {
	installs_argo_cd
	values := object.get(bootstrap, "values", null)
	not values_file(values)
}

values_file(v) if {
	is_string(v)
	gitops.is_file(v)
}

root_values := "argocd/apps/values.yaml"

deny contains sprintf("%s is no YAML map", [root_values]) if {
	gitops.is_file(root_values)
	not gitops.yaml_map(root_values)
}

deny contains msg if {
	doc := gitops.yaml_map(root_values)
	not object.get(doc, "cluster", null) in [null, false, {}]
	msg := sprintf(
		"%s sets cluster: the bootstrap alone sets it, from the values of the session, which never go to git (an empty map at most)",
		[root_values],
	)
}
