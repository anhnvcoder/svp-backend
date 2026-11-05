# The environments: envs/ holds exactly a folder per environment (prd and stg), and in each of them:
#   - charts.yaml holds exactly the keys revision, podSecurityVersion and collectorConfigSha256, one line each (the
#     script reads them with sed). revision is the full commit (40 hex) of the code repository whose charts the
#     environment runs; podSecurityVersion and collectorConfigSha256 equal what that commit gives (input.charts, which
#     the script derives with git). With input.worktree only the keys are checked.
#   - envs/prd/charts.yaml alone may add gitopsRevision, the full commit (40 hex) of this repository (svp-gitops) at which
#     prd renders argocd/apps, base/ and platforms/ while its own envs/prd/ is read on main; only the promote to prd
#     writes it, the commit of main that stg ran. stg follows main and never pins one. The two-level root argocd/root is
#     what reads the key, so a tree that sets it has that root. Whether the commit is on main of this repository, and
#     holds argocd/apps, the script checks with git.
#   - images/ holds exactly one file per service, <service>.yaml, each the image block alone: no top-level line besides
#     image:, and image.repository, tag and digest each exactly one line of the block, as values_field of
#     deploy/k8s/lib.sh reads them (the promote jobs and values-check.sh read the files so). The repository is that
#     service's of exactly one release source of the table at the environment's revision (input.sources), so a release
#     the policy of that environment admits; tag and digest are set. Whether the release is signed, and built from the
#     commit its tag names, is step 5 of the check (values-check.sh).
#   - no overlay envs/<env>/<name>.yaml nor image file sets a value null, {} or [], at any depth: the root hands their
#     content to the Applications of argocd/apps in valuesObject, and the health check of an Application
#     (argoproj.io_Application of base/argo-cd.yaml) compares the spec it reads with the one the controller compared,
#     in Lua, where null is a key left out and {} and [] are one empty table. Such a change would leave the
#     Application Healthy on the previous spec's status, and the root report the new commit deployed before it runs.
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

# The environment that may pin a commit of this repository, and the keys of its charts.yaml when it does.
pinning_env := "prd"

pinned_keys := "collectorConfigSha256 gitopsRevision podSecurityVersion revision"

# allowed_keys(env): the sets of keys envs/<env>/charts.yaml may hold.
allowed_keys(env) := {charts_keys, pinned_keys} if env == pinning_env

allowed_keys(env) := {charts_keys} if env != pinning_env

# keys(env): the keys of envs/<env>/charts.yaml, one per line that is neither blank nor a comment, sorted.
keys(env) := concat(" ", sort([regex.replace(line, `:.*`, "") |
	some line in gitops.lines(charts_path(env))
	not regex.match(`^\s*(#.*)?$`, line)
]))

deny contains msg if {
	some env in gitops.environments
	gitops.is_file(charts_path(env))
	not keys(env) in allowed_keys(env)
	not stg_pins(env)
	msg := sprintf(
		"%s holds '%s': exactly revision, podSecurityVersion and collectorConfigSha256, one line each (and gitopsRevision in %s alone)",
		[charts_path(env), keys(env), charts_path(pinning_env)],
	)
}

# stg_pins(env): env is not the pinning environment, and its charts.yaml holds exactly the pinned keys.
stg_pins(env) if {
	env != pinning_env
	keys(env) == pinned_keys
}

deny contains msg if {
	some env in gitops.environments
	stg_pins(env)
	msg := sprintf(
		"%s sets gitopsRevision: only %s pins a commit of svp-gitops (the one the promote to %s copied from stg); %s follows main",
		[charts_path(env), pinning_env, pinning_env, env],
	)
}

# Every line that is neither blank nor a comment is `key: value`, the value not empty: a key without its colon or value
# would count among the keys above yet give no value to the rules below, which would then check nothing. Not on a working
# tree, whose charts.yaml these rules never read.
deny contains msg if {
	not input.worktree
	some env in gitops.environments
	gitops.is_file(charts_path(env))
	some line in gitops.lines(charts_path(env))
	not regex.match(`^\s*(#.*)?$`, line)
	not regex.match(`^[A-Za-z0-9]+: *\S`, line)
	msg := sprintf("%s: line '%s' is not 'key: value' with a value", [charts_path(env), line])
}

# field(env, key): the value of key in envs/<env>/charts.yaml, once its keys are those of the file.
field(env, key) := regex.replace(line, `^[^:]*: *`, "") if {
	keys(env) in allowed_keys(env)
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

# gitopsRevision, with or without input.worktree: it names a commit of svp-gitops, which the working tree of this
# repository does not stand for.
deny contains msg if {
	rev := field(pinning_env, "gitopsRevision")
	not regex.match(`^[0-9a-f]{40}$`, rev)
	msg := sprintf(
		"%s: gitopsRevision is '%s', the full commit (40 hex) of svp-gitops at which %s renders argocd/apps, base/ and platforms/",
		[charts_path(pinning_env), rev, pinning_env],
	)
}

root_chart := "argocd/root/Chart.yaml"

deny contains msg if {
	field(pinning_env, "gitopsRevision")
	not gitops.is_file(root_chart)
	msg := sprintf(
		"%s sets gitopsRevision, which only the two-level root argocd/root reads: %s is missing",
		[charts_path(pinning_env), root_chart],
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

# values_files: each overlay envs/<env>/<name>.yaml (charts.yaml aside) and each image file envs/<env>/images/*.yaml.
values_files contains path if {
	some env in gitops.environments
	some dir in [sprintf("envs/%s", [env]), images_dir(env)]
	some name in gitops.visible(dir)
	name != "charts.yaml"
	endswith(name, ".yaml")
	path := concat("/", [dir, name])
	gitops.is_file(path)
}

deny contains msg if {
	some path in values_files
	doc := gitops.yaml_map(path)
	walk(doc, [at, value])
	count(at) > 0
	empty(value)
	msg := sprintf(
		"%s: %s is %s: an overlay or image file sets no null, {} or [], which the health check of Argo CD's Applications cannot tell from a key left out; leave the key out or give it a value",
		[path, key_path(at), json.marshal(value)],
	)
}

empty(value) if is_null(value)

empty(value) if value == {}

empty(value) if value == []

# key_path(at): a path walk gives, as YAML names it: a.b[0].c.
key_path(at) := trim_prefix(concat("", [segment(k) | some k in at]), ".")

segment(k) := sprintf("[%d]", [k]) if is_number(k)

segment(k) := sprintf(".%s", [k]) if is_string(k)

# release(table, svc, img): img is a release of svc of exactly one source of table, with its tag and digest.
release(table, svc, img) if {
	count([s | some s in table; svc in s.services; concat("", [s.imagePrefix, svc]) == img.repository]) == 1
	img.tag != ""
	img.digest != ""
}
