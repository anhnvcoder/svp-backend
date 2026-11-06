# Tests of envs.rego (make conftest-verify), each on the fixture with one thing changed.
package gitops.envs_test

import data.gitops.envs
import data.gitops.fixture_test as fx

deny(given) := msgs if {
	msgs := envs.deny with input as given with data.gitops_check as fx.cfg
}

worktree := object.union(object.remove(fx.tree_input, ["charts"]), {"worktree": true})

# with_image(given, env, svc, text): given with envs/<env>/images/<svc>.yaml holding text.
with_image(given, env, svc, text) := fx.with_file(given, $"envs/{env}/images/{svc}.yaml", text)

# with_charts(given, env, text): given with envs/<env>/charts.yaml holding text.
with_charts(given, env, text) := fx.with_file(given, $"envs/{env}/charts.yaml", text)

test_the_fixture_passes if count(deny(fx.tree_input)) == 0

test_the_fixture_passes_with_the_working_tree if count(deny(worktree)) == 0

test_an_unknown_environment if fx.says(
	deny(fx.with_entry(fx.tree_input, "envs/qa", fx.dir)),
	"envs/ holds 'prd qa stg': the environments are exactly prd and stg",
)

test_an_environment_missing if fx.says(deny(fx.without(fx.tree_input, "envs/prd")), "envs/ holds 'stg'")

test_no_envs if fx.says(deny(fx.without(fx.tree_input, "envs")), "envs/ holds '': the environments are exactly prd and stg")

test_a_file_beside_the_environments_passes if count(deny(fx.with_file(fx.tree_input, "envs/README.md", "# envs\n"))) == 0

test_a_dot_folder_beside_the_environments_passes if count(deny(fx.with_entry(fx.tree_input, "envs/.cache", fx.dir))) == 0

test_charts_missing if fx.says(
	deny(fx.without(fx.tree_input, "envs/stg/charts.yaml")),
	"envs/stg/charts.yaml is missing: it pins the commit of this repository whose charts stg runs",
)

test_charts_with_another_key if fx.says(
	deny(with_charts(fx.tree_input, "stg", $"{fx.charts_text}replicas: 2\n")),
	"envs/stg/charts.yaml holds 'collectorConfigSha256 podSecurityVersion replicas revision': exactly revision, podSecurityVersion and collectorConfigSha256, one line each",
)

test_charts_with_a_key_twice if fx.says(
	deny(with_charts(fx.tree_input, "prd", $"{fx.charts_text}revision: {fx.revision}\n")),
	"envs/prd/charts.yaml holds 'collectorConfigSha256 podSecurityVersion revision revision'",
)

test_charts_without_a_key if fx.says(
	deny(with_charts(fx.tree_input, "stg", $"revision: {fx.revision}\npodSecurityVersion: v1.36\n")),
	"envs/stg/charts.yaml holds 'podSecurityVersion revision'",
)

test_charts_with_an_indented_key if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, "\nrevision:", "\n  revision:"))),
	"envs/stg/charts.yaml holds '  revision collectorConfigSha256 podSecurityVersion'",
)

test_the_keys_with_the_working_tree if fx.says(
	deny(with_charts(worktree, "stg", $"{fx.charts_text}replicas: 2\n")),
	"envs/stg/charts.yaml holds 'collectorConfigSha256 podSecurityVersion replicas revision'",
)

# pinned(given, env, rev): given with gitopsRevision rev added to envs/<env>/charts.yaml, and the two-level root.
pinned(given, env, rev) := fx.with_file(
	with_charts(given, env, $"{fx.charts_text}# The commit of svp-gitops prd renders at.\ngitopsRevision: {rev}\n"),
	"argocd/root/Chart.yaml",
	"apiVersion: v2\nname: svp-root\nversion: 0.1.0\n",
)

gitops_commit := "5d2b1c7e9f0a3b4c5d6e7f8091a2b3c4d5e6f708"

test_prd_pinned_to_a_commit_passes if count(deny(pinned(fx.tree_input, "prd", gitops_commit))) == 0

test_prd_pinned_with_the_working_tree_passes if count(deny(pinned(worktree, "prd", gitops_commit))) == 0

test_stg_pinned if fx.says(
	deny(pinned(fx.tree_input, "stg", gitops_commit)),
	"envs/stg/charts.yaml sets gitopsRevision: only prd pins a commit of svp-gitops (the one the promote to prd copied from stg); stg follows main",
)

test_stg_pinned_names_no_other_rule if count(deny(pinned(fx.tree_input, "stg", gitops_commit))) == 1

test_a_pin_that_is_a_branch if fx.says(
	deny(pinned(fx.tree_input, "prd", "main")),
	"envs/prd/charts.yaml: gitopsRevision is 'main', the full commit (40 hex) of svp-gitops at which prd renders argocd/apps, base/ and platforms/",
)

test_a_short_pin if fx.says(
	deny(pinned(fx.tree_input, "prd", substring(gitops_commit, 0, 12))),
	"envs/prd/charts.yaml: gitopsRevision is '5d2b1c7e9f0a', the full commit (40 hex)",
)

test_a_short_pin_with_the_working_tree if fx.says(
	deny(pinned(worktree, "prd", substring(gitops_commit, 0, 12))),
	"envs/prd/charts.yaml: gitopsRevision is '5d2b1c7e9f0a'",
)

test_a_pin_without_the_two_level_root if fx.says(
	deny(fx.without(pinned(fx.tree_input, "prd", gitops_commit), "argocd/root")),
	"envs/prd/charts.yaml sets gitopsRevision, which only the two-level root argocd/root reads: argocd/root/Chart.yaml is missing",
)

test_a_pin_twice if fx.says(
	deny(with_charts(pinned(fx.tree_input, "prd", gitops_commit), "prd", $"{fx.charts_text}gitopsRevision: {gitops_commit}\ngitopsRevision: {gitops_commit}\n")),
	concat("", [
		"envs/prd/charts.yaml holds 'collectorConfigSha256 gitopsRevision gitopsRevision podSecurityVersion revision': ",
		"exactly revision, podSecurityVersion and collectorConfigSha256, one line each (and gitopsRevision in envs/prd/charts.yaml alone)",
	]),
)

test_an_empty_revision if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, fx.revision, ""))),
	"envs/stg/charts.yaml: revision is '', the full commit (40 hex) of this repository whose charts stg runs",
)

test_a_short_revision if fx.says(
	deny(with_charts(fx.tree_input, "prd", replace(fx.charts_text, fx.revision, "0b4c089951cf"))),
	"envs/prd/charts.yaml: revision is '0b4c089951cf', the full commit (40 hex)",
)

test_a_quoted_revision if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, fx.revision, $"\"{fx.revision}\""))),
	$"envs/stg/charts.yaml: revision is '\"{fx.revision}\"'",
)

test_the_working_tree_reads_no_revision if count(deny(with_charts(worktree, "stg", replace(fx.charts_text, fx.revision, "")))) == 0

test_a_wrong_collector_config_sha256 if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, fx.sha, "0000000000000000000000000000000000000000000000000000000000000000"))),
	$"envs/stg/charts.yaml: collectorConfigSha256 is '0000000000000000000000000000000000000000000000000000000000000000', deploy/observability/otelcol/k8s-config.yaml at 0b4c089951cf has sha256 {fx.sha}",
)

test_a_wrong_pod_security_version if fx.says(
	deny(with_charts(fx.tree_input, "prd", replace(fx.charts_text, "v1.36", "v1.35"))),
	"envs/prd/charts.yaml: podSecurityVersion is 'v1.35', deploy/helm/svp-cluster/values.yaml at 0b4c089951cf pins 'v1.36'",
)

test_derived_values_of_an_environment_off_main_are_not_compared if count(deny(with_charts(
	json.remove(fx.tree_input, ["charts/prd"]),
	"prd", replace(fx.charts_text, "v1.36", "v1.35"),
))) == 0

test_six_image_files_of_seven if fx.says(
	deny(fx.without(fx.tree_input, "envs/stg/images/web.yaml")),
	concat("", [
		"envs/stg/images/ holds 'engagement-service.yaml feed-service.yaml gateway.yaml media-worker.yaml user-service.yaml video-service.yaml': ",
		"exactly one file per service, engagement-service.yaml feed-service.yaml gateway.yaml media-worker.yaml user-service.yaml video-service.yaml web.yaml",
	]),
)

test_an_image_file_of_no_service if fx.says(
	deny(with_image(fx.tree_input, "prd", "admin", fx.image_text("ghcr.io/anhnvcoder/svp-backend/admin"))),
	"envs/prd/images/ holds 'admin.yaml engagement-service.yaml",
)

test_a_dot_file_among_the_image_files if fx.says(
	deny(fx.with_file(fx.tree_input, "envs/stg/images/.gateway.yaml.swp", "")),
	"envs/stg/images/ holds '.gateway.yaml.swp engagement-service.yaml",
)

test_no_images_folder if fx.says(deny(fx.without(fx.tree_input, "envs/prd/images")), "envs/prd/images/ holds '': exactly one file per service")

test_an_image_file_with_another_key if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", concat("", [fx.image_text(fx.repository("gateway")), "replicas: 2\n"]))),
	"envs/stg/images/gateway.yaml holds replicas besides image: an image file holds the image block alone",
)

test_an_image_file_with_two_other_keys if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", concat("", ["canary: {}\n", fx.image_text(fx.repository("gateway")), "replicas: 2\n"]))),
	"envs/stg/images/gateway.yaml holds canary replicas besides image",
)

test_an_image_block_in_flow_style if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", "image: {repository: ghcr.io/anhnvcoder/svp-backend/gateway}\n")),
	"envs/stg/images/gateway.yaml holds image besides image",
)

test_a_field_twice if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", concat("", [fx.image_text(fx.repository("gateway")), "  tag: \"0b4c089951cf\"\n"]))),
	"envs/stg/images/gateway.yaml: image.repository, tag and digest must each be one plain line in the image block",
)

test_a_field_missing if fx.says(
	deny(with_image(fx.tree_input, "prd", "web", "image:\n  repository: ghcr.io/anhnvcoder/svp-frontend/web\n  tag: \"0b4c089951cf\"\n")),
	"envs/prd/images/web.yaml: image.repository, tag and digest must each be one plain line in the image block",
)

test_a_field_with_a_comment if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", replace(fx.image_text(fx.repository("gateway")), "\"0b4c089951cf\"", "\"0b4c089951cf\" # main"))),
	"envs/stg/images/gateway.yaml: image.repository, tag and digest must each be one plain line",
)

test_a_tag_that_is_no_commit if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", replace(fx.image_text(fx.repository("gateway")), "\"0b4c089951cf\"", "latest"))),
	"envs/stg/images/gateway.yaml: image.repository, tag and digest must each be one plain line",
)

test_a_field_outside_the_image_block if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", "image:\n  repository: ghcr.io/anhnvcoder/svp-backend/gateway\n  tag: \"0b4c089951cf\"\n# below\nother:\n  digest: \"x\"\n")),
	"envs/stg/images/gateway.yaml holds other besides image",
)

test_bare_values_pass if count(deny(with_image(
	fx.tree_input, "stg", "gateway",
	$"image:\n  repository: ghcr.io/anhnvcoder/svp-backend/gateway\n  tag: 0b4c089951cf\n  digest: {fx.digest}\n",
))) == 0

test_an_empty_tag if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", replace(fx.image_text(fx.repository("gateway")), "\"0b4c089951cf\"", "\"\""))),
	$"envs/stg/images/gateway.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-backend/gateway with its tag and digest, not 'ghcr.io/anhnvcoder/svp-backend/gateway' '' '{fx.digest}'",
)

test_an_empty_digest if fx.says(
	deny(with_image(fx.tree_input, "prd", "web", replace(fx.image_text(fx.repository("web")), fx.digest, ""))),
	"envs/prd/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-frontend/web with its tag and digest, not 'ghcr.io/anhnvcoder/svp-frontend/web' '0b4c089951cf' ''",
)

test_the_repository_of_another_service if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", fx.image_text(fx.repository("user-service")))),
	"envs/stg/images/gateway.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-backend/gateway with its tag and digest, not 'ghcr.io/anhnvcoder/svp-backend/user-service'",
)

test_a_repository_of_no_source if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", fx.image_text("docker.io/someone/gateway"))),
	"envs/stg/images/gateway.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-backend/gateway",
)

renamed := object.union(fx.tree_input, {"sources": {"stg": {"revision": fx.revision, "sources": array.concat(fx.table, fx.retired)}}})

test_the_table_of_the_rename_admits_the_releases_of_the_retired_sources if count(deny(object.union_n([
	renamed,
	with_image(renamed, "stg", "web", fx.image_text("ghcr.io/anhnvcoder/svp-web/web")),
	with_image(renamed, "stg", "gateway", fx.image_text("ghcr.io/anhnvcoder/short-video-platform/gateway")),
]))) == 0

test_the_table_of_the_rename_admits_the_releases_of_the_new_sources if count(deny(renamed)) == 0

test_the_table_of_the_rename_names_both_repositories if fx.says(
	deny(with_image(renamed, "stg", "web", fx.image_text("ghcr.io/anhnvcoder/svp-backend/web"))),
	"envs/stg/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-frontend/web or ghcr.io/anhnvcoder/svp-web/web with its tag and digest",
)

test_the_table_of_now_refuses_a_release_of_a_retired_source if fx.says(
	deny(with_image(fx.tree_input, "stg", "web", fx.image_text("ghcr.io/anhnvcoder/svp-web/web"))),
	"envs/stg/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-frontend/web with its tag and digest",
)

test_the_working_tree_table_refuses_a_release_of_a_retired_source if fx.says(
	deny(with_image(worktree, "prd", "web", fx.image_text("ghcr.io/anhnvcoder/svp-web/web"))),
	"envs/prd/images/web.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-frontend/web",
)

test_without_the_table_the_shape_alone if count(deny(with_image(
	json.remove(fx.tree_input, ["sources/stg"]),
	"stg", "web", fx.image_text("ghcr.io/anhnvcoder/svp-web/web"),
))) == 0

# A key without its colon or its value counts among the keys but gives the rules no value: refused, so the revision and
# the derived values are always checked.
test_a_revision_without_its_colon if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, $"revision: {fx.revision}", "revision"))),
	"envs/stg/charts.yaml: line 'revision' is not 'key: value' with a value",
)

test_a_revision_without_a_value if fx.says(
	deny(with_charts(fx.tree_input, "prd", replace(fx.charts_text, $"revision: {fx.revision}", "revision:"))),
	"envs/prd/charts.yaml: line 'revision:' is not 'key: value' with a value",
)

test_a_derived_value_without_its_colon if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, "podSecurityVersion: v1.36", "podSecurityVersion"))),
	"envs/stg/charts.yaml: line 'podSecurityVersion' is not 'key: value' with a value",
)

# with_overlay(given, env, name, text): given with envs/<env>/<name>.yaml holding text.
with_overlay(given, env, name, text) := fx.with_file(given, $"envs/{env}/{name}.yaml", text)

empty_value := "sets no null, {} or [], which the health check of Argo CD's Applications cannot tell from a key left out"

test_an_overlay_setting_null if fx.says(
	deny(with_overlay(fx.tree_input, "stg", "gateway", "replicas: 2\npdb: null\n")),
	$"envs/stg/gateway.yaml: pdb is null: an overlay or image file {empty_value}",
)

test_an_overlay_setting_null_names_no_other_rule if count(deny(with_overlay(fx.tree_input, "stg", "gateway", "pdb: null\n"))) == 1

test_an_overlay_with_a_key_without_value if fx.says(
	deny(with_overlay(fx.tree_input, "prd", "gateway", "pdb:\n")),
	"envs/prd/gateway.yaml: pdb is null",
)

test_an_overlay_with_a_tilde if fx.says(deny(with_overlay(fx.tree_input, "stg", "gateway", "pdb: ~\n")), "envs/stg/gateway.yaml: pdb is null")

test_an_overlay_with_an_empty_map_deep if fx.says(
	deny(with_overlay(fx.tree_input, "stg", "gateway", "resources:\n  requests:\n    cpu: 100m\n  limits: {}\n")),
	"envs/stg/gateway.yaml: resources.limits is {}",
)

test_an_overlay_with_an_empty_list if fx.says(
	deny(with_overlay(fx.tree_input, "stg", "gateway", "env: []\n")),
	"envs/stg/gateway.yaml: env is []",
)

test_an_overlay_with_an_empty_map_in_a_list if fx.says(
	deny(with_overlay(fx.tree_input, "prd", "gateway", "env:\n  - name: A\n    value: x\n  - name: B\n    valueFrom: {}\n")),
	"envs/prd/gateway.yaml: env[1].valueFrom is {}",
)

test_an_overlay_with_null_in_a_list if fx.says(
	deny(with_overlay(fx.tree_input, "stg", "gateway", "args:\n  - --a\n  -\n")),
	"envs/stg/gateway.yaml: args[1] is null",
)

test_a_new_overlay_with_null if fx.says(
	deny(with_overlay(fx.tree_input, "stg", "svp-policy", "imageVerification:\n  required: null\n")),
	"envs/stg/svp-policy.yaml: imageVerification.required is null",
)

test_an_image_file_with_a_null_tag if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", replace(fx.image_text(fx.repository("gateway")), "\"0b4c089951cf\"", ""))),
	"envs/stg/images/gateway.yaml: image.tag is null",
)

# false, 0 and "" stay what they are in Lua, and an overlay of comments alone hands over no value at all.
test_false_zero_and_empty_string_pass if count(deny(with_overlay(
	fx.tree_input, "stg", "gateway",
	"replicas: 0\npdb:\n  enabled: false\nenv:\n  - name: A\n    value: \"\"\n",
))) == 0

test_an_overlay_of_comments_alone_passes if count(deny(with_overlay(fx.tree_input, "stg", "gateway", "# Nothing yet.\n"))) == 0
