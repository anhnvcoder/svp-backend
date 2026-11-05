# Tests of layout.rego (make conftest-verify), each on the fixture with one thing changed.
package gitops.layout_test

import data.gitops.fixture_test as fx
import data.gitops.layout

deny(given) := msgs if {
	msgs := layout.deny with input as given with data.gitops_check as fx.cfg
}

test_the_fixture_passes if count(deny(fx.tree_input)) == 0

test_each_file_of_the_root_and_the_bootstrap_is_required if {
	every path in layout.required {
		fx.says(deny(fx.without(fx.tree_input, path)), $"{path} is missing")
	}
}

test_a_folder_in_place_of_a_file_of_the_root if fx.says(
	deny(fx.with_entry(fx.without(fx.tree_input, "argocd/project.yaml"), "argocd/project.yaml", fx.dir)),
	"argocd/project.yaml is missing",
)

test_files_envs_that_is_no_link if fx.says(
	deny(fx.with_entry(fx.without(fx.tree_input, "argocd/apps/files/envs"), "argocd/apps/files/envs", fx.dir)),
	"argocd/apps/files/envs must be a symlink to ../../../envs",
)

test_files_envs_linked_elsewhere if fx.says(
	deny(fx.with_entry(fx.tree_input, "argocd/apps/files/envs", {"type": "dir", "link": "../../envs"})),
	"argocd/apps/files/envs must be a symlink to ../../../envs",
)

test_components_that_is_no_json if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/components.json", "{\"components\": [")),
	"argocd/apps/components.json cannot be read: it is no JSON",
)

test_no_component if fx.says(
	deny(fx.with_components(fx.tree_input, object.union(fx.components, {"components": []}))),
	"argocd/apps/components.json lists no component",
)

test_components_that_is_false if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/components.json", "false")),
	"argocd/apps/components.json must be a JSON object",
)

test_components_that_is_null if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/components.json", "null")),
	"argocd/apps/components.json lists no component",
)

test_components_that_is_a_list if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/components.json", "[]")),
	"argocd/apps/components.json must be a JSON object",
)

test_components_that_is_no_list if fx.says(
	deny(fx.with_components(fx.tree_input, object.union(fx.components, {"components": {"name": "keda"}}))),
	"argocd/apps/components.json lists no component",
)

test_no_external_secrets if fx.says(
	deny(fx.with_components(fx.tree_input, object.union(fx.components, {"components": [c |
		some c in fx.components.components
		c.name != "external-secrets"
	]}))),
	"no component external-secrets in argocd/apps/components.json",
)

test_svp_policy_with_a_values_file if fx.says(
	deny(fx.with_component(fx.tree_input, "svp-policy", {"values": "base/svp-policy.yaml"})),
	"component svp-policy names a values file",
)

test_bootstrap_of_another_chart if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/bootstrap.json", json.marshal(object.union(fx.bootstrap, {"chart": "argocd"})))),
	"argocd/bootstrap.json must install chart argo-cd of https://argoproj.github.io/argo-helm",
)

test_bootstrap_that_is_no_json if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/bootstrap.json", "{")),
	"argocd/bootstrap.json must install chart argo-cd",
)

test_bootstrap_values_missing if fx.says(
	deny(fx.without(fx.tree_input, "base/argo-cd.yaml")),
	"argocd/bootstrap.json: values file base/argo-cd.yaml is missing",
)

test_bootstrap_without_values if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/bootstrap.json", json.marshal(object.remove(fx.bootstrap, ["values"])))),
	"argocd/bootstrap.json: values file null is missing",
)

test_the_roots_values_set_cluster if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/values.yaml", "targetRevision: refs/heads/main\ncluster:\n  name: svp-stg\n")),
	"argocd/apps/values.yaml sets cluster: the bootstrap alone sets it",
)

test_the_roots_values_set_an_empty_cluster if count(deny(fx.with_file(
	fx.tree_input,
	"argocd/apps/values.yaml", "targetRevision: refs/heads/main\ncluster: {}\n",
))) == 0

test_the_roots_values_that_are_no_map if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/values.yaml", "- targetRevision\n")),
	"argocd/apps/values.yaml is no YAML map",
)

test_the_roots_values_that_are_no_yaml if fx.says(
	deny(fx.with_file(fx.tree_input, "argocd/apps/values.yaml", "cluster: [\n")),
	"argocd/apps/values.yaml is no YAML map",
)

# The two-level root reads envs/ through its own link.
test_the_link_of_the_two_level_root_passes if count(deny(fx.with_entry(fx.tree_input, "argocd/root/files/envs", {"type": "dir", "link": "../../../envs"}))) == 0

# A link to a folder anywhere else hides its files from every rule: refused.
test_a_platform_that_is_a_link_to_a_folder if fx.says(
	deny(fx.with_entry(fx.tree_input, "platforms/eks", {"type": "dir", "link": "../base"})),
	"platforms/eks is a link to the folder ../base: write the files where they are",
)

test_an_environment_that_is_a_link_to_a_folder if fx.says(
	deny(fx.with_entry(fx.tree_input, "envs/stg/images", {"type": "dir", "link": "../prd/images"})),
	"envs/stg/images is a link to the folder ../prd/images",
)
