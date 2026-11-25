# The wave rule of the startup taint on platform eks: a component pinned to Karpenter's nodes waits for what lifts it.
# Design notes: docs/reference/ci.md.
package gitops.platforms

import data.gitops

# Karpenter's nodes register with startup taint cni.istio.io/not-ready. istiod (taint.enabled) removes it once istio-cni
# and ztunnel are Ready on the node, so a pod pinned to those nodes stays Pending, and its Application never Healthy,
# until the three are installed: the pinned component must not sit in an earlier wave than any of them.
taint_platform := "eks"

taint_removers := ["istiod", "istio-cni", "ztunnel"]

# wave_of(name): the wave of component name, 0 when it sets none.
wave_of(name) := object.get(gitops.component(name), "wave", 0)

# values_docs(name): the YAML maps of the values files of component name on eks that can be read: its base file and the
# overlay of the platform. A *.values.tpl is a Go template, read only when it is valid YAML as written.
values_docs(name) := [doc |
	some path in values_paths(name)
	gitops.is_file(path)
	doc := gitops.yaml_map(path)
]

values_paths(name) := array.concat(
	[p | p := object.get(gitops.component(name), "values", ""); p != ""],
	[
		$"platforms/{taint_platform}/{name}.yaml",
		$"platforms/{taint_platform}/{name}.values.tpl",
	],
)

# pins_karpenter(doc): a pod pinned to Karpenter's nodes at any depth of values doc, in one of two forms: a term of a
# required node affinity with key karpenter.sh/nodepool and Exists or In (DoesNotExist keeps a pod off them, and a
# preferred term pins nothing), or a nodeSelector with that key.
pins_karpenter(doc) if {
	walk(doc, [path, term])
	term.key == "karpenter.sh/nodepool"
	term.operator in {"Exists", "In"}
	not "preferredDuringSchedulingIgnoredDuringExecution" in path
}

pins_karpenter(doc) if {
	walk(doc, [_, node])
	is_object(node.nodeSelector)
	"karpenter.sh/nodepool" in object.keys(node.nodeSelector)
}

# eks_envs: the environments that run on the taint platform.
eks_envs := object.get(object.get(object.get(gitops.components_doc, "platforms", {}), taint_platform, {}), "envs", [])

# A file of the chain base < platform < envs/<env>/ that pins is a pin, whatever a later file says (no reasoning about
# a file that lifts the pin). A pin of base or platform holds in every env; one only of an overlay, in that env.
base_pinned contains c.name if {
	some c in gitops.components
	gitops.runs_on(c.name, taint_platform)
	some doc in values_docs(c.name)
	pins_karpenter(doc)
}

pin_sites contains {"name": name, "env": ""} if some name in base_pinned

pin_sites contains {"name": c.name, "env": env} if {
	some c in gitops.components
	gitops.runs_on(c.name, taint_platform)
	not c.name in base_pinned
	some env in eks_envs
	path := $"envs/{env}/{c.name}.yaml"
	gitops.is_file(path)
	pins_karpenter(gitops.yaml_map(path))
}

pinned := sort({site.name | some site in pin_sites})

# site_label(wave, env): the wave of a pinned component, with the env when only that env's overlay pins it.
site_label(wave, "") := $"wave {wave}"

site_label(wave, env) := $"wave {wave}, env {env}" if env != ""

# lifts(name): component name runs on eks and, for istiod, enables taint removal in its values (the overlay of the
# platform over the base).
lifts(name) if {
	name != "istiod"
	gitops.runs_on(name, taint_platform)
}

lifts("istiod") if {
	gitops.runs_on("istiod", taint_platform)
	docs := values_docs("istiod")
	enabled := [doc.taint.enabled | some doc in docs]
	enabled[count(enabled) - 1] == true
}

deny contains msg if {
	some site in pin_sites
	name := site.name
	some remover in taint_removers
	lifts(remover)
	name_wave := wave_of(name)
	remover_wave := wave_of(remover)
	name_wave < remover_wave
	msg := sprintf(
		concat("", [
			"%s: %s (%s) is pinned to Karpenter's nodes, whose startup taint cni.istio.io/not-ready %s (wave %d) lifts ",
			"once it runs: %s cannot become Healthy before, so give it a wave of at least %d",
		]),
		[gitops.components_file, name, site_label(name_wave, site.env), remover, remover_wave, name, remover_wave],
	)
}

# A taint that nothing lifts leaves every pinned pod Pending for good.
deny contains msg if {
	count(pinned) > 0
	some remover in taint_removers
	not lifts(remover)
	msg := sprintf(
		concat("", [
			"%s: %s is pinned to Karpenter's nodes, whose startup taint cni.istio.io/not-ready is never lifted: ",
			"%s is no component that runs on %s%s",
		]),
		[gitops.components_file, concat(" ", pinned), remover, taint_platform, lift_missing(remover)],
	)
}

lift_missing("istiod") := " with taint.enabled: true in its values"

lift_missing(name) := "" if name != "istiod"
