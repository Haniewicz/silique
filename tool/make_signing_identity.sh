#!/usr/bin/env bash
# Generuje WYŁĄCZNIE parę podpisu macOS: RSA 2048, certyfikat self-signed
# CN=Silique (3650 dni), eksport silique-publisher.p12 + silique-publisher.crt
# i wypisuje SHA-256 liścia certyfikatu. To jest nowa tożsamość podpisu macOS;
# Android pozostaje bez zmian (ten sam keystore, CN=Nova Notes, alias nova-notes)
# i ten skrypt w ogóle go nie dotyka.
#
# SEKRETY: klucz prywatny i hasło NIE mogą trafić do repo. Hasło pochodzi
# wyłącznie ze zmiennej środowiskowej SILIQUE_MACOS_P12_PASSWORD; nic nie jest
# zapisywane do Gita. Wyjście trafia do katalogu podanego jako jedyny argument
# (poza drzewem repo — trzymaj je obok Androida, np. ~/.local/share/silique-signing/).
#
# Po wygenerowaniu skopiuj wypisany SHA-256 do DOKŁADNIE tych trzech miejsc,
# inaczej nowy DMG odrzuci własną weryfikację (testy będą zielone i bezużyteczne):
#   1. tool/macos_dmg.py        -> PUBLISHER_CERTIFICATE_SHA256
#   2. tool/test_macos_dmg.py   -> oczekiwany pin/Authority w testach
#   3. tool/test_branding_compatibility.py -> pin w 'tool/macos_dmg.py'
# SHA-1 z `-fingerprint -sha1` trafia do designated requirement w tool/sign_macos.py.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Użycie: $0 KATALOG_DOCELOWY" >&2
  echo "  KATALOG_DOCELOWY tworzy silique-publisher.p12, silique-publisher.crt" >&2
  echo "  (oraz klucz tymczasowy; trzymaj to POZA repozytorium)." >&2
  exit 2
fi

if [[ -z "${SILIQUE_MACOS_P12_PASSWORD:-}" ]]; then
  echo "Ustaw hasło: export SILIQUE_MACOS_P12_PASSWORD='...'" >&2
  echo "Hasło nigdy nie trafia do repo ani do logów." >&2
  exit 2
fi

out="$(realpath -m "$1")"
umask 077
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/silique-identity.XXXXXX")"
trap 'rm -rf "$work"' EXIT

key="$work/silique-publisher.key"
crt="$out/silique-publisher.crt"
p12="$out/silique-publisher.p12"
openssl genrsa -out "$key" 2048
openssl req -new -x509 -key "$key" -out "$crt" \
  -subj "/CN=Silique" \
  -days 3650 \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"
openssl pkcs12 -export -inkey "$key" -in "$crt" -out "$p12" \
  -name "Silique macOS publisher" -passout "pass:$SILIQUE_MACOS_P12_PASSWORD"

echo "Wygenerowano macOS identity (self-signed, CN=Silique):"
echo "  certyfikat: $crt"
echo "  PKCS#12:    $p12"
echo "SHA-256 liścia certyfikatu (wpisz do trzech miejsc wymienionych w komentarzu):"
openssl x509 -in "$crt" -outform DER | sha256sum | awk '{print $1}'
echo "SHA-1 (designated requirement w tool/sign_macos.py):"
openssl x509 -in "$crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':'
