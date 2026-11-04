# Tests of envs.rego (make conftest-verify), each on the fixture with one thing changed.
package gitops.envs_test

import data.gitops.envs
import data.gitops.fixture_test as fx

deny(given) := msgs if {
	msgs := envs.deny with input as given with data.gitops_check as fx.cfg
}

worktree := object.union(object.remove(fx.tree_input, ["charts"]), {"worktree": true})

# with_image(given, env, svc, text): given with envs/<env>/images/<svc>.yaml holding text.
with_image(given, env, svc, text) := fx.with_file(given, sprintf("envs/%s/images/%s.yaml", [env, svc]), text)

# with_charts(given, env, text): given with envs/<env>/charts.yaml holding text.
with_charts(given, env, text) := fx.with_file(given, sprintf("envs/%s/charts.yaml", [env]), text)

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
	deny(with_charts(fx.tree_input, "stg", concat("", [fx.charts_text, "replicas: 2\n"]))),
	"envs/stg/charts.yaml holds 'collectorConfigSha256 podSecurityVersion replicas revision': exactly revision, podSecurityVersion and collectorConfigSha256, one line each",
)

test_charts_with_a_key_twice if fx.says(
	deny(with_charts(fx.tree_input, "prd", concat("", [fx.charts_text, "revision: ", fx.revision, "\n"]))),
	"envs/prd/charts.yaml holds 'collectorConfigSha256 podSecurityVersion revision revision'",
)

test_charts_without_a_key if fx.says(
	deny(with_charts(fx.tree_input, "stg", sprintf("revision: %s\npodSecurityVersion: v1.36\n", [fx.revision]))),
	"envs/stg/charts.yaml holds 'podSecurityVersion revision'",
)

test_charts_with_an_indented_key if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, "\nrevision:", "\n  revision:"))),
	"envs/stg/charts.yaml holds '  revision collectorConfigSha256 podSecurityVersion'",
)

test_the_keys_with_the_working_tree if fx.says(
	deny(with_charts(worktree, "stg", concat("", [fx.charts_text, "replicas: 2\n"]))),
	"envs/stg/charts.yaml holds 'collectorConfigSha256 podSecurityVersion replicas revision'",
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
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, fx.revision, sprintf("\"%s\"", [fx.revision])))),
	sprintf("envs/stg/charts.yaml: revision is '\"%s\"'", [fx.revision]),
)

test_the_working_tree_reads_no_revision if count(deny(with_charts(worktree, "stg", replace(fx.charts_text, fx.revision, "")))) == 0

test_a_wrong_collector_config_sha256 if fx.says(
	deny(with_charts(fx.tree_input, "stg", replace(fx.charts_text, fx.sha, "0000000000000000000000000000000000000000000000000000000000000000"))),
	sprintf(
		"envs/stg/charts.yaml: collectorConfigSha256 is '0000000000000000000000000000000000000000000000000000000000000000', deploy/observability/otelcol/k8s-config.yaml at 0b4c089951cf has sha256 %s",
		[fx.sha],
	),
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
	"envs/stg/images/ holds 'engagement-service.yaml feed-service.yaml gateway.yaml media-worker.yaml user-service.yaml video-service.yaml': exactly one file per service, engagement-service.yaml feed-service.yaml gateway.yaml media-worker.yaml user-service.yaml video-service.yaml web.yaml",
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
	sprintf("image:\n  repository: ghcr.io/anhnvcoder/svp-backend/gateway\n  tag: 0b4c089951cf\n  digest: %s\n", [fx.digest]),
))) == 0

test_an_empty_tag if fx.says(
	deny(with_image(fx.tree_input, "stg", "gateway", replace(fx.image_text(fx.repository("gateway")), "\"0b4c089951cf\"", "\"\""))),
	sprintf("envs/stg/images/gateway.yaml: the image must be a release of ghcr.io/anhnvcoder/svp-backend/gateway with its tag and digest, not 'ghcr.io/anhnvcoder/svp-backend/gateway' '' '%s'", [fx.digest]),
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

# The table of the rename: the retired sources still listed, without promoter.
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

# Without the table of an environment (the script names why), its image files are held to their shape alone.
test_without_the_table_the_shape_alone if count(deny(with_image(
	json.remove(fx.tree_input, ["sources/stg"]),
	"stg", "web", fx.image_text("ghcr.io/anhnvcoder/svp-web/web"),
))) == 0
