# Tests of platforms.rego (make conftest-verify), each on the fixture with one thing changed.
package gitops.platforms_test

import data.gitops.fixture_test as fx
import data.gitops.platforms

deny(given) := msgs if {
	msgs := platforms.deny with input as given with data.gitops_check as fx.cfg
}

# with_platforms(map): the fixture with key platforms of components.json holding map.
with_platforms(map) := fx.with_components(fx.tree_input, object.union(object.remove(fx.components, ["platforms"]), {"platforms": map}))

# with_platform(name, value): the fixture with platform name of the map holding value.
with_platform(name, value) := with_platforms(object.union(fx.components.platforms, {name: value}))

must_map(platform) := concat("", [
	$"argocd/apps/components.json: platforms: {platform} must each map a name of ",
	$"lowercase letters and digits to \{envs: environments of prd stg, each once; localHosts: true or false, optional}",
])

file_rule := "a file of a platform is README.md, <name>.yaml or <name>.values.tpl, <name> a component of components.json"

test_the_fixture_passes if count(deny(fx.tree_input)) == 0

test_no_key_platforms if fx.says(
	deny(fx.with_components(fx.tree_input, object.remove(fx.components, ["platforms"]))),
	"argocd/apps/components.json: has no key platforms, a map of each platform to {envs, localHosts}",
)

test_an_empty_map if fx.says(deny(with_platforms({})), "argocd/apps/components.json: has no key platforms")

test_a_map_that_is_a_list if fx.says(deny(with_platforms(["k3d", "eks"])), "argocd/apps/components.json: has no key platforms")

test_an_environment_on_no_platform if fx.says(
	deny(with_platforms({"k3d": {"envs": ["stg"], "localHosts": true}, "eks": {"envs": ["stg"]}})),
	"argocd/apps/components.json: platforms: no platform runs prd",
)

test_an_unknown_environment if fx.says(deny(with_platform("eks", {"envs": ["stg", "prd", "qa"]})), must_map("eks"))

test_an_environment_twice if fx.says(deny(with_platform("eks", {"envs": ["stg", "prd", "prd"]})), must_map("eks"))

test_no_environment if fx.says(deny(with_platform("eks", {"envs": []})), must_map("eks"))

test_a_local_hosts_that_is_no_boolean if fx.says(deny(with_platform("k3d", {"envs": ["stg"], "localHosts": "yes"})), must_map("k3d"))

test_a_key_besides_envs_and_local_hosts if fx.says(
	deny(with_platform("eks", {"envs": ["stg", "prd"], "region": "ap-southeast-1"})),
	must_map("eks"),
)

test_a_platform_that_is_no_map if fx.says(deny(with_platform("k3d", "x")), must_map("k3d"))

test_envs_that_is_no_list if fx.says(deny(with_platform("k3d", {"envs": "stg"})), must_map("k3d"))

test_a_name_that_is_not_lowercase if fx.says(deny(with_platform("Aks", {"envs": ["stg"]})), must_map("Aks"))

test_two_bad_platforms_are_named_together if fx.says(
	deny(with_platforms({"k3d": "x", "eks": {"envs": "prd"}})),
	must_map("eks k3d"),
)

test_a_platform_of_the_map_without_its_folder if fx.says(
	deny(with_platform("aks", {"envs": ["stg"]})),
	"platforms/ holds 'eks k3d': the platforms are exactly those of key platforms of components.json, 'aks eks k3d'",
)

test_a_tree_without_platforms if fx.says(
	deny(fx.without(fx.tree_input, "platforms")),
	"platforms/ is missing: the tree is from before the platform layer, which the root chart and this check read",
)

test_an_unknown_platform if fx.says(
	deny(fx.with_file(fx.with_entry(fx.tree_input, "platforms/aks", fx.dir), "platforms/aks/README.md", "# another platform\n")),
	"platforms/ holds 'aks eks k3d': the platforms are exactly those of key platforms of components.json, 'eks k3d'",
)

test_files_platforms_that_is_no_link if fx.says(
	deny(fx.with_entry(fx.without(fx.tree_input, "argocd/apps/files/platforms"), "argocd/apps/files/platforms", fx.dir)),
	"argocd/apps/files/platforms must be a symlink to ../../../platforms",
)

test_a_file_beside_the_folders_of_platforms if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/gateway.yaml", "replicas: 2\n")),
	"platforms/gateway.yaml: platforms/ holds a folder per platform (and README.md), the root reads nothing else there",
)

test_a_component_on_an_unknown_platform if fx.says(
	deny(fx.with_component(fx.tree_input, "keda", {"platforms": ["aks"]})),
	"components.json: platforms of keda must list platforms of 'eks k3d', each once (no platforms: every platform)",
)

test_a_component_on_a_platform_twice if fx.says(
	deny(fx.with_component(fx.tree_input, "keda", {"platforms": ["eks", "eks"]})),
	"components.json: platforms of keda must list platforms of 'eks k3d'",
)

test_a_component_on_no_platform if fx.says(
	deny(fx.with_component(fx.tree_input, "keda", {"platforms": []})),
	"components.json: platforms of keda must list platforms of 'eks k3d'",
)

test_platforms_of_a_component_that_is_no_list if fx.says(
	deny(fx.with_component(fx.tree_input, "keda", {"platforms": "eks"})),
	"components.json: platforms of keda must list platforms of 'eks k3d'",
)

test_a_file_naming_no_component if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/nope.yaml", "replicas: 2\n")),
	$"platforms/eks/nope.yaml: {file_rule}",
)

test_a_template_of_argo_cds_values if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/argo-cd.values.tpl", "notifications:\n  enabled: true\n")),
	$"platforms/eks/argo-cd.values.tpl: {file_rule}",
)

test_a_file_of_another_extension if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yml", "loki: {}\n")),
	$"platforms/eks/loki.yml: {file_rule}",
)

test_a_folder_inside_a_platform if fx.says(
	deny(fx.with_entry(fx.tree_input, "platforms/eks/loki.yaml", fx.dir)),
	$"platforms/eks/loki.yaml: {file_rule}",
)

test_argo_cds_values_of_a_platform_pass if count(deny(fx.with_file(
	fx.tree_input,
	"platforms/eks/argo-cd.yaml", "notifications:\n  enabled: true\n",
))) == 0

test_argo_cds_values_of_a_platform_set_cluster if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/argo-cd.yaml", "cluster:\n  name: svp-stg\n")),
	"platforms/eks/argo-cd.yaml sets cluster: what depends on the cluster reaches a component through platforms/<platform>/argo-cd.values.tpl",
)

test_a_file_of_k3d_for_a_component_of_eks_alone if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/k3d/aws-load-balancer-controller.yaml", "replicas: 2\n")),
	"platforms/k3d/aws-load-balancer-controller.yaml: component aws-load-balancer-controller does not run on k3d (its platforms in components.json)",
)

test_a_template_of_eks_for_a_component_of_k3d_alone if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/cloudnative-pg.values.tpl", "replicas: 2\n")),
	"platforms/eks/cloudnative-pg.values.tpl: component cloudnative-pg does not run on eks",
)

test_a_file_of_a_platform_sets_cluster if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yaml", "cluster:\n  vpcId: vpc-00000000000000000\n")),
	"platforms/eks/loki.yaml sets cluster: what depends on the cluster reaches a component through platforms/<platform>/loki.values.tpl from the root's value cluster, which the bootstrap alone sets",
)

test_a_file_of_a_platform_sets_an_empty_cluster if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yaml", "cluster: null\n")),
	"platforms/eks/loki.yaml sets cluster",
)

test_a_file_of_a_platform_that_is_no_map if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yaml", "- loki\n")),
	"platforms/eks/loki.yaml is no YAML map",
)

test_a_file_of_a_platform_that_is_no_yaml if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yaml", "loki: [\n")),
	"platforms/eks/loki.yaml is no YAML map",
)

test_a_file_of_comments_alone_passes if count(deny(fx.with_file(fx.tree_input, "platforms/eks/loki.yaml", "# nothing yet\n"))) == 0

test_a_file_of_an_unknown_platform_is_held_to_the_rules_too if fx.says(
	deny(fx.with_file(fx.with_entry(fx.tree_input, "platforms/aks", fx.dir), "platforms/aks/loki.yaml", "cluster: {}\n")),
	"platforms/aks/loki.yaml sets cluster",
)

test_a_file_of_a_platform_that_sets_the_image_of_a_release if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/gateway.yaml", "image:\n  tag: \"000000000000\"\n")),
	"platforms/eks/gateway.yaml sets image: a release's image is envs/<env>/images/gateway.yaml, and every platform runs the base's canary",
)

test_a_file_of_a_platform_that_sets_canary_and_the_routes_name if fx.says(
	deny(fx.with_file(fx.tree_input, "platforms/eks/web.yaml", "canary: {}\nhttpRoute:\n  name: web\n")),
	"platforms/eks/web.yaml sets canary, httpRoute.name: a release's image is envs/<env>/images/web.yaml",
)

test_a_file_of_a_platform_that_sets_other_keys_of_the_route_passes if count(deny(fx.with_file(
	fx.tree_input,
	"platforms/eks/gateway.yaml", "httpRoute:\n  hostnames: [api.example.com]\n",
))) == 0

test_a_file_of_a_platform_may_set_the_image_of_another_chart if count(deny(fx.with_file(
	fx.tree_input,
	"platforms/eks/loki.yaml", "image:\n  tag: \"3.0.0\"\n",
))) == 0
