#!/bin/sh
# aclfile.sh ENV_FILE OUT: writes the ACL file of the compose Valkey to OUT (mode 600), run by `make up` with .env and
# .local/valkey/users.acl; tls-init puts it into the server's volume. One user per client, with the same access string
# word for word that ElastiCache gets as aws_elasticache_user.access_string, and its password from ENV_FILE; user
# default is off.

# ENV_FILE is read with the strict rule of deploy/observability/glitchtip/dotenv.sh, as compose reads it; a password
# must be letters and digits only (`make env` writes hex), since the file has no quoting. Nothing is printed of a
# password, and none is on a command line (printf is a shell builtin). POSIX sh, like the rest of make's recipes.
# Design notes: docs/explanation/deployment.md.
set -eu

env_file=${1:?usage: aclfile.sh ENV_FILE OUT}
out=${2:?usage: aclfile.sh ENV_FILE OUT}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/observability/glitchtip/dotenv.sh
. "$here/../observability/glitchtip/dotenv.sh"

umask 077
mkdir -p "$(dirname "$out")"
tmp=$(mktemp "$out.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# line USER VARIABLE ACCESS_STRING: the line of USER, with the password in VARIABLE of ENV_FILE.
line() {
  pw=$(dotenv_value "$env_file" "$2") || exit 1
  case $pw in
    '' | *[!A-Za-z0-9]*) echo "aclfile.sh: $2 is missing, empty or holds a character other than a letter or digit in $env_file; run make env" >&2; exit 1 ;;
  esac
  printf 'user %s %s >%s\n' "$1" "$3" "$pw" >>"$tmp"
}

line svp-gateway SVP_VALKEY_GATEWAY_PASSWORD \
  'on ~svp:gw:* resetchannels db=10 -@all +select +client|setinfo +eval +evalsha +time +get +set +del'
line svp-feed-service SVP_VALKEY_FEED_SERVICE_PASSWORD \
  'on ~svp:feed:* resetchannels db=14 -@all +select +client|setinfo +get +set'
line svp-web SVP_VALKEY_WEB_PASSWORD \
  'on ~svp:web:* resetchannels db=9 -@all +select +client|setinfo +eval +get +set +del +exists'
line svp-ops SVP_VALKEY_OPS_PASSWORD \
  'on ~svp:* resetchannels db=9,10,14 -@all +select +ping +time +scan +get +mget +pttl (~svp:gw:rl:register:* resetchannels db=10 -@all +del) (~svp:feed:explore:* resetchannels db=14 -@all +del)'
echo 'user default off' >>"$tmp"
mv "$tmp" "$out"
