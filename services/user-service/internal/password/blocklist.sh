#!/usr/bin/env bash
# blocklist.sh: writes blocklist.txt next to it from the NCSC 100k list of SecLists at a pinned commit. Run by hand when
# the source changes; the output is committed, and a rerun gives the same bytes. The download is data only: it is
# checked against src_sha256 before use and nothing in it is run.

# Source: the 100 000 most used passwords the UK NCSC published from Have I Been Pwned data, through SecLists at the
# commit in src_url. Contains public sector information licensed under the Open Government Licence v3.0:
# https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/

# Rules, one entry per line: drop the CR of a CRLF line end, trim leading and trailing spaces and tabs, drop empty lines
# and lines with any byte outside printable ASCII (0x20-0x7E: invalid UTF-8, and non-ASCII letters that byte-wise
# lowercasing would leave apart from Go's strings.ToLower), lowercase A-Z, keep 8 to 128 characters (password.MinLength,
# password.MaxLength), sort by byte (LC_ALL=C, as Go compares strings) and drop duplicates.

# Lines shaped like an email address (local@domain.tld) are dropped too: the file is public, and such an entry may be
# someone's real address.

# want_lines and want_sha256 describe blocklist.txt; the Go tests read them, so change them with the file.
set -euo pipefail

src_url=https://raw.githubusercontent.com/danielmiessler/SecLists/1a7bb9127eca9e6ff2fc0301c597fe6e16a0cb56/Passwords/Common-Credentials/100k-most-used-passwords-NCSC.txt
src_sha256=c2e5696882c603b76bb67a47ee970897e5a76fc4c3f5547abe3d0ca340c576e0
want_lines=46449
want_sha256=b91281a2b64db6ffe53df4d4e0fe3a2bac37ae174c6b771fd9f9b4de06852359

fail() {
  echo "blocklist.sh: $*" >&2
  exit 1
}

dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o "$work/source.txt" "$src_url" || fail "download of $src_url failed"
got=$(shasum -a 256 "$work/source.txt" | cut -d' ' -f1)
[ "$got" = "$src_sha256" ] || fail "source sha256 is $got, want $src_sha256"

LC_ALL=C awk '
  { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
  $0 == "" || /[^ -~]/ { next }
  { $0 = tolower($0) }
  /^[^@]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z][a-z]+$/ { next }
  length($0) >= 8 && length($0) <= 128 { print }
' "$work/source.txt" | LC_ALL=C sort -u >"$work/blocklist.txt"

lines=$(wc -l <"$work/blocklist.txt" | tr -d ' ')
[ "$lines" = "$want_lines" ] || fail "blocklist.txt would have $lines lines, want $want_lines"
got=$(shasum -a 256 "$work/blocklist.txt" | cut -d' ' -f1)
[ "$got" = "$want_sha256" ] || fail "blocklist.txt would have sha256 $got, want $want_sha256"
mv "$work/blocklist.txt" "$dir/blocklist.txt"
echo "wrote $dir/blocklist.txt: $lines lines, sha256 $got"
