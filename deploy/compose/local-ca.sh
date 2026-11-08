#!/usr/bin/env bash
# local-ca.sh DIR: the local CA of compose and the k3d cluster, and the one server certificate it signs, which the
# local Kafka and Valkey present; run by `make env` with DIR .local/ca. Writes ca.crt and server.crt (mode 644: public,
# mounted into the clients) and ca.key and server.key (mode 600). EC P-256 keys in PKCS#8, which openssl, Java's PEM
# key store, Go and Node all read.

# Run again, it changes nothing that is valid. A missing or expired CA makes a new CA and a new server certificate (a
# certificate signed by another CA would not verify). A missing server certificate or key, or one that no longer
# verifies against the CA (expired), makes a new server certificate signed by the CA there.
# Design notes: docs/explanation/deployment.md.
set -euo pipefail

dir=${1:?usage: local-ca.sh DIR}
umask 077
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The names clients use: the compose service, and the k3d Service in namespace svp-data in all its forms.
san=
for host in kafka valkey; do
  for suffix in "" .svp-data .svp-data.svc .svp-data.svc.cluster.local; do
    san="$san${san:+,}DNS:$host$suffix"
  done
done
san="$san,DNS:localhost"

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
subjectAltName = $san
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

new_server() {
  new_key "$work/server.key"
  openssl req -new -sha256 -key "$work/server.key" -subj "/CN=svp local server" -config "$work/openssl.cnf" \
    -out "$work/server.csr"
  openssl x509 -req -sha256 -days 825 -in "$work/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -extfile "$work/openssl.cnf" -extensions server -out "$work/server.crt" 2>/dev/null
  install -m 600 "$work/server.key" "$dir/server.key"
  install -m 644 "$work/server.crt" "$dir/server.crt"
}

if [[ ! -s $dir/ca.crt || ! -s $dir/ca.key ]] || ! openssl x509 -checkend 0 -noout -in "$dir/ca.crt" >/dev/null; then
  rm -f "$dir/server.crt" "$dir/server.key"
  new_ca
  new_server
  echo "wrote a new local CA and server certificate to $dir"
elif [[ ! -s $dir/server.crt || ! -s $dir/server.key ]] ||
  ! openssl verify -CAfile "$dir/ca.crt" "$dir/server.crt" >/dev/null 2>&1; then
  new_server
  echo "wrote a new server certificate to $dir, signed by the local CA there"
else
  echo "$dir already has a valid local CA and server certificate; left unchanged"
fi
