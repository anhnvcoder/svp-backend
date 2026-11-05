# The platform layer. Key platforms of argocd/apps/components.json maps each platform to the environments that run on
# it (envs, each of prd and stg on at least one platform) and whether its renders may name the lab's *.svp.localhost
# (localHosts, false when left out); platforms of a component, when set, lists platforms of that map, each once (no
# platforms: every platform). platforms/ holds exactly a folder per platform of the map (and README.md), and
# argocd/apps/files/platforms is a symbolic link to it. Each file of platforms/<platform>/ is README.md, argo-cd.yaml
# (the platform's values of Argo CD, after argocd/bootstrap.json's), or <name>.yaml or <name>.values.tpl with <name> a
# component that runs on that platform. A file platforms/<platform>/*.yaml is held to an overlay's rules: a YAML map
# that sets no key cluster (what depends on the cluster reaches a component through a template <name>.values.tpl,
# from the root's value cluster), and for a release of chart svp-service no image, canary or httpRoute.name (a release's
# image is envs/<env>/images/<name>.yaml, and every platform runs the base's canary). What the templates render is
# checked on the root's render (step 2 of the check).
package gitops.platforms

import data.gitops

file := gitops.components_file

platform_map := gitops.components_doc.platforms

envs := concat(" ", gitops.environments)

deny contains sprintf("%s: has no key platforms, a map of each platform to {envs, localHosts}", [file]) if {
	is_object(gitops.components_doc)
	not filled
}

filled if {
	is_object(platform_map)
	count(platform_map) > 0
}

bad := sort([name | some name, value in platform_map; not sound(name, value)]) if filled

sound(name, value) if {
	regex.match(`^[a-z][a-z0-9]*$`, name)
	is_object(value)
	count(object.keys(value) - {"envs", "localHosts"}) == 0
	is_array(value.envs)
	count(value.envs) > 0
	count({e | some e in value.envs}) == count(value.envs)
	every e in value.envs {
		e in gitops.environments
	}
	local_hosts_sound(value)
}

local_hosts_sound(value) if not "localHosts" in object.keys(value)

local_hosts_sound(value) if is_boolean(value.localHosts)

deny contains msg if {
	count(bad) > 0
	msg := sprintf(
		"%s: platforms: %s must each map a name of lowercase letters and digits to {envs: environments of %s, each once; localHosts: true or false, optional}",
		[file, concat(" ", bad), envs],
	)
}

unrun := [env | some env in gitops.environments; not run(env)] if count(bad) == 0

run(env) if {
	some value in platform_map
	env in value.envs
}

deny contains sprintf("%s: platforms: no platform runs %s", [file, concat(" ", unrun)]) if count(unrun) > 0

# names: the platforms, sorted and joined by spaces, once the map is sound.
names := concat(" ", sort(object.keys(platform_map))) if count(unrun) == 0

platforms := object.keys(platform_map) if count(unrun) == 0

deny contains msg if {
	misplaced := [c.name | some c in gitops.components; "platforms" in object.keys(c); not lists_platforms(c.platforms)]
	count(misplaced) > 0
	msg := sprintf(
		"components.json: platforms of %s must list platforms of '%s', each once (no platforms: every platform)",
		[concat(" ", misplaced), names],
	)
}

lists_platforms(list) if {
	is_array(list)
	count(list) > 0
	count({p | some p in list}) == count(list)
	every p in list {
		p in platforms
	}
}

deny contains "platforms/ is missing: the tree is from before the platform layer, which the root chart and this check read" if {
	not gitops.is_dir("platforms")
}

deny contains msg if {
	gitops.is_dir("platforms")
	got := gitops.folders("platforms")
	got != names
	msg := sprintf(
		"platforms/ holds '%s': the platforms are exactly those of key platforms of components.json, '%s'",
		[got, names],
	)
}

deny contains msg if {
	not gitops.links_to("argocd/apps/files/platforms", "../../../platforms")
	msg := "argocd/apps/files/platforms must be a symlink to ../../../platforms, through which the root chart reads platforms/"
}

deny contains sprintf("platforms/%s: platforms/ holds a folder per platform (and README.md), the root reads nothing else there", [name]) if {
	some name in gitops.visible("platforms")
	name != "README.md"
	not gitops.is_dir(concat("/", ["platforms", name]))
}

# component_of(name): the component a file of a platform is for, by its name.
component_of(name) := trim_suffix(name, ".values.tpl") if endswith(name, ".values.tpl")

component_of(name) := trim_suffix(name, ".yaml") if endswith(name, ".yaml")

# platform_files: [platform, name] of each entry of the folder of a platform of the map, README.md and argo-cd.yaml
# aside.
platform_files contains [platform, name] if {
	some platform in platforms
	some name in gitops.visible(concat("/", ["platforms", platform]))
	not name in {"README.md", "argo-cd.yaml"}
}

deny contains msg if {
	some [platform, name] in platform_files
	not known(platform, name)
	msg := sprintf(
		"platforms/%s/%s: a file of a platform is README.md, <name>.yaml or <name>.values.tpl, <name> a component of components.json",
		[platform, name],
	)
}

known(platform, name) if {
	not gitops.is_dir(sprintf("platforms/%s/%s", [platform, name]))
	gitops.component(component_of(name))
}

deny contains sprintf("platforms/%s/%s: component %s does not run on %s (its platforms in components.json)", [platform, name, c, platform]) if {
	some [platform, name] in platform_files
	known(platform, name)
	c := component_of(name)
	not gitops.runs_on(c, platform)
}

# values_files: [path, name] of each file platforms/<platform>/<name>.yaml of any folder of platforms/.
values_files contains [path, trim_suffix(name, ".yaml")] if {
	some platform in gitops.visible("platforms")
	some name in gitops.visible(concat("/", ["platforms", platform]))
	endswith(name, ".yaml")
	path := sprintf("platforms/%s/%s", [platform, name])
	gitops.is_file(path)
}

deny contains sprintf("%s is no YAML map", [path]) if {
	some [path, _] in values_files
	not gitops.yaml_map(path)
}

deny contains msg if {
	some [path, name] in values_files
	"cluster" in object.keys(gitops.yaml_map(path))
	msg := sprintf(
		"%s sets cluster: what depends on the cluster reaches a component through platforms/<platform>/%s.values.tpl from the root's value cluster, which the bootstrap alone sets",
		[path, name],
	)
}

deny contains msg if {
	some [path, name] in values_files
	values := gitops.yaml_map(path)
	not "cluster" in object.keys(values)
	gitops.component(name).path == gitops.service_chart
	keys := gitops.overlay_keys(values)
	keys != ""
	msg := sprintf(
		"%s sets %s: a release's image is envs/<env>/images/%s.yaml, and every platform runs the base's canary",
		[path, keys, name],
	)
}
