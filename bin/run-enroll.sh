#!/usr/bin/env bash
# Re-run the enrollment playbook unattended (renews host certificates that are about to
# expire, re-applies CA trust and principals). Started daily by a systemd timer or cron.
set -euo pipefail

CONF=${ANSIBLE_STEP_CA_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=/dev/null
. "$CONF/config.env"
export PATH="$PATH:/usr/local/bin:$HOME/.local/bin"
export ANSIBLE_CONFIG="$INVENTORY_DIR/ansible.cfg"

cd -- "$INVENTORY_DIR"
exec "$ANSIBLE_PLAYBOOK" "$REPO_DIR/playbooks/enroll.yml" -e "@$CONF/enroll-vars.yml"
