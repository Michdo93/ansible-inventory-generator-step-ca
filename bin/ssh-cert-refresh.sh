#!/usr/bin/env bash
# Request a fresh short-lived SSH user certificate for the control node key from step-ca.
# Installed into the ansible-step-ca configuration directory and run by a systemd timer
# or cron job. Configuration: config.env next to this script (or $ANSIBLE_STEP_CA_DIR).
set -euo pipefail

CONF=${ANSIBLE_STEP_CA_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=/dev/null
. "$CONF/config.env"
export STEPPATH="$CONF/step"
export PATH="$PATH:/usr/local/bin:$HOME/.local/bin"

[[ -r $KEY_FILE.pub ]] || { echo "Public key $KEY_FILE.pub not found." >&2; exit 1; }
[[ -r $CONF/provisioner-password ]] || { echo "Missing $CONF/provisioner-password." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -- "$KEY_FILE.pub" "$tmp/key.pub"
args=()
for principal in $PRINCIPALS; do args+=(--principal "$principal"); done

if ! step ssh certificate "$KEY_ID" "$tmp/key.pub" --sign --force \
    --provisioner "$PROVISIONER" --provisioner-password-file "$CONF/provisioner-password" \
    --not-after "$USER_CERT_DURATION" "${args[@]}" >"$tmp/out" 2>&1; then
  cat "$tmp/out" >&2
  exit 1
fi
install -m 0644 "$tmp/key-cert.pub" "$KEY_FILE-cert.pub.new"
mv -f -- "$KEY_FILE-cert.pub.new" "$KEY_FILE-cert.pub"
valid=$(ssh-keygen -L -f "$KEY_FILE-cert.pub" | sed -n 's/^ *Valid: //p')
echo "SSH certificate $KEY_FILE-cert.pub ($PRINCIPALS) $valid"
