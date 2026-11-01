#!/usr/bin/env bash
# Generates all deployment secrets into ./secrets (git-ignored).
#   - database password
#   - core master key (32 random bytes, base64)  -> encrypts credentials at rest
#   - internal CA + server cert + web client cert (ECDSA P-256) for mTLS between web and server
#
# Refuses to overwrite existing secrets unless --force is given.
# IMPORTANT: back up secrets/core_master_key SEPARATELY from database backups (see docs/SECURITY.md).
set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

cd "$(dirname "$0")/.."
umask 077
mkdir -p secrets/ca
chmod 0700 secrets secrets/ca

if [[ -e secrets/core_master_key && $FORCE -eq 0 ]]; then
  echo "secrets/ already initialized. Use --force to regenerate (this INVALIDATES existing encrypted data)." >&2
  exit 1
fi
# With --force, previous files may be read-only (0400): remove them first.
rm -f secrets/db_password secrets/core_master_key secrets/internal_* secrets/ca/*

# --- random secrets ---------------------------------------------------------
openssl rand -base64 32 | tr -d '\n' > secrets/db_password
openssl rand -base64 32 | tr -d '\n' > secrets/core_master_key

# --- internal CA ------------------------------------------------------------
openssl ecparam -name prime256v1 -genkey -noout -out secrets/ca/ca.key
openssl req -x509 -new -key secrets/ca/ca.key -sha256 -days 3650 \
  -subj "/CN=postflowx-internal-ca" -out secrets/internal_ca.crt

issue() { # issue <name> <CN> <extKeyUsage> <SAN or empty>
  local name="$1" cn="$2" eku="$3" san="$4" ext
  ext="$(mktemp)"
  { echo "basicConstraints=CA:FALSE"; echo "extendedKeyUsage=${eku}"
    if [[ -n "$san" ]]; then echo "subjectAltName=${san}"; fi; } > "$ext"
  openssl ecparam -name prime256v1 -genkey -noout -out "secrets/internal_${name}.key"
  openssl req -new -key "secrets/internal_${name}.key" -subj "/CN=${cn}" -out "secrets/internal_${name}.csr"
  openssl x509 -req -in "secrets/internal_${name}.csr" -CA secrets/internal_ca.crt -CAkey secrets/ca/ca.key \
    -CAcreateserial -CAserial secrets/ca/ca.srl -out "secrets/internal_${name}.crt" -days 365 -sha256 -extfile "$ext"
  rm -f "$ext" "secrets/internal_${name}.csr"
}

issue server postflowx-server serverAuth "DNS:server,DNS:postflowx-server"
issue web    postflowx-web    clientAuth ""

# --- permissions ------------------------------------------------------------
# secrets/ itself is 0700 (host-level protection). Server-side secrets are 0400 and are read by the
# watchdog (root + CAP_DAC_READ_SEARCH) and re-homed per process; the web container has a single
# unprivileged process, so its certificate files must be readable by that user (0444 inside the 0700 dir).
chmod 0400 secrets/db_password secrets/core_master_key secrets/internal_server.key secrets/ca/ca.key
chmod 0444 secrets/internal_ca.crt secrets/internal_server.crt secrets/internal_web.crt secrets/internal_web.key

echo "Secrets written to ./secrets"
echo "  * Back up secrets/core_master_key SEPARATELY from database backups."
echo "  * Keep secrets/ca/ca.key offline; it is not mounted into any container."
