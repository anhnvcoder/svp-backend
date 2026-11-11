#!/usr/bin/env bash
# local-ca.sh DIR: the local CA of compose and the k3d cluster, and the two server certificates it signs: server.crt,
# which the local Kafka and Valkey present, and postgres.crt, which the local Postgres presents; run by `make env` with
# DIR .local/ca. Writes the certificates (mode 644: public, mounted into the clients) and their keys (mode 600). EC
# P-256 keys in PKCS#8, which openssl, Java's PEM key store, Go, Node and Postgres all read.

# Run again, it changes nothing that is valid. A missing or expired CA makes a new CA and both server certificates (a
# certificate signed by another CA would not verify). A missing server certificate or key, or one that no longer
# verifies against the CA (expired), makes that one certificate again, signed by the CA there; the other files stay.
# Design notes: docs/explanation/deployment.md.
set -euo pipefail

dir=${1:?usage: local-ca.sh DIR}
umask 077
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# sans HOST...: the subjectAltName of the names clients use for those hosts: the compose service, and the k3d Service in
# namespace svp-data in all its forms (Postgres is `postgres` in compose and Service svp-pg-rw of CloudNativePG in the
# cluster, so `postgres` gets no cluster forms), then localhost.
sans() {
  local san='' host suffix
  for host in "$@"; do
    if [[ $host == postgres ]]; then
      san="$san${san:+,}DNS:$host"
      continue
    fi
    for suffix in "" .svp-data .svp-data.svc .svp-data.svc.cluster.local; do
      san="$san${san:+,}DNS:$host$suffix"
    done
  done
  printf '%s,DNS:localhost' "$san"
}

cat >"$work/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = svp local
[ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $(sans kafka valkey)
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
[postgres]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = $(sans postgres svp-pg-rw)
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

new_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

new_ca() {
  new_key "$work/ca.key"
  openssl req -x509 -new -sha256 -days 3650 -key "$work/ca.key" -subj "/CN=svp local CA" \
    -config "$work/openssl.cnf" -extensions ca -out "$work/ca.crt"
  install -m 600 "$work/ca.key" "$dir/ca.key"
  install -m 644 "$work/ca.crt" "$dir/ca.crt"
}

# new_cert NAME: NAME.key and NAME.crt in DIR, signed by the CA there, with the extensions of section NAME above.
new_cert() {
  new_key "$work/$1.key"
  openssl req -new -sha256 -key "$work/$1.key" -subj "/CN=svp local $1" -config "$work/openssl.cnf" \
    -out "$work/$1.csr"
  openssl x509 -req -sha256 -days 825 -in "$work/$1.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/openssl.cnf" -extensions "$1" -out "$work/$1.crt" 2>/dev/null
  install -m 600 "$work/$1.key" "$dir/$1.key"
  install -m 644 "$work/$1.crt" "$dir/$1.crt"
}

certs=(server postgres)
if [[ ! -s $dir/ca.crt || ! -s $dir/ca.key ]] || ! openssl x509 -checkend 0 -noout -in "$dir/ca.crt" >/dev/null; then
  new_ca
  for name in "${certs[@]}"; do new_cert "$name"; done
  echo "wrote a new local CA and the server certificates ${certs[*]} to $dir"
  exit 0
fi
written=
for name in "${certs[@]}"; do
  if [[ ! -s $dir/$name.crt || ! -s $dir/$name.key ]] ||
    ! openssl verify -CAfile "$dir/ca.crt" "$dir/$name.crt" >/dev/null 2>&1; then
    new_cert "$name"
    written="$written $name"
  fi
done
if [[ -n $written ]]; then
  echo "wrote new server certificates to $dir, signed by the local CA there:$written"
else
  echo "$dir already has a valid local CA and server certificates; left unchanged"
fi
