# Tests of waves.rego (make conftest-verify): the fixture with the mesh components and a component pinned to Karpenter's
# nodes, each test changing one thing of it.
package gitops.waves_test

import data.gitops.fixture_test as fx
import data.gitops.platforms

deny(given) := msgs if {
	msgs := platforms.deny with input as given with data.gitops_check as fx.cfg
}

pin := "nodeAffinity:\n  requiredDuringSchedulingIgnoredDuringExecution:\n    nodeSelectorTerms:\n      - matchExpressions:\n          - {key: karpenter.sh/nodepool, operator: Exists}\n"

# indented: pin one level down, to sit under a parent key.
indented := trim_suffix(replace(pin, "\n", "\n  "), "  ")

mesh(name, wave) := {
	"name": name,
	"namespace": "istio-system",
	"wave": wave,
	"repo": "https://blob.istio.io/istio-release/charts",
	"chart": name,
	"version": "1.0.0",
	"values": $"base/{name}.yaml",
}

# components(w): the fixture's with the mesh and svp-cluster at the waves of w (name to wave).
components(w) := object.union(fx.components, {"components": array.concat(fx.components.components, [
	mesh("istiod", w.istiod),
	mesh("istio-cni", w["istio-cni"]),
	mesh("ztunnel", w.ztunnel),
	{"name": "svp-cluster", "namespace": "cert-manager", "wave": w["svp-cluster"], "path": "deploy/helm/svp-cluster"},
])})

one := {"istiod": 1, "istio-cni": 1, "ztunnel": 1, "svp-cluster": 1}

# with_mesh(w): the fixture with the mesh files, svp-cluster pinned to Karpenter's nodes, and the waves of w.
with_mesh(w) := object.union(fx.with_components(fx.tree_input, components(w)), {"tree": {
	"base/istiod.yaml": fx.file("taint:\n  enabled: true\n"),
	"base/istio-cni.yaml": fx.file("profile: ambient\n"),
	"base/ztunnel.yaml": fx.file("profile: ambient\n"),
	"platforms/eks/svp-cluster.yaml": fx.file(pin),
}})

mesh_input := with_mesh(one)

# patched(given, name, fields): given with component name of its components.json merged with fields.
patched(given, name, fields) := fx.with_components(given, object.union(doc, {"components": [fx.merged(c, name, fields) |
	some c in doc.components
]})) if doc := json.unmarshal(given.tree["argocd/apps/components.json"].text)

old := {"istiod": 3, "istio-cni": 4, "ztunnel": 4, "svp-cluster": 1}

test_the_mesh_in_the_wave_of_the_pinned_component_passes if count(deny(mesh_input)) == 0

test_the_old_waves_of_the_mesh_are_refused if fx.says(
	deny(with_mesh(old)),
	concat("", [
		"argocd/apps/components.json: svp-cluster (wave 1) is pinned to Karpenter's nodes, whose startup taint ",
		"cni.istio.io/not-ready istiod (wave 3) lifts once it runs: svp-cluster cannot become Healthy before, ",
		"so give it a wave of at least 3",
	]),
)

test_each_component_that_lifts_the_taint_is_named if {
	msgs := deny(with_mesh(old))
	fx.says(msgs, "istio-cni (wave 4) lifts")
	fx.says(msgs, "ztunnel (wave 4) lifts")
}

test_a_pinned_component_after_the_mesh_passes if count(deny(with_mesh(object.union(old, {"svp-cluster": 4})))) == 0

test_one_remover_in_a_later_wave_is_enough if fx.says(
	deny(with_mesh(object.union(one, {"ztunnel": 2}))),
	"svp-cluster (wave 1) is pinned to Karpenter's nodes, whose startup taint cni.istio.io/not-ready ztunnel (wave 2) lifts",
)

test_a_component_that_is_not_pinned_is_left_alone if count(deny(fx.with_file(with_mesh(old), "platforms/eks/svp-cluster.yaml", "replicas: 2\n"))) == 0

test_a_term_that_keeps_pods_off_karpenters_nodes_is_no_pin if count(deny(fx.with_file(
	with_mesh(old), "platforms/eks/svp-cluster.yaml",
	replace(pin, "operator: Exists", "operator: DoesNotExist"),
))) == 0

test_a_preferred_term_is_no_pin if count(deny(fx.with_file(
	with_mesh(old), "platforms/eks/svp-cluster.yaml",
	replace(pin, "requiredDuring", "preferredDuring"),
))) == 0

test_an_in_term_is_a_pin if fx.says(
	deny(fx.with_file(
		with_mesh(old), "platforms/eks/svp-cluster.yaml",
		replace(pin, "{key: karpenter.sh/nodepool, operator: Exists}", "{key: karpenter.sh/nodepool, operator: In, values: [default]}"),
	)),
	"svp-cluster (wave 1) is pinned",
)

test_a_pin_at_any_depth_of_the_values_is_found if fx.says(
	deny(fx.with_file(
		with_mesh(old), "platforms/eks/svp-cluster.yaml",
		$"envoy:\n  {indented}",
	)),
	"svp-cluster (wave 1) is pinned",
)

test_a_pin_in_a_file_of_base_counts_on_eks if fx.says(
	deny(fx.with_file(
		patched(with_mesh(old), "gateway", {"wave": 0}), "base/services/gateway.yaml",
		$"affinity:\n  {indented}",
	)),
	"gateway (wave 0) is pinned",
)

test_a_component_of_k3d_alone_is_not_checked if {
	given := fx.with_file(
		patched(with_mesh(old), "cloudnative-pg", {"wave": 0, "values": "base/cloudnative-pg.yaml"}),
		"base/cloudnative-pg.yaml", pin,
	)
	not fx.says(deny(given), "cloudnative-pg (wave 0) is pinned")
}

test_a_file_of_a_platform_other_than_eks_is_not_read if count(deny(fx.with_file(with_mesh(old), "platforms/k3d/gateway.yaml", pin))) == count(deny(with_mesh(old)))

test_a_template_that_is_valid_yaml_is_read if fx.says(
	deny(fx.with_file(fx.without(with_mesh(old), "platforms/eks/svp-cluster.yaml"), "platforms/eks/svp-cluster.values.tpl", pin)),
	"svp-cluster (wave 1) is pinned",
)

test_a_template_that_is_not_yaml_is_left_alone if count(deny(fx.with_file(
	fx.without(with_mesh(old), "platforms/eks/svp-cluster.yaml"),
	"platforms/eks/svp-cluster.values.tpl", "{{ .Values.pin }}: [\n",
))) == 0

test_a_taint_nothing_lifts_is_named if {
	given := fx.with_components(mesh_input, object.union(components(one), {"components": [c |
		some c in components(one).components
		c.name != "istio-cni"
	]}))
	fx.says(deny(given), concat("", [
		"argocd/apps/components.json: svp-cluster is pinned to Karpenter's nodes, whose startup taint ",
		"cni.istio.io/not-ready is never lifted: istio-cni is no component that runs on eks",
	]))
}

test_a_remover_that_runs_on_k3d_alone_lifts_nothing if fx.says(
	deny(patched(mesh_input, "ztunnel", {"platforms": ["k3d"]})),
	"ztunnel is no component that runs on eks",
)

test_istiod_without_taint_removal_lifts_nothing if fx.says(
	deny(fx.with_file(mesh_input, "base/istiod.yaml", "profile: ambient\n")),
	"istiod is no component that runs on eks with taint.enabled: true in its values",
)

test_the_overlay_of_eks_can_turn_taint_removal_off if fx.says(
	deny(fx.with_file(mesh_input, "platforms/eks/istiod.yaml", "taint:\n  enabled: false\n")),
	"istiod is no component that runs on eks with taint.enabled: true",
)

selector := "nodeSelector:\n  karpenter.sh/nodepool: default\n"

# overlaid(given, env, text): given with a platform file of svp-cluster that pins nothing and
# envs/<env>/svp-cluster.yaml of text.
overlaid(given, env, text) := fx.with_file(
	fx.with_file(given, "platforms/eks/svp-cluster.yaml", "replicas: 2\n"),
	$"envs/{env}/svp-cluster.yaml", text,
)

test_a_node_selector_on_the_nodepool_key_is_a_pin if fx.says(
	deny(fx.with_file(with_mesh(old), "platforms/eks/svp-cluster.yaml", selector)),
	"svp-cluster (wave 1) is pinned",
)

test_a_node_selector_at_any_depth_is_a_pin if fx.says(
	deny(fx.with_file(
		with_mesh(old), "platforms/eks/svp-cluster.yaml",
		"envoy:\n  pod:\n    nodeSelector:\n      karpenter.sh/nodepool: default\n",
	)),
	"svp-cluster (wave 1) is pinned",
)

test_a_node_selector_on_another_key_is_no_pin if count(deny(fx.with_file(with_mesh(old), "platforms/eks/svp-cluster.yaml", "nodeSelector:\n  kubernetes.io/arch: arm64\n"))) == 0

test_a_node_selector_pin_after_the_mesh_passes if count(deny(fx.with_file(with_mesh(one), "platforms/eks/svp-cluster.yaml", selector))) == 0

test_a_pin_of_the_overlay_of_an_env_is_named_with_the_env if {
	msgs := deny(overlaid(with_mesh(old), "stg", pin))
	fx.says(msgs, "svp-cluster (wave 1, env stg) is pinned")
	not fx.says(msgs, "env prd")
}

test_a_node_selector_in_the_overlay_of_an_env_is_a_pin if fx.says(
	deny(overlaid(with_mesh(old), "prd", selector)),
	"svp-cluster (wave 1, env prd) is pinned",
)

test_a_pin_of_the_overlay_of_an_env_after_the_mesh_passes if count(deny(overlaid(with_mesh(one), "stg", pin))) == 0

test_a_pin_of_the_platform_file_is_named_without_an_env if {
	msgs := deny(fx.with_file(with_mesh(old), "envs/stg/svp-cluster.yaml", pin))
	fx.says(msgs, "svp-cluster (wave 1) is pinned")
	not fx.says(msgs, "env stg")
}

test_an_overlay_that_does_not_pin_is_left_alone if count(deny(overlaid(with_mesh(old), "stg", "replicas: 3\n"))) == 0

test_an_overlay_of_an_env_the_platform_does_not_run_is_not_read if count(deny(overlaid(with_mesh(old), "dev", pin))) == 0

# istiod_overlay(env, enabled): mesh_input with envs/<env>/istiod.yaml setting taint.enabled.
istiod_overlay(env, enabled) := fx.with_file(mesh_input, $"envs/{env}/istiod.yaml", $"taint:\n  enabled: {enabled}\n")

test_an_env_overlay_that_turns_taint_removal_off_is_named_with_the_env if {
	msgs := deny(istiod_overlay("prd", "false"))
	fx.says(msgs, "istiod is no component that runs on eks with taint.enabled: true in its values (env prd)")
	not fx.says(msgs, "(env stg)")
}

test_an_env_overlay_that_turns_taint_removal_back_on_lifts if count(deny(fx.with_file(
	fx.with_file(istiod_overlay("prd", "true"), "envs/stg/istiod.yaml", "taint:\n  enabled: true\n"),
	"platforms/eks/istiod.yaml", "taint:\n  enabled: false\n",
))) == 0

test_no_env_overlay_for_istiod_leaves_every_env_lifted if count(deny(mesh_input)) == 0

test_an_env_that_still_lifts_keeps_the_wave_rule if fx.says(
	deny(fx.with_file(with_mesh(old), "envs/stg/istiod.yaml", "taint:\n  enabled: false\n")),
	"svp-cluster (wave 1) is pinned to Karpenter's nodes, whose startup taint cni.istio.io/not-ready istiod (wave 3) lifts",
)
