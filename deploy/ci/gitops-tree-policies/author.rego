# Pull requests of bots (a login ending in [bot]) merge with no review where no code owner owns the files (envs/stg/),
# so a bot may change only what it promotes under envs/, and delete nothing; a person's pull request is not limited.
# A bot that caused the event (the sender) other than the author fails, since the files allowed are the author's.
# Design notes: docs/reference/ci.md.
package gitops.author

import data.gitops

pr := input.pull_request

bot(login) if endswith(login, "[bot]")

deny contains msg if {
	foreign_sender
	msg := $"the commit checked was pushed by {pr.sender} onto the pull request of {pr.author}: a bot pushes onto its own pull requests only, since the files allowed are the author's"
}

foreign_sender if {
	bot(pr.sender)
	pr.sender != pr.author
}

# judged: the files of the pull request are held to the rule: its author is a bot, which pushed the commit checked.
judged if {
	bot(pr.author)
	not foreign_sender
}

unread contains env if {
	judged
	some env in gitops.environments
	not input.sources[env].sources
}

deny contains msg if {
	some env in unread
	msg := $"the release sources of the charts of envs/{env} cannot be read (above), so neither can which files {pr.author} may change"
}

# changes: the files of the pull request to judge, once every table is read.
changes := pr.changes if {
	judged
	count(unread) == 0
}

login := trim_suffix(pr.author, "[bot]")

promoters contains s.promoter if {
	some env in gitops.environments
	some s in input.sources[env].sources
	is_string(s.promoter)
}

promoter if login in promoters

deny contains $"{c.path}: changed by {pr.author}, a bot that promotes no release source: such a bot changes nothing under envs/" if {
	not promoter
	some c in changes
	startswith(c.path, "envs/")
}

target(path) := {"env": env} if {
	some env in gitops.environments
	path == $"envs/{env}/charts.yaml"
}

target(path) := {"env": env, "service": svc} if {
	endswith(path, ".yaml")
	some env in gitops.environments
	prefix := $"envs/{env}/images/"
	startswith(path, prefix)
	svc := trim_suffix(trim_prefix(path, prefix), ".yaml")
	svc != ""
}

deny contains msg if {
	promoter
	some c in changes
	not target(c.path)
	msg := concat("", [
		$"{c.path}: changed by {pr.author}, the bot of a release source: it changes envs/<env>/images/<service>.yaml ",
		$"of its own services only (the bot of {gitops.chart_source} also envs/<env>/charts.yaml and envs/prd/images/)",
	])
}

source(env) := s if {
	some s in input.sources[env].sources
	s.promoter == login
}

deny contains msg if {
	promoter
	some c in changes
	env := target(c.path).env
	not source(env)
	msg := $"{c.path}: changed by {pr.author}, which promotes no release source of the charts envs/{env} runs ({substring(input.sources[env].revision, 0, 12)})"
}

judged_changes contains [c, t, s] if {
	promoter
	some c in changes
	t := target(c.path)
	s := source(t.env)
}

who(s) := $"{pr.author}, the bot of release source {s.name}"

deny contains $"{c.path}: deleted by {who(s)}: a bot changes files under envs/, never deletes one" if {
	some [c, _, s] in judged_changes
	c.status == "D"
}

deny contains msg if {
	some [c, t, s] in judged_changes
	c.status != "D"
	not t.service
	s.name != gitops.chart_source
	msg := $"{c.path}: changed by {who(s)}: only the bot of {gitops.chart_source}, whose repository holds the charts, changes charts.yaml"
}

deny contains msg if {
	some [c, t, s] in judged_changes
	c.status != "D"
	_ = t.service
	not allowed(t, s)
	msg := sprintf(
		"%s: changed by %s, which publishes %s: it changes the image files of those services only",
		[c.path, who(s), concat(" ", s.services)],
	)
}

allowed(t, s) if t.service in s.services

# The promote to prd copies every image file of stg, those of other sources too.
allowed(t, s) if {
	t.env == "prd"
	s.name == gitops.chart_source
	t.service in gitops.services
}
