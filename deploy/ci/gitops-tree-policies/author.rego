# The author of a pull request (input.pull_request). A bot's pull request merges with no review where no code owner
# owns the files (envs/stg/), so a bot's token, leaked or misused, may change only what that bot promotes. Each file
# the pull request of a bot (a login ending in [bot]) changes is judged with the table of release sources of the
# revision its environment pins (input.sources): the bot <promoter>[bot] of source N changes envs/stg/images/<svc>.yaml
# and envs/prd/images/<svc>.yaml with <svc> in N's services; the bot of backend, whose repository holds the charts,
# also envs/stg/charts.yaml, envs/prd/charts.yaml and every image file of envs/prd/images/ (the promote to prd copies
# the whole set of stg, web's included); nothing else, and no such bot deletes a file. A bot that promotes no source
# (Renovate) changes nothing under envs/. A person's pull request is not limited here. A bot that caused the event
# (the sender: who opened the pull request or pushed the commit checked) other than the author fails, since the files
# allowed are the author's.
package gitops.author

import data.gitops

pr := input.pull_request

bot(login) if endswith(login, "[bot]")

deny contains msg if {
	foreign_sender
	msg := sprintf(
		"the commit checked was pushed by %s onto the pull request of %s: a bot pushes onto its own pull requests only, since the files allowed are the author's",
		[pr.sender, pr.author],
	)
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
	msg := sprintf(
		"the release sources of the charts of envs/%s cannot be read (above), so neither can which files %s may change",
		[env, pr.author],
	)
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

deny contains sprintf("%s: changed by %s, a bot that promotes no release source: such a bot changes nothing under envs/", [c.path, pr.author]) if {
	not promoter
	some c in changes
	startswith(c.path, "envs/")
}

# target(path): the environment of a file a promoter may change, with the service of an image file.
target(path) := {"env": env} if {
	some env in gitops.environments
	path == sprintf("envs/%s/charts.yaml", [env])
}

target(path) := {"env": env, "service": svc} if {
	some env in gitops.environments
	prefix := sprintf("envs/%s/images/", [env])
	startswith(path, prefix)
	endswith(path, ".yaml")
	svc := trim_suffix(trim_prefix(path, prefix), ".yaml")
	svc != ""
}

deny contains msg if {
	promoter
	some c in changes
	not target(c.path)
	msg := sprintf(
		"%s: changed by %s, the bot of a release source: it changes envs/<env>/images/<service>.yaml of its own services only (the bot of %s also envs/<env>/charts.yaml and envs/prd/images/)",
		[c.path, pr.author, gitops.chart_source],
	)
}

# source(env): the release source of the environment's table that the author promotes.
source(env) := s if {
	some s in input.sources[env].sources
	s.promoter == login
}

deny contains msg if {
	promoter
	some c in changes
	env := target(c.path).env
	not source(env)
	msg := sprintf("%s: changed by %s, which promotes no release source of the charts envs/%s runs (%s)", [
		c.path, pr.author, env, substring(input.sources[env].revision, 0, 12),
	])
}

# judged_changes: [change, its target, the source the author promotes there].
judged_changes contains [c, t, s] if {
	promoter
	some c in changes
	t := target(c.path)
	s := source(t.env)
}

who(s) := sprintf("%s, the bot of release source %s", [pr.author, s.name])

deny contains sprintf("%s: deleted by %s: a bot changes files under envs/, never deletes one", [c.path, who(s)]) if {
	some [c, _, s] in judged_changes
	c.status == "D"
}

deny contains msg if {
	some [c, t, s] in judged_changes
	c.status != "D"
	not t.service
	s.name != gitops.chart_source
	msg := sprintf(
		"%s: changed by %s: only the bot of %s, whose repository holds the charts, changes charts.yaml",
		[c.path, who(s), gitops.chart_source],
	)
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
