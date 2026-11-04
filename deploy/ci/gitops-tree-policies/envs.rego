# The environments: envs/ holds exactly a folder per environment (prd and stg), and in each of them:
#   - charts.yaml holds exactly the keys revision, podSecurityVersion and collectorConfigSha256, one line each (the
#     script reads them with sed). revision is the full commit (40 hex) of the code repository whose charts the
#     environment runs; podSecurityVersion and collectorConfigSha256 equal what that commit gives (input.charts, which
#     the script derives with git). With input.worktree only the keys are checked.
#   - images/ holds exactly one file per service, <service>.yaml, each the image block alone: no top-level line besides
#     image:, and image.repository, tag and digest each exactly one line of the block, as values_field of
#     deploy/k8s/lib.sh reads them (the promote jobs and values-check.sh read the files so). The repository is that
#     service's of exactly one release source of the table at the environment's revision (input.sources), so a release
#     the policy of that environment admits; tag and digest are set. Whether the release is signed, and built from the
#     commit its tag names, is step 5 of the check (values-check.sh).
package gitops.envs

import data.gitops

envs := concat(" ", sort(gitops.environments))

deny contains sprintf("envs/ holds '%s': the environments are exactly %s", [got, concat(" and ", sort(gitops.environments))]) if {
	got := gitops.folders("envs")
	got != envs
}

charts_path(env) := sprintf("envs/%s/charts.yaml", [env])

deny contains sprintf("%s is missing: it pins the commit of this repository whose charts %s runs", [charts_path(env), env]) if {
	some env in gitops.environments
	not gitops.is_file(charts_path(env))
}

charts_keys := "collectorConfigSha256 podSecurityVersion revision"

# keys(env): the keys of envs/<env>/charts.yaml, one per line that is neither blank nor a comment, sorted.
keys(env) := concat(" ", sort([regex.replace(line, `:.*`, "") |
	some line in gitops.lines(charts_path(env))
	not regex.match(`^\s*(#.*)?$`, line)
]))

deny contains msg if {
	some env in gitops.environments
	gitops.is_file(charts_path(env))
	keys(env) != charts_keys
	msg := sprintf(
		"%s holds '%s': exactly revision, podSecurityVersion and collectorConfigSha256, one line each",
		[charts_path(env), keys(env)],
	)
}

# field(env, key): the value of key in envs/<env>/charts.yaml, once its keys are those of the file.
field(env, key) := regex.replace(line, `^[^:]*: *`, "") if {
	keys(env) == charts_keys
	some line in gitops.lines(charts_path(env))
	startswith(line, concat("", [key, ":"]))
}

deny contains msg if {
	not input.worktree
	some env in gitops.environments
	rev := field(env, "revision")
	not regex.match(`^[0-9a-f]{40}$`, rev)
	msg := sprintf(
		"%s: revision is '%s', the full commit (40 hex) of this repository whose charts %s runs",
		[charts_path(env), rev, env],
	)
}

derived := {
	"podSecurityVersion": "deploy/helm/svp-cluster/values.yaml at %s pins '%s'",
	"collectorConfigSha256": "deploy/observability/otelcol/k8s-config.yaml at %s has sha256 %s",
}

deny contains msg if {
	not input.worktree
	some env, given in input.charts
	some key, from in derived
	got := field(env, key)
	got != given[key]
	msg := sprintf("%s: %s is '%s', %s", [
		charts_path(env), key, got,
		sprintf(from, [substring(given.revision, 0, 12), given[key]]),
	])
}

images_dir(env) := sprintf("envs/%s/images", [env])

want_images := concat(" ", sort([sprintf("%s.yaml", [svc]) | some svc in gitops.services]))

deny contains sprintf("%s/ holds '%s': exactly one file per service, %s", [images_dir(env), got, want_images]) if {
	some env in gitops.environments
	got := concat(" ", sort(gitops.names(images_dir(env))))
	got != want_images
}

# image_files: [env, service, path] of each image file of the tree.
image_files contains [env, svc, path] if {
	some env in gitops.environments
	some svc in gitops.services
	path := sprintf("%s/%s.yaml", [images_dir(env), svc])
	gitops.is_file(path)
}

# others(path): the top-level lines of an image file besides image:, up to their colon.
others(path) := [regex.replace(line, `:.*`, "") |
	some line in gitops.lines(path)
	not regex.match(`^(\s|#|$)`, line)
	line != "image:"
]

deny contains sprintf("%s holds %s besides image: an image file holds the image block alone", [path, concat(" ", others(path))]) if {
	some [_, _, path] in image_files
	count(others(path)) > 0
}

forms := {
	"repository": `^[0-9a-z.:/_-]*$`,
	"tag": `^([0-9a-f]{12})?$`,
	"digest": `^(sha256:[0-9a-f]{64})?$`,
}

# image(path): image.repository, tag and digest of an image file, read as values_field of deploy/k8s/lib.sh reads
# them: each exactly one line "  <key>: <value>" inside the top-level block image:, the value bare or in double
# quotes and of the key's form ("" when empty); undefined when one is not so.
image(path) := {key: value |
	some key, _ in forms
	value := image_field(path, key)
} if {
	every key, _ in forms {
		image_field(path, key)
	}
}

image_field(path, key) := value if {
	lines := gitops.lines(path)
	values := [unquote(regex.replace(line, sprintf(`^  %s: *`, [key]), "")) |
		some i, line in lines
		startswith(line, sprintf("  %s:", [key]))
		in_image_block(lines, i)
	]
	count(values) == 1
	value := values[0]
	regex.match(forms[key], value)
}

# in_image_block(lines, i): line i lies inside the top-level block image: (the top-level line before it is image:).
in_image_block(lines, i) if {
	tops := [j | some j, line in lines; j < i; regex.match(`^[^ #]`, line)]
	count(tops) > 0
	startswith(lines[max(tops)], "image:")
}

unquote(v) := substring(v, 1, count(v) - 2) if regex.match(`^"[^"]*"$`, v)

unquote(v) := v if not regex.match(`^"[^"]*"$`, v)

deny contains sprintf("%s: image.repository, tag and digest must each be one plain line in the image block", [path]) if {
	some [_, _, path] in image_files
	count(others(path)) == 0
	not image(path)
}

deny contains msg if {
	some [env, svc, path] in image_files
	count(others(path)) == 0
	img := image(path)
	table := input.sources[env].sources
	not release(table, svc, img)
	msg := sprintf("%s: the image must be a release of %s with its tag and digest, not '%s' '%s' '%s'", [
		path,
		concat(" or ", [concat("", [s.imagePrefix, svc]) | some s in table; svc in s.services]),
		img.repository, img.tag, img.digest,
	])
}

# release(table, svc, img): img is a release of svc of exactly one source of table, with its tag and digest.
release(table, svc, img) if {
	count([s | some s in table; svc in s.services; concat("", [s.imagePrefix, svc]) == img.repository]) == 1
	img.tag != ""
	img.digest != ""
}
