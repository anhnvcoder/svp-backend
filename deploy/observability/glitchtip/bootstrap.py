# Creates what the services and the drills need in GlitchTip, through the image's ORM: the admin user, organization,
# team and project `svp` with its DSN, the API token `svp-drill` (event:read, project:read) and the API token
# `svp-sourcemaps` (project:releases) that uploads the web client's source maps.
# Idempotent: a second run creates nothing and changes no key, token or password.

# Run inside the glitchtip-init container: python manage.py shell < /init/bootstrap.py
# Reads GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD. When SVP_GLITCHTIP_OUT names a file, writes the DSN and
# the two tokens there (mode 600) for deploy/observability/glitchtip/init.sh, never printed. Prints only counts.
# Design notes: docs/explanation/observability.md.
import os

from allauth.account.models import EmailAddress

from apps.api_tokens.models import APIToken
from apps.organizations_ext.models import Organization, OrganizationUser
from apps.projects.models import Project, ProjectKey
from apps.teams.models import Team
from apps.users.models import User

SLUG = "svp"
TOKEN_LABEL = "svp-drill"
TOKEN_SCOPES = ["event:read", "project:read"]
# The one scope GlitchTip asks of the source map upload: its chunk upload and its artifact bundle assemble
# endpoints accept project:releases (or project:write, project:admin, which also change projects). It reads no
# event, so the drills keep their own read-only token.
SOURCEMAPS_TOKEN_LABEL = "svp-sourcemaps"
SOURCEMAPS_TOKEN_SCOPES = ["project:releases"]

email = os.environ["GLITCHTIP_ADMIN_EMAIL"]
password = os.environ["GLITCHTIP_ADMIN_PASSWORD"]
if not email or not password:
    raise SystemExit("bootstrap: GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD must be set")

# Admin user. The password is set only when the user is created, so a password changed in the UI stays.
admin, created = User.objects.get_or_create(email=email)
if created:
    admin.set_password(password)
    admin.is_staff = True
    admin.is_superuser = True
    admin.save()
EmailAddress.objects.get_or_create(
    user=admin, email=email, defaults={"primary": True, "verified": True}
)

# Organization, with the admin as a member (the first member becomes its owner).
org, _ = Organization.objects.get_or_create(slug=SLUG, defaults={"name": SLUG})
org_user = OrganizationUser.objects.filter(organization=org, user=admin).first()
if org_user is None:
    org_user = org.add_user(admin)

# One project for every service (the `service` tag tells them apart), in team `svp`. Creating the project
# creates its key.
project, _ = Project.objects.get_or_create(
    organization=org, slug=SLUG, defaults={"name": SLUG, "platform": "go"}
)
team, _ = Team.objects.get_or_create(organization=org, slug=SLUG)
team.members.add(org_user)
team.projects.add(project)
key = ProjectKey.objects.filter(project=project, is_active=True).order_by("pk").first()
if key is None:
    raise SystemExit("bootstrap: project svp has no active key")
dsn = key.get_dsn()
if not dsn:
    raise SystemExit("bootstrap: GLITCHTIP_DOMAIN gives no DSN")

# Read-only API token of the drills, looked up by its label alone: after GLITCHTIP_ADMIN_EMAIL changes, the
# token made for the previous admin (still a member of the organization) stays the one, instead of a second one
# beside it. Among several (a run from before this rule), the oldest, the one deploy/k8s/glitchtip-init.sh
# also reads. The model generates a random token.
token = APIToken.objects.filter(label=TOKEN_LABEL).order_by("pk").first()
if token is None:
    token = APIToken.objects.create(user=admin, label=TOKEN_LABEL)
token.add_permissions(TOKEN_SCOPES)

# Write token of the source map upload, looked up the same way as the drills' token.
sourcemaps_token = (
    APIToken.objects.filter(label=SOURCEMAPS_TOKEN_LABEL).order_by("pk").first()
)
if sourcemaps_token is None:
    sourcemaps_token = APIToken.objects.create(user=admin, label=SOURCEMAPS_TOKEN_LABEL)
sourcemaps_token.add_permissions(SOURCEMAPS_TOKEN_SCOPES)

out = os.environ.get("SVP_GLITCHTIP_OUT")
if out:
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(
            f"dsn={dsn}\ntoken={token.token}\nsourcemaps_token={sourcemaps_token.token}\n"
        )

print(
    "bootstrap: users={} organizations={} members={} teams={} projects={} active_keys={} tokens={} sourcemaps_tokens={}".format(
        User.objects.filter(email=email).count(),
        Organization.objects.filter(slug=SLUG).count(),
        OrganizationUser.objects.filter(organization=org, user=admin).count(),
        Team.objects.filter(organization=org, slug=SLUG).count(),
        Project.objects.filter(organization=org, slug=SLUG).count(),
        ProjectKey.objects.filter(project=project, is_active=True).count(),
        APIToken.objects.filter(label=TOKEN_LABEL).count(),
        APIToken.objects.filter(label=SOURCEMAPS_TOKEN_LABEL).count(),
    )
)
