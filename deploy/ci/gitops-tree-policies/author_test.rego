# Tests of author.rego (make conftest-verify): pull requests on the fixture, each by an author whose event a sender
# caused, changing files ([status, path]).
package gitops.author_test

import data.gitops.author
import data.gitops.fixture_test as fx

deny(given) := msgs if {
	msgs := author.deny with input as given with data.gitops_check as fx.cfg
}

web_bot := "svp-web-promoter[bot]"

backend_bot := "svp-gitops-promoter[bot]"

# by(login, changes): a pull request of login, which pushed its commit itself.
by(login, changes) := deny(fx.pull_request(fx.tree_input, login, login, changes))

outside := "the bot of a release source: it changes envs/<env>/images/<service>.yaml of its own services only (the bot of backend also envs/<env>/charts.yaml and envs/prd/images/)"

test_no_pull_request_passes if count(deny(fx.tree_input)) == 0

test_the_bot_of_svp_frontend_moves_web_of_stg if count(by(web_bot, [["M", "envs/stg/images/web.yaml"]])) == 0

test_the_bot_of_svp_frontend_moves_web_of_prd if count(by(web_bot, [["M", "envs/prd/images/web.yaml"]])) == 0

test_the_bot_of_backend_promotes_charts_and_the_six_services_to_stg if count(by(backend_bot, array.concat(
	[["M", "envs/stg/charts.yaml"]],
	[["M", $"envs/stg/images/{svc}.yaml"] | some svc in fx.six],
))) == 0

test_the_bot_of_backend_promotes_the_whole_set_to_prd_web_included if count(by(backend_bot, array.concat(
	[["M", "envs/prd/charts.yaml"]],
	[["M", $"envs/prd/images/{svc}.yaml"] | some svc in fx.services],
))) == 0

test_a_person_changes_anything if count(by("anhnvcoder", [
	["M", "envs/stg/svp-cluster.yaml"],
	["M", "base/tempo.yaml"],
	["D", "envs/stg/images/gateway.yaml"],
])) == 0

test_a_bot_that_promotes_no_source_changes_base if count(by("renovate[bot]", [["M", "base/tempo.yaml"]])) == 0

test_a_person_pushes_onto_the_pull_request_of_a_bot if count(deny(fx.pull_request(
	fx.tree_input, backend_bot, "anhnvcoder",
	[["M", "envs/stg/images/gateway.yaml"]],
))) == 0

test_a_person_pushing_onto_the_pull_request_of_a_bot_is_held_to_the_bots_rule if fx.says(
	deny(fx.pull_request(fx.tree_input, web_bot, "anhnvcoder", [["M", "envs/stg/images/gateway.yaml"]])),
	"envs/stg/images/gateway.yaml: changed by svp-web-promoter[bot], the bot of release source web",
)

test_the_bot_of_svp_frontend_changes_gateway_of_stg if fx.says(
	by(web_bot, [["M", "envs/stg/images/gateway.yaml"]]),
	"envs/stg/images/gateway.yaml: changed by svp-web-promoter[bot], the bot of release source web, which publishes web: it changes the image files of those services only",
)

test_the_bot_of_svp_frontend_changes_gateway_of_prd if fx.says(
	by(web_bot, [["M", "envs/prd/images/gateway.yaml"]]),
	"envs/prd/images/gateway.yaml: changed by svp-web-promoter[bot], the bot of release source web, which publishes web",
)

test_the_bot_of_svp_frontend_changes_charts if fx.says(
	by(web_bot, [["M", "envs/stg/charts.yaml"]]),
	"envs/stg/charts.yaml: changed by svp-web-promoter[bot], the bot of release source web: only the bot of backend, whose repository holds the charts, changes charts.yaml",
)

test_the_bot_of_backend_changes_web_of_stg if fx.says(
	by(backend_bot, [["M", "envs/stg/images/web.yaml"]]),
	"envs/stg/images/web.yaml: changed by svp-gitops-promoter[bot], the bot of release source backend, which publishes gateway user-service video-service engagement-service feed-service media-worker",
)

test_the_bot_of_backend_adds_an_image_file_of_no_service_to_prd if fx.says(
	by(backend_bot, [["A", "envs/prd/images/admin.yaml"]]),
	"envs/prd/images/admin.yaml: changed by svp-gitops-promoter[bot], the bot of release source backend, which publishes",
)

test_the_bot_of_svp_frontend_changes_an_overlay_of_stg if fx.says(
	by(web_bot, [["M", "envs/stg/svp-cluster.yaml"]]),
	$"envs/stg/svp-cluster.yaml: changed by svp-web-promoter[bot], {outside}",
)

test_the_bot_of_backend_changes_an_overlay_of_stg if fx.says(
	by(backend_bot, [["M", "envs/stg/gateway.yaml"]]),
	$"envs/stg/gateway.yaml: changed by svp-gitops-promoter[bot], {outside}",
)

test_the_bot_of_backend_adds_an_overlay_to_stg if fx.says(
	by(backend_bot, [["A", "envs/stg/kyverno.yaml"]]),
	$"envs/stg/kyverno.yaml: changed by svp-gitops-promoter[bot], {outside}",
)

test_the_bot_of_backend_adds_an_image_file_of_an_unknown_environment if fx.says(
	by(backend_bot, [["A", "envs/qa/images/gateway.yaml"]]),
	$"envs/qa/images/gateway.yaml: changed by svp-gitops-promoter[bot], {outside}",
)

test_the_bot_of_backend_adds_an_image_file_without_a_name if fx.says(
	by(backend_bot, [["A", "envs/stg/images/.yaml"]]),
	$"envs/stg/images/.yaml: changed by svp-gitops-promoter[bot], {outside}",
)

test_the_bot_of_svp_frontend_deletes_web if fx.says(
	by(web_bot, [["D", "envs/stg/images/web.yaml"]]),
	"envs/stg/images/web.yaml: deleted by svp-web-promoter[bot], the bot of release source web: a bot changes files under envs/, never deletes one",
)

test_the_bot_of_backend_deletes_charts if fx.says(
	by(backend_bot, [["D", "envs/prd/charts.yaml"]]),
	"envs/prd/charts.yaml: deleted by svp-gitops-promoter[bot], the bot of release source backend",
)

test_the_bot_of_svp_frontend_changes_base if fx.says(
	by(web_bot, [["M", "base/tempo.yaml"]]),
	$"base/tempo.yaml: changed by svp-web-promoter[bot], {outside}",
)

test_the_bot_of_backend_changes_the_workflow_of_the_check if fx.says(
	by(backend_bot, [["M", ".github/workflows/check.yml"]]),
	$".github/workflows/check.yml: changed by svp-gitops-promoter[bot], {outside}",
)

test_a_bot_that_promotes_no_source_changes_an_image_file if fx.says(
	by("renovate[bot]", [["M", "envs/stg/images/gateway.yaml"]]),
	"envs/stg/images/gateway.yaml: changed by renovate[bot], a bot that promotes no release source: such a bot changes nothing under envs/",
)

test_a_bot_that_promotes_no_source_adds_a_file_of_a_name_git_quotes_under_envs if fx.says(
	by("renovate[bot]", [["A", "envs/stg/gätewäy.yaml"]]),
	"envs/stg/gätewäy.yaml: changed by renovate[bot], a bot that promotes no release source",
)

test_every_file_is_named if count(by(web_bot, [
	["M", "envs/stg/images/web.yaml"],
	["M", "envs/stg/images/gateway.yaml"],
	["M", "base/tempo.yaml"],
])) == 2

test_a_bot_pushes_onto_the_pull_request_of_another_bot if fx.says(
	deny(fx.pull_request(fx.tree_input, backend_bot, web_bot, [["M", "envs/stg/images/web.yaml"]])),
	"the commit checked was pushed by svp-web-promoter[bot] onto the pull request of svp-gitops-promoter[bot]: a bot pushes onto its own pull requests only, since the files allowed are the author's",
)

test_a_bot_pushing_onto_another_bots_pull_request_is_named_alone if count(deny(fx.pull_request(
	fx.tree_input, backend_bot, web_bot,
	[["M", "base/tempo.yaml"]],
))) == 1

test_a_bot_pushes_onto_the_pull_request_of_a_person if fx.says(
	deny(fx.pull_request(fx.tree_input, "anhnvcoder", "renovate[bot]", [])),
	"the commit checked was pushed by renovate[bot] onto the pull request of anhnvcoder",
)

test_a_table_that_cannot_be_read if fx.says(
	deny(fx.pull_request(json.remove(fx.tree_input, ["sources/prd"]), web_bot, web_bot, [["M", "envs/stg/images/web.yaml"]])),
	"the release sources of the charts of envs/prd cannot be read (above), so neither can which files svp-web-promoter[bot] may change",
)

test_a_bot_promoting_no_source_of_the_charts_an_environment_runs if fx.says(
	deny(fx.pull_request(
		object.union(fx.tree_input, {"sources": {"prd": {"revision": "1111111111111111111111111111111111111111", "sources": [fx.backend]}}}),
		web_bot, web_bot, [["M", "envs/prd/images/web.yaml"]],
	)),
	"envs/prd/images/web.yaml: changed by svp-web-promoter[bot], which promotes no release source of the charts envs/prd runs (111111111111)",
)

test_a_promoter_of_one_table_only_is_a_promoter if count(deny(fx.pull_request(
	object.union(fx.tree_input, {"sources": {"prd": {"revision": "1111111111111111111111111111111111111111", "sources": [fx.backend]}}}),
	web_bot, web_bot, [["M", "envs/stg/images/web.yaml"]],
))) == 0
