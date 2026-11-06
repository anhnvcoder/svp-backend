# Layout of a tree of svp-gitops: the files the root chart and the bootstrap read, and settings no render shows.
# Design notes: docs/reference/ci.md.
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

deny contains $"{path} is missing" if {
	some path in required
	not gitops.is_file(path)
}

# The shell that lists the tree does not follow a link to a folder: no rule would check what lies behind one.
# The links to a folder the root charts need are the only such links a tree may hold.
folder_links := {"argocd/apps/files/envs", "argocd/apps/files/platforms", "argocd/root/files/envs"}

deny contains msg if {
	some path, entry in input.tree
	entry.type == "dir"
	entry.link
	not path in folder_links
	msg := $"{path} is a link to the folder {entry.link}: write the files where they are, no rule of this check reads behind such a link"
}

deny contains "argocd/apps/files/envs must be a symlink to ../../../envs, through which the root chart reads envs/" if {
	not gitops.links_to("argocd/apps/files/envs", "../../../envs")
}

deny contains $"{gitops.components_file} cannot be read: it is no JSON" if {
	gitops.is_file(gitops.components_file)
	not json.is_valid(gitops.text(gitops.components_file))
}

# A JSON document that is no object (false, null, a list) leaves every rule that reads it undefined: a silent pass.
deny contains $"{gitops.components_file} must be a JSON object" if {
	json.is_valid(gitops.text(gitops.components_file))
	not is_object(gitops.components_doc)
}

deny contains $"{gitops.components_file} lists no component" if {
	json.is_valid(gitops.text(gitops.components_file))
	not listed
}

listed if {
	is_array(gitops.components_doc.components)
	count(gitops.components_doc.components) > 0
}

deny contains $"no component external-secrets in {gitops.components_file}" if {
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

deny contains $"argocd/bootstrap.json: values file {values} is missing" if {
	installs_argo_cd
	values := object.get(bootstrap, "values", null)
	not values_file(values)
}

values_file(v) if {
	is_string(v)
	gitops.is_file(v)
}

root_values := "argocd/apps/values.yaml"

deny contains $"{root_values} is no YAML map" if {
	gitops.is_file(root_values)
	not gitops.yaml_map(root_values)
}

deny contains msg if {
	doc := gitops.yaml_map(root_values)
	not object.get(doc, "cluster", null) in [null, false, {}]
	msg := $"{root_values} sets cluster: the bootstrap alone sets it, from the values of the session, which never go to git (an empty map at most)"
}
