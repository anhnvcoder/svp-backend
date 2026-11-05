# shellcheck shell=bash
# Helpers of the drill tests that talk to the web client (threat model 4.9) on cluster svp: web-7-web-2 and web-8 of
# deploy/k8s/drills/threats/. A script of such a test sources this file from its test's folder (Chainsaw runs it there):
# `. ./web.sh` in web-7-web-2, `. ../web-7-web-2/web.sh` in web-8. Written for bash 3.2 (the macOS /bin/bash).
#
# Every file the helpers write is private (umask 077) and lives in the test's own work directory, $work:
# .k8s/drills/<folder of the test> (ignored by git), made by the test's first step and removed by its cleanup. The
# drill user's credentials and session cookie (cookie jar $work/web.jar), the curl configs that carry form fields and
# the session's tokens read from Valkey stay there and are never printed: a script prints statuses, codes and the names
# of what it found, not values.
#
# The script's environment needs CALLER_KUBECONFIG, the caller's kubeconfig (empty: ~/.kube/config): Chainsaw sets
# KUBECONFIG to its own copy of the cluster (templates/probe-up.yaml says why). kubectl always names context k3d-svp;
# curl takes the cluster's CA from CURL_CA_BUNDLE, which the make target sets.

umask 077
: "${CALLER_KUBECONFIG?the env of the script sets CALLER_KUBECONFIG to the caller KUBECONFIG}"
export KUBECONFIG="$CALLER_KUBECONFIG"

work="$(git rev-parse --show-toplevel)/.k8s/drills/$(basename "$PWD")"

ok() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1" >&2
  exit 1
}
kc() { kubectl --context k3d-svp "$@"; }

# The gateway behind Envoy, the web client (listener https-apex of Gateway svp) and the object store's route, which is
# the same site as the web client.
api_base=https://api.svp.localhost:8443
web_base=https://svp.localhost:8443
s3_origin=https://s3.svp.localhost:8443
web_cookie=__Host-Http-svp_sid
# The web pods: a Rollout's, so kubectl exec names a pod, not deploy/web.
web_selector=app.kubernetes.io/name=web,app.kubernetes.io/component=server

# work_ready: the work directory exists (the test's first step made it); fails otherwise.
work_ready() { [[ -d $work ]] || fail "the test's work directory ${work#"$(git rev-parse --show-toplevel)"/} exists (made by its first step)"; }

# web_get PATH OUT [CURL_ARGS...] / web_post PATH OUT [CURL_ARGS...]: a request to the web client with the drill user's
# session (the private cookie jar $work/web.jar, kept up to date; web_jar names another one, such as an empty one for a
# logged-out request); the body goes to OUT, the response headers to OUT.headers, and the HTTP status is printed (000
# when nothing answered). Accept-Language en: the form errors the tests read are the English copy. Redirects are not
# followed.
web_get() { web_curl GET "$@"; }
web_post() { web_curl POST "$@"; }
web_curl() {
  local method=$1 path=$2 out=$3 jar=${web_jar:-$work/web.jar}
  shift 3
  : >"$out"
  touch "$jar"
  curl -sS --max-time 15 -X "$method" -o "$out" -D "$out.headers" -w '%{http_code}' -b "$jar" -c "$jar" \
    -H 'Accept-Language: en' "$@" "$web_base$path" || true
}

# web_sid: the session id in the cookie jar, "" when there is none. Never printed: callers only test or hash it.
web_sid() {
  [[ -f $work/web.jar ]] || return 0
  awk -F '\t' -v n="$web_cookie" '$6 == n { v = $7 } END { print v }' "$work/web.jar"
}

# form_fields HTML_FILE: the hidden inputs of the form that has a password field in HTML_FILE, as curl config lines
# (form-string = "NAME=VALUE", HTML entities decoded); fails when there is none. A form whose action is a Server Action
# carries the action's id and bound state in such inputs ($ACTION_...), which is how a browser without JavaScript posts
# it: a multipart POST of those fields and the user's, to the page's own URL.
form_fields() {
  perl -0777 -ne '
    my $form;
    while (/(<form\b.*?<\/form>)/sg) { my $f = $1; if ($f =~ /name="password"/) { $form = $f; last } }
    defined $form or exit 1;
    my $n = 0;
    while ($form =~ /<input\b([^>]*)>/sg) {
      my $a = $1;
      next unless $a =~ /\btype="hidden"/;
      my ($name) = $a =~ /\bname="([^"]*)"/ or next;
      my ($value) = $a =~ /\bvalue="([^"]*)"/;
      $value = "" unless defined $value;
      for ($name, $value) {
        s/&quot;/"/g; s/&#x27;|&#39;/\x27/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/&/g;
        s/\\/\\\\/g; s/"/\\"/g;
      }
      print "form-string = \"$name=$value\"\n";
      $n++;
    }
    exit($n ? 0 : 1);
  ' "$1"
}

# web_form_config PAGE FIELDS_FILE OUT: a curl config (written to OUT) that posts the form of PAGE as a browser without
# JavaScript does, with the fields of FIELDS_FILE (a JSON object, as web_user writes credentials: values reach curl in
# this private file, never on a command line). No Origin or Sec-Fetch-Site: the caller adds them. Reads the page first
# (with the session of the cookie jar, or of web_jar).
web_form_config() {
  local status
  status=$(web_get "$1" "$work/form.html")
  [[ $status == 200 ]] || fail "GET $1 of the web client is 200 (status $status)"
  {
    echo "url = \"$web_base$1\""
    echo 'header = "Accept-Language: en"'
    form_fields "$work/form.html" || fail "the form of $1 has hidden Server Action fields"
    jq -r 'to_entries[] | "form-string = \("\(.key)=\(.value)" | @json)"' "$2"
  } >"$3"
}

# web_form PAGE FIELDS_FILE: posts the form of PAGE (web_form_config) with the session of the cookie jar and the app's own
# Origin, as the CSRF check wants; the answer goes to $work/form.out, and form_status is set to the HTTP status: 303 when
# the action redirects (signed in), 200 when the form comes back with an error. Sets a variable instead of printing: a
# fail inside $(...) would only end the subshell. Call it as a plain command.
web_form() {
  web_form_config "$1" "$2" "$work/form.curl"
  : >"$work/form.out"
  form_status=$(curl -sS --max-time 15 -o "$work/form.out" -w '%{http_code}' -b "$work/web.jar" -c "$work/web.jar" \
    -K "$work/form.curl" -H "Origin: $web_base" || true)
}

# form_error FILE: the error the form with a password field in FILE shows, by its English copy (messages/en/auth.json):
# wrong-credentials, rate-limited, unavailable (the box of the whole form, role="alert", by its title), email-taken,
# handle-taken, invalid (the red note under a field, class text-danger), other (an alert or note with other copy), none
# (neither), no-form (FILE has no such form: a redirect, an error page). Only the form's own markup is read: every
# page of /login and /register also carries all the auth messages, unrendered, in its RSC payload (scripts outside the
# form), so a search of the whole page finds "Wrong email or password" in a form that shows nothing.
form_error() {
  perl -0777 -ne '
    my $form;
    while (/(<form\b.*?<\/form>)/sg) { my $f = $1; if ($f =~ /name="password"/) { $form = $f; last } }
    defined $form or do { print "no-form\n"; exit 0 };
    my $alert = $form =~ /\brole="alert"[^>]*>(.*?)<\/strong>/s ? $1 : "";
    my $notes = join " ", $form =~ /<p\b[^>]*\bclass="[^"]*\btext-danger\b[^"]*"[^>]*>(.*?)<\/p>/sg;
    s/<[^>]*>//g for $alert, $notes;
    if ($alert =~ /Wrong email or password/) { print "wrong-credentials\n" }
    elsif ($alert =~ /Too many tries/) { print "rate-limited\n" }
    elsif ($alert =~ /The service is busy/) { print "unavailable\n" }
    elsif ($notes =~ /This email is already in use/) { print "email-taken\n" }
    elsif ($notes =~ /This username is taken/) { print "handle-taken\n" }
    elsif ($notes =~ /Enter a valid email|The password needs|A username needs/) { print "invalid\n" }
    elsif ($alert =~ /\S/ || $notes =~ /\S/) { print "other\n" }
    else { print "none\n" }
  ' "$1"
}

# web_user: the test's web user, registered through the web client's /register form on first use (the register action
# logs the new user in); its credentials and handle stay in $work/web.cred, its session in the cookie jar. A user whose
# session is gone (logged out) is replaced by a new one.
web_user() {
  local handle email
  [[ -s $work/web.cred && -n $(web_sid) ]] && return 0
  handle=drill_$(openssl rand -hex 6)
  email="drill-web-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)@example.test"
  DRILL_PASSWORD=$(openssl rand -hex 16) jq -n --arg e "$email" --arg h "$handle" \
    '{email: $e, password: env.DRILL_PASSWORD, handle: $h}' >"$work/web-new.cred"
  : >"$work/web.jar"
  web_form /register "$work/web-new.cred"
  [[ $form_status == 303 && -n $(web_sid) ]] ||
    fail "register a user through the web client's /register form: 303 with cookie $web_cookie (status $form_status, form error $(form_error "$work/form.out"))"
  mv "$work/web-new.cred" "$work/web.cred"
  ok "user @$handle registered through the web client's /register form (no JavaScript, Server Action): 303, session cookie $web_cookie in the test's cookie jar"
}

# web_logout: logs the web session of the cookie jar out, if there is one (the session lives 30 days); a logout that
# does not answer 303 is printed as info, the session then ends with its TTL.
web_logout() {
  [[ -n $(web_sid) ]] || return 0
  if [[ $(web_post /logout "$work/web-logout" -H "Sec-Fetch-Site: same-origin" -H "Origin: $web_base") == 303 ]]; then
    ok "web session of the drill user logged out"
  else
    echo "info  the web session's logout did not answer 303: it ends with its TTL"
  fi
}

# web_tokens: the drill user's web session, read from Valkey db 9 (key svp:web:sess:<SHA-256 of the sid>, the web
# client's session store; only this user's key is read), as "NAME<TAB>VALUE" lines in $work/web.tokens: access-token,
# refresh-token, sid. The values stay in that private file; the sid reaches jq through its environment.
web_tokens() {
  local sid key
  sid=$(web_sid)
  [[ -n $sid ]] || fail "the web session cookie is in the test's cookie jar"
  key="svp:web:sess:$(printf '%s' "$sid" | shasum -a 256 | cut -c1-64)"
  kc -n svp-data exec deploy/valkey -c valkey -- valkey-cli -n 9 GET "$key" >"$work/web.session" ||
    fail "read the drill user's web session in Valkey db 9"
  WEB_SID=$sid jq -r '"access-token\t\(.access_token // "")", "refresh-token\t\(.refresh_token // "")", "sid\t\(env.WEB_SID)"' \
    "$work/web.session" >"$work/web.tokens" 2>/dev/null || : >"$work/web.tokens"
  rm -f "$work/web.session"
  [[ $(awk -F '\t' '$2 != ""' "$work/web.tokens" | wc -l | tr -d ' ') == 3 ]] ||
    fail "the drill user's web session in Valkey db 9 (svp:web:sess:<SHA-256 of the sid>) has an access and a refresh token"
}

# holds VALUES_FILE FILE: the names of the values of VALUES_FILE ("NAME<TAB>VALUE[<TAB>i]" lines; i: any case) that
# FILE holds, space-separated, "" when none. awk reads the values from the file, never from its command line.
holds() {
  awk -F '\t' 'NR == FNR { n++; name[n] = $1; val[n] = $2; ci[n] = ($3 == "i"); next }
    { s = s $0 "\n" }
    END {
      l = tolower(s)
      for (i = 1; i <= n; i++) {
        if (val[i] == "") continue
        if (ci[i] ? index(l, tolower(val[i])) : index(s, val[i])) out = out " " name[i]
      }
      print substr(out, 2)
    }' "$1" "$2"
}

# jwt_shaped FILE: true when FILE holds a string shaped like a JWT: eyJ (base64url of {") and three dot-separated
# base64url parts, as every token of the gateway is.
jwt_shaped() { grep -qE 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$1"; }

# rand_uuid: a random id in the canonical UUID form (the BFF's id pattern).
rand_uuid() { openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})/\1-\2-\3-\4-/'; }

# web_pods: "NAME IP" of every running web pod.
web_pods() {
  kc -n svp get pods -l "$web_selector" --field-selector status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}'
}
