# Ansible Inventory Generator – step-ca variant

Entry point for running Ansible with **short-lived SSH certificates from [step-ca](https://smallstep.com/docs/step-ca/)** instead of static public keys copied to every host.

It builds on [ansible-inventory-generator](https://github.com/Michdo93/ansible-inventory-generator) (inventory, dedicated account, become password in Ansible Vault) and then switches every host to certificate authentication:

| | Static keys (`ansible-inventory-generator`) | step-ca (this repository) |
| --- | --- | --- |
| Ansible logs in with | control node key in every `authorized_keys` | a user certificate valid for **4 hours**, refreshed every hour |
| Hosts trust | each copied public key | the SSH **user CA** (`TrustedUserCAKeys`) plus an explicit principal per account |
| Revoking access | remove the key on every host | stop issuing certificates – the last one expires within hours |
| Host fingerprints | accepted on first contact (`accept-new`) | **host certificates** signed by the host CA; the control node trusts the CA (`@cert-authority`), so no fingerprint prompt ever |
| Become password | Ansible Vault | Ansible Vault (unchanged) |

step-ca should run on a host other than the control node. Either use an existing step-ca with SSH enabled, or let this tool set one up on a host from the inventory.

## How it works

```text
            (1) JWK provisioner, password file          step-ca (CA host)
 control node ───────────────────────────────────────► SSH user CA + host CA
   │  ~/.ssh/id_ed25519-cert.pub  ◄── 4 h user certificate, renewed hourly
   │
   │ (2) Ansible: enroll.yml
   ├──► every host: /etc/ssh/ssh_user_ca.pub          (TrustedUserCAKeys)
   │                /etc/ssh/auth_principals/<user>   (AuthorizedPrincipalsFile)
   │                /etc/ssh/ssh_host_*_key-cert.pub  (HostCertificate, 30 days, renewed daily)
   │                static control node key removed from authorized_keys
   └──► ~/.ssh/known_hosts: @cert-authority <inventory hosts> <host CA key>
```

1. **Inventory**: `ansible-inventory-generator` onboards hosts as before (dedicated account such as `ansible` or `sysadmin`, sudo rule, Vault). During the bootstrap the control node key is still installed, so the first contact needs nothing from the CA.
2. **CA**: an existing step-ca (URL, root fingerprint, provisioner, password) or `playbooks/ca-setup.yml` on a chosen inventory host.
3. **Control node certificate**: `step ssh certificate` signs the control node key for the principals = the `ansible_user` values of the inventory. `ssh` and Ansible use `<key>-cert.pub` automatically – `ansible.cfg` does not change.
4. **Enrollment** (`playbooks/enroll.yml`), per host:
   - install the user CA and an `AuthorizedPrincipalsFile` containing only the Ansible account's principal,
   - sign every SSH host key (re-signed when missing, expiring, issued by another CA or with outdated names),
   - add the sshd settings (`/etc/ssh/sshd_config.d/05-ansible-step-ca.conf`, validated with `sshd -t`, reverted on error),
   - **verify a login that uses nothing but the user certificate and the host certificate**,
   - only then remove the static control node key from `authorized_keys`.
5. **Timers** on the control node: the user certificate is refreshed every hour; `enroll.yml` runs daily and renews host certificates 10 days before they expire.

## Requirements

- Control node: everything `ansible-inventory-generator` needs (Bash, OpenSSH, Python 3, `ansible-core`, `sshpass`), plus the `step` CLI (installed from GitHub on request) and `curl`.
- Managed hosts: Linux with OpenSSH (Debian family via the bootstrap repositories). Windows OpenSSH is supported by the playbooks but **not yet tested** (needs `ansible-galaxy collection install ansible.windows`).
- CA host (when set up by this tool): Linux with internet access to GitHub releases; systemd for the service.

Recommended layout – the scripts find each other and use these local copies:

```bash
mkdir ansible-tools && cd ansible-tools
for r in ansible-inventory-generator-step-ca ansible-inventory-generator ssh-ansible-bootstrap-manager \
         ansible-linux-bootstrap ansible-kali-bootstrap ansible-windows-bootstrap; do
  git clone https://github.com/Michdo93/$r
done
```

Missing sibling repositories are cloned into `vendor/` automatically.

## Run

```bash
chmod +x ansible-inventory-generator-step-ca/generate-inventory-step-ca.sh
./ansible-inventory-generator-step-ca/generate-inventory-step-ca.sh
```

The script asks for:

1. running the inventory generator (scan, admin login, account name and password – see its README),
2. the CA: existing step-ca, or set-up on an inventory host (name and port, default `9000`),
3. whether to remove the static control node key after a successful certificate login (default: yes).

| Option | Meaning |
| --- | --- |
| `--inventory DIR` | inventory directory (default `./inventory`, or `$OUTPUT_DIR`) |
| `--skip-generator` | use the existing inventory, only (re-)enroll |
| `--limit PATTERN` | enroll only these hosts |
| `--keep-static-keys` | keep the control node key in `authorized_keys` (certificates *and* key work) |
| `--no-timers` | do not install the systemd timers / cron jobs |
| `--reconfigure-ca` | ask for the CA again (switch to another CA) |

Afterwards Ansible is used exactly as before:

```bash
cd inventory
ansible all -m ping
ansible all -b -m ansible.builtin.apt -a 'update_cache=yes upgrade=dist'
```

Adding hosts later: run the script again. Hosts that already accept certificates are left unchanged; new hosts are bootstrapped with the key, enrolled and switched to certificates.

## Files on the control node

`~/.config/ansible-step-ca/` (or `$ANSIBLE_STEP_CA_DIR`), mode 0700:

| File | Content |
| --- | --- |
| `config.env` | CA URL, root fingerprint, provisioner, key, principals, durations, inventory path |
| `provisioner-password` | password of the JWK provisioner (0600) – needed to request certificates unattended |
| `step/` | `STEPPATH` of the step CLI (root certificate, CA URL) |
| `ssh-cert-refresh.sh` | requests a new user certificate (run hourly) |
| `run-enroll.sh` | runs `enroll.yml` unattended (run daily) |
| `enroll-vars.yml` | variables for `enroll.yml` |

Timers: `ansible-step-ca-user-cert.timer` and `ansible-step-ca-enroll.timer` (systemd, `systemctl list-timers 'ansible-step-ca-*'`), or cron entries marked `# ansible-step-ca` when systemd is not available. The daily enrollment needs a stored Vault password (`vault_password_file` in `ansible.cfg`); without it the script warns and only installs the hourly refresh.

## CA set-up (`playbooks/ca-setup.yml`)

Installs `step` and `step-ca` from the GitHub releases, initialises a CA with SSH support under `/etc/step-ca` (service account `step`, systemd unit `step-ca.service`), and configures:

- a JWK provisioner `ansible-ssh` (user certificates: default 4 h, max 24 h; host certificates: default 30 days, max 90 days),
- an **authority policy**: SSH user certificates may only contain the Ansible account names (`ca_user_principals`); host certificates for any name except `localhost` (restrict with `ca_host_allow_dns` / `ca_host_allow_ips`).

Passwords are generated on the CA host and stay there (`/etc/step-ca/*.txt`); only the provisioner password is copied to the control node. Re-running the playbook updates the policy – the entry script does this automatically when the inventory gets a new `ansible_user`. Principals listed in `/etc/step-ca/extra-principals` are kept; [ansible-ssh-key-distribution-step-ca](https://github.com/Michdo93/ansible-ssh-key-distribution-step-ca) maintains that file for the certificates it hands out to other accounts.

Using an existing step-ca instead: it needs SSH enabled (`step ca init --ssh`), a JWK provisioner with SSH certificates, and the account names allowed as user principals, e.g. in `ca.json`:

```json
"authority": {
  "policy": {
    "ssh": {
      "user": { "allow": { "principal": ["ansible"] } },
      "host": { "deny":  { "dns": ["localhost"] } }
    }
  }
}
```

Without a policy a JWK provisioner signs **any** principal it is asked for (including `root`); the hosts still only accept the principal listed in their `AuthorizedPrincipalsFile`, but a policy on the CA is strongly recommended.

## Security notes

- `AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u` is set globally. Accounts without such a file cannot log in with certificates at all; key and password logins are not affected.
- The provisioner password on the control node is equivalent to the ability to obtain certificates for the allowed principals. Protect the control node; rotate the password with `step ca provisioner update` on the CA if it is exposed.
- **Break glass**: if the CA is unavailable, certificates expire within 4 hours. Ansible access can be restored with the static-key path – run `ansible-inventory-generator` (or `ssh-ansible-bootstrap-manager`) with the admin password; the next enrollment run switches the host back to certificates.
- sshd uses the *first* value of `TrustedUserCAKeys` / `AuthorizedPrincipalsFile`. The playbook checks `sshd -T` and stops if another configuration file overrides them.

## Repository layout

```text
ansible-inventory-generator-step-ca/
├── generate-inventory-step-ca.sh     entry point
├── lib/step-ca-lib.sh                helpers (step CLI, config, timers)
├── bin/ssh-cert-refresh.sh           hourly user certificate refresh
├── bin/run-enroll.sh                 daily enrollment run
└── playbooks/
    ├── vars.yml                      shared defaults
    ├── ca-setup.yml                  install/initialise step-ca on an inventory host
    ├── enroll.yml                    CA trust, principals, host certificates, verification
    ├── files/cert_status.py          host key / certificate state (Linux)
    └── tasks/                        Linux and Windows task files
```

## Tested

On Ubuntu 24.04 hosts (separate containers with their own sshd): CA set-up on a managed host, bootstrap with an admin account, enrollment of three hosts, certificate-only login (login without certificate refused), `become` through the Vault, removal of the static key, no fingerprint prompt thanks to the host CA, refused `root` principal, host certificate renewal, idempotent re-runs (`changed=0`), adding a host later, switching to an existing CA. Not tested: Windows hosts and the systemd timer units (the cron installation and the scripts the timers call were tested).
