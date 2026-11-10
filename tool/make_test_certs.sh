#!/usr/bin/env bash
# Generates self-signed certificate fixtures for server-trust tests.
#
# Fixtures produced:
#   a.pem / a.key   — cert A (RSA 2048 key)
#   b.pem / b.key   — cert B (a *different* key than A)
#   a-prime.pem     — cert A′ (same key as A, later validity window)
#   a-expired.pem   — cert A″ (same key as A, already expired)
#
# Idea under test: the SPKI pin is a digest of the *public key*. A and A′/A″
# share a key, so their pins are identical and "confirm once" holds across
# renewals; B uses a different key and must not match A's pin.
#
# These are TEST-ONLY keys. They are not secrets and must never be used
# anywhere real. Regenerating them is cheap and changes nothing — no other
# fixture depends on the actual key material, only the structural relations.
set -euo pipefail

cd "$(dirname "$0")/../test/fixtures/certs"
rm -rf work && mkdir -p work

gen() { # gen <name> <days-offset-around-now> <key-or-none>
  local name="$1" days="$2" key="$3"
  local key_args=()
  if [[ "$key" == "none" ]]; then
    openssl genrsa -out "work/$name.key" 2048 2>/dev/null
  else
    cp "$key" "work/$name.key"
  fi
  openssl req -new -x509 -key "work/$name.key" -out "work/$name.pem" \
    -subj "/CN=$name.test.invalid" \
    -addext "subjectAltName=DNS:$name.test.invalid,DNS:localhost" \
    -days "$days" 2>/dev/null
  cp "work/$name.key" "$name.key"
  cp "work/$name.pem" "$name.pem"
}

# A: valid now, 825 days.
gen a 825 none
# B: a different key, valid now.
gen b 825 none
# A′: same key as A, later window (still valid, 1500 days).
gen a-prime 1500 a.key
# A″: same key as A, already expired: set notBefore years ago, days negative
# is not supported by -days, so use -days with a start in the past via -not_before.
openssl req -new -x509 -key a.key -out work/a-expired.pem \
  -subj "/CN=a-expired.test.invalid" \
  -addext "subjectAltName=DNS:a-expired.test.invalid" \
  -days 30 \
  -not_before 20200101000000Z -not_after 20210101000000Z 2>/dev/null
cp work/a-expired.pem a-expired.pem
cp a.key a-expired.key

rm -rf work
echo "Certificates written to test/fixtures/certs/"
