#!/usr/bin/env bash
# Ansible Inventory Generator - step-ca variant. Run on the Ansible control node.
#
#   1. ansible-inventory-generator onboards the hosts (dedicated account, sudo/Vault)
#   2. step-ca: an existing CA, or one set up on an inventory host (playbooks/ca-setup.yml)
#   3. the control node gets a short-lived SSH user certificate (refreshed hourly)
#   4. playbooks/enroll.yml makes every host trust the user CA, signs its host keys,
#      verifies a certificate-only login and removes the static control node key
#   5. timers keep the user certificate and the host certificates fresh
#
# Usage: ./generate-inventory-step-ca.sh [--inventory DIR] [--skip-generator] [--limit PATTERN]
#                                        [--keep-static-keys] [--no-timers] [--reconfigure-ca]
set -uo pipefail

SC_REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/step-ca-lib.sh
source "$SC_REPO_DIR/lib/step-ca-lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

INVENTORY_DIR=${OUTPUT_DIR:-./inventory}
skip_generator=false keep_static=false no_timers=false reconfigure=false limit=''
while (($#)); do
  case $1 in
    --inventory) INVENTORY_DIR=${2:-}; shift 2 ;;
    --skip-generator) skip_generator=true; shift ;;
    --limit) limit=${2:-}; shift 2 ;;
    --keep-static-keys) keep_static=true; shift ;;
    --no-timers) no_timers=true; shift ;;
    --reconfigure-ca) reconfigure=true; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage 2 ;;
  esac
done

GEN_DIR=$(sc_find_repo ansible-inventory-generator generate-inventory.sh) || exit 1
MGR_DIR=$(sc_find_repo ssh-ansible-bootstrap-manager lib/bootstrap-lib.sh) || exit 1
export BOOTSTRAP_MANAGER_DIR=$MGR_DIR
# shellcheck source=/dev/null
source "$MGR_DIR/lib/bootstrap-lib.sh"

for cmd in python3 ansible-playbook ansible-vault ssh-keygen; do
  command -v "$cmd" >/dev/null 2>&1 || sc_die "$cmd is required (sudo apt install ansible-core python3 openssh-client)."
done
bm_check_dependencies || exit 1
bm_ensure_keypair || exit 1
sc_ensure_step

# ------------------------------------------------------------------ 1. inventory ---
install -d -m 0700 "$INVENTORY_DIR" || sc_die "Cannot create $INVENTORY_DIR"
INVENTORY_DIR=$(cd -- "$INVENTORY_DIR" && pwd)
INVENTORY=$INVENTORY_DIR/hosts.ini
if [[ $skip_generator != true ]]; then
  default=y; [[ -e $INVENTORY ]] && default=n
  if bm_ask_yes_no "Run ansible-inventory-generator now to add or update hosts in $INVENTORY?" "$default"; then
    OUTPUT_DIR=$INVENTORY_DIR BM_KEY_FILE=$BM_KEY bash "$GEN_DIR/generate-inventory.sh" || sc_die 'The inventory generator failed.'
  fi
fi
[[ -r $INVENTORY ]] || sc_die "No inventory at $INVENTORY. Run without --skip-generator first."
INV_PRINCIPALS=$(sc_inventory_users "$INVENTORY")
[[ -n $INV_PRINCIPALS ]] || sc_die "No ansible_user found in $INVENTORY."

export ANSIBLE_CONFIG=$INVENTORY_DIR/ansible.cfg
vault_args=()
grep -q '^vault_password_file' "$ANSIBLE_CONFIG" 2>/dev/null || vault_args=(--ask-vault-pass)
run_playbook() { (cd -- "$INVENTORY_DIR" && ansible-playbook "${vault_args[@]}" "$@"); }

# ------------------------------------------------------------------------ 2. CA ---
old_principals=''
have_ca=false
sc_load_config && have_ca=true   # also restores earlier answers (REMOVE_STATIC_KEY, durations, ...)
if [[ $have_ca == true && $reconfigure != true ]]; then
  old_principals=${PRINCIPALS_SAVED:-}
  sc_info "Using step-ca $CA_URL (fingerprint ${CA_FINGERPRINT:0:16}..., provisioner $PROVISIONER)."
else
  CA_HOST=''
  printf '\nstep-ca issues the SSH certificates. It should run on a host other than the control node.\n'
  printf '  1) use an existing step-ca (SSH enabled)\n  2) set up step-ca on a host of the inventory\n'
  sc_ask 'Choose' 2
  if [[ $REPLY == 1 ]]; then
    sc_ask 'CA URL (e.g. https://ca.lab:9000)'; CA_URL=$REPLY
    sc_ask 'Root certificate fingerprint (step certificate fingerprint root_ca.crt)'; CA_FINGERPRINT=$REPLY
    sc_ask 'JWK provisioner with SSH enabled' ansible-ssh; PROVISIONER=$REPLY
    until bm_read_secret_confirmed "Password of the provisioner $PROVISIONER"; do :; done
    install -d -m 0700 "$SC_DIR"; (umask 077; printf '%s\n' "$BM_SECRET" > "$SC_DIR/provisioner-password"); BM_SECRET=''
    sc_warn "The CA must allow the SSH user principals: $INV_PRINCIPALS (authority policy in ca.json)."
  else
    printf '\nInventory hosts:\n'; sc_inventory_hosts "$INVENTORY" | nl -w3 -s') '
    sc_ask 'Inventory name of the CA host'; CA_HOST=$REPLY
    sc_inventory_hosts "$INVENTORY" | awk '{print $1}' | grep -qxF -- "$CA_HOST" || sc_die "$CA_HOST is not in $INVENTORY."
    sc_ask 'CA port' 9000; ca_port=$REPLY
    principals_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$INV_PRINCIPALS")
    run_playbook "$SC_REPO_DIR/playbooks/ca-setup.yml" -e "ca_host=$CA_HOST" -e "ca_port=$ca_port" \
      -e "{\"ca_user_principals\": $principals_json}" -e "ssh_ca_dir=$SC_DIR" || sc_die 'step-ca setup failed.'
    # shellcheck source=/dev/null
    . "$SC_DIR/ca-info.env"
  fi
  old_principals=$INV_PRINCIPALS
fi
PRINCIPALS=$INV_PRINCIPALS
export STEPPATH=$SC_DIR/step
step ca bootstrap --ca-url "$CA_URL" --fingerprint "$CA_FINGERPRINT" --force >/dev/null 2>&1 \
  || sc_die "Cannot reach or verify step-ca at $CA_URL (check URL, fingerprint, firewall)."
[[ -n $(step ssh config --roots 2>/dev/null) ]] || sc_die "step-ca at $CA_URL has no SSH CA (initialise it with --ssh)."

# The CA host from step 2 is managed here: keep its principal policy in sync with the inventory.
if [[ -n ${CA_HOST:-} && $old_principals != "$PRINCIPALS" ]]; then
  principals_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$PRINCIPALS")
  sc_info "Updating the CA policy for the principals: $PRINCIPALS"
  run_playbook "$SC_REPO_DIR/playbooks/ca-setup.yml" -e "ca_host=$CA_HOST" -e "{\"ca_user_principals\": $principals_json}" \
    -e "ssh_ca_dir=$SC_DIR" >/dev/null || sc_die 'Updating the CA policy failed.'
fi

# ---------------------------------------------------------- 3. control node certificate ---
KEY_FILE=$BM_KEY
KEY_ID=${KEY_ID:-$(id -un)@$(hostname -s 2>/dev/null || uname -n)}
USER_CERT_DURATION=${USER_CERT_DURATION:-4h}
HOST_CERT_DURATION=${HOST_CERT_DURATION:-720h}
HOST_CERT_RENEW_BEFORE=${HOST_CERT_RENEW_BEFORE:-240h}
if [[ $keep_static == true ]]; then REMOVE_STATIC_KEY=false
elif [[ -z ${REMOVE_STATIC_KEY:-} ]]; then
  REMOVE_STATIC_KEY=true
  bm_ask_yes_no 'Remove the static control node key from the hosts after a successful certificate login?' y || REMOVE_STATIC_KEY=false
fi
sc_save_config
printf 'CA_HOST=%q\nPRINCIPALS_SAVED=%q\n' "${CA_HOST:-}" "$PRINCIPALS" >> "$SC_DIR/config.env"
"$SC_DIR/ssh-cert-refresh.sh" || sc_die "step-ca refused the user certificate (are the principals '$PRINCIPALS' allowed by the CA policy?)."

# ------------------------------------------------------------------------- 4. timers ---
if [[ $no_timers != true ]]; then
  with_enroll=true
  if [[ ${#vault_args[@]} -gt 0 ]]; then
    with_enroll=false
    sc_warn 'No stored Vault password: host certificates are not renewed automatically. Re-run this script within 20 days or store the Vault password.'
  fi
  sc_install_timers "$with_enroll" || true
fi

# ------------------------------------------------------------------------- 5. enroll ---
printf '\nEnrolling hosts (CA trust, principals, host certificates, certificate login test)...\n'
run_playbook "$SC_REPO_DIR/playbooks/enroll.yml" -e "@$SC_DIR/enroll-vars.yml" ${limit:+--limit "$limit"}
rc=$?

printf '\nControl node certificate: %s-cert.pub (principals: %s, %s, refreshed hourly)\n' "$KEY_FILE" "$PRINCIPALS" "$USER_CERT_DURATION"
printf 'Configuration: %s\n' "$SC_DIR"
if ((rc == 0)); then
  printf 'All selected hosts accept step-ca certificates. Use the inventory as before:\n  cd %q && ansible all -m ping\n' "$INVENTORY_DIR"
else
  printf 'Some hosts failed (see above). Hosts that failed keep their static key; fix the cause and re-run with --skip-generator.\n'
fi
exit "$rc"
