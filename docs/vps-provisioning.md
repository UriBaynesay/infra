# VPS Provisioning & Hardening Runbook

The reproducible record of how the project's first VPS (`vpa-1`, Hetzner
Cloud) was provisioned and hardened, 2026-09-10. Every command that was run
on the box is here, in order, with what it does and why. Re-runnable on a
fresh Ubuntu 24.04 VPS from scratch.

Decisions behind each choice (why Hetzner, why Ubuntu LTS, why a non-root
user, etc.) live in the **Infra Knowledge** Google Doc — this file is the
*how*, that doc is the *why*.

---

## 0. Provider & server creation (Hetzner Cloud console)

Done through `console.hetzner.cloud`, not a CLI. Choices made:

| Setting | Value | Reason (short) |
|---|---|---|
| Location | Falkenstein (`fsn1`) | Any EU location fine; latency to user is negligible for one low-traffic app + admin work. |
| Image | Ubuntu 24.04 LTS | LTS = 5-year support, no forced major upgrades. 24.04 (not the newer 26.04) is old enough that tutorials/tooling have caught up. |
| Type | `CX23`, Cost-Optimized, x86 | Cost-Optimized is ~3.5× cheaper than Regular Performance here (€6.49 vs ~$23/mo) for near-identical specs; "limited availability" only affects *creating/resizing* more Cost-Optimized servers later, not a running box. x86 over ARM to avoid a whole class of "no arm64 build" friction on a first server. |
| Networking | Public IPv4 **+** IPv6 | Keep the IPv4 (~€0.60/mo) — an IPv6-only box is painful to reach (home ISPs, some mirrors/registries still lack clean IPv6). |
| SSH key | `hetzner_vpa` public key attached | Attaching a key ⇒ server is key-only, **no root password emailed** — nothing to brute-force. |
| Backups | **declined** | ~20% surcharge; relying on app code in git. The owner has also decided against app-level database backups, so database contents are not backed up anywhere. |
| Firewalls (Hetzner Cloud Firewall) | **skipped at create time** | Add the network-level firewall later, once Docker + the app define which ports to open. Host `ufw` covers the baseline now. |
| Volumes, Placement groups, Labels, Cloud config | skipped | Not relevant for one hand-provisioned box. |

### Local SSH key generation (on the workstation, once)

```bash
ssh-keygen -t ed25519 -C "uri552@gmail.com" -f ~/.ssh/hetzner_vpa -N ""
```

- `-t ed25519` — modern key type: short, fast, at least as strong as RSA.
- `-C "..."` — a comment label (cosmetic; not used for auth).
- `-f ~/.ssh/hetzner_vpa` — output path. Named for the **provider + project**,
  not any one app — a VPS access key is an infra concern.
- `-N ""` — no passphrase. Simpler for a first box; a passphrase-protected
  key + ssh-agent is a reasonable later upgrade.

Produces `~/.ssh/hetzner_vpa` (private — never leaves the machine) and
`~/.ssh/hetzner_vpa.pub` (public — the string pasted into Hetzner).

### Local SSH config (on the workstation)

`~/.ssh/config`:

```
Host vpa
    HostName 178.105.102.146
    User uri
    IdentityFile ~/.ssh/hetzner_vpa
```

Lets you connect with just `ssh vpa`. `User` was `root` for the very first
connection, changed to `uri` after step 3 below.

---

## 1. First connection & full system update

```bash
ssh vpa                 # first time: accept the host-key fingerprint prompt ("yes")
```

First connect records the server's host key in `~/.ssh/known_hosts` — SSH's
check that the server is who it claims to be on every later connection.

```bash
apt update && apt upgrade -y
```

- `apt update` — refresh the list of available package versions (installs
  nothing).
- `apt upgrade -y` — install newer versions of everything currently
  installed; `-y` auto-confirms.
- `&&` — only upgrade if update succeeded.
- Most important security step: a freshly-built image is always behind on
  patches, and unpatched known CVEs are the #1 way servers get compromised.

This pulled a new kernel (`6.8.0-138` → `139`). A running kernel can't be
swapped without a reboot:

```bash
reboot
```

Session drops; wait ~30s; `ssh vpa` again. Verify:

```bash
uname -r        # -> 6.8.0-139-generic (new kernel active)
uptime          # confirms the box just restarted
```

---

## 2. Create a non-root user with sudo

Why: `root` does anything instantly with no undo — one mistyped destructive
command wrecks the box. A normal user + `sudo` adds deliberate friction to
system-level actions and lets root SSH login be disabled entirely (root is
the universal brute-force target).

```bash
adduser uri
```

Interactive:
- Sets a **password** — *not* used for SSH (that stays key-only), but
  **required for `sudo`**. Set a real one, remember it.
- Prompts for Full Name / Room / Phone — press Enter through all (unused).
- "Is the information correct? [Y/n]" — Enter.

```bash
usermod -aG sudo uri
```

- `-aG sudo` — **append** the user **to the group** `sudo`. On Ubuntu, `sudo`
  group membership grants sudo rights.
- `-a` is critical: without it, `-G` *replaces* all the user's groups.

```bash
groups uri      # -> uri sudo users
```

---

## 3. Give `uri` SSH key access

Only `root` had the key (Hetzner put it in `/root/.ssh/authorized_keys` at
create time). `uri` needs its own copy with strict permissions or SSH
refuses it.

```bash
mkdir -p /home/uri/.ssh
cp ~/.ssh/authorized_keys /home/uri/.ssh/authorized_keys
chown -R uri:uri /home/uri/.ssh
chmod 700 /home/uri/.ssh
chmod 600 /home/uri/.ssh/authorized_keys
```

- `chown -R uri:uri` — `uri` must own these (root created them).
- `chmod 700` on the dir / `600` on the file — accessible **only by `uri`**.
  SSH silently ignores keys if the `.ssh` dir or `authorized_keys` is
  group/world-accessible.

Then, updated `~/.ssh/config` on the workstation: `User root` → `User uri`.

**Test from a second terminal, keeping the root session open** as a fallback:

```bash
ssh uri@178.105.102.146 -i ~/.ssh/hetzner_vpa   # should log straight in ($ prompt)
whoami            # -> uri
sudo whoami       # prompts for uri's password, then -> root
```

---

## 4. Lock down SSH

Modern Ubuntu reads drop-in files from `/etc/ssh/sshd_config.d/` — don't
edit the main `sshd_config`.

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
```

- `sudo tee <file>` — write to a root-owned file (a plain `>` redirect isn't
  run as root even under `sudo`; `tee` is).
- `<<'EOF' ... EOF` — heredoc; the quoted `'EOF'` means no variable
  expansion inside.
- `> /dev/null` — discard tee's echo of the content.
- `PermitRootLogin no` — kills the #1 brute-force target.
- `PasswordAuthentication no` — key-only; no password guessing possible for
  any account.

```bash
sudo sshd -t                    # validate config — NO output means valid. Fix errors before restarting.
sudo systemctl restart ssh      # existing sessions survive a restart
```

**Test from a fresh terminal before trusting it:**

```bash
ssh vpa                                          # still works (uri, key)
ssh root@178.105.102.146 -i ~/.ssh/hetzner_vpa   # -> Permission denied (publickey)  ✓ root is blocked
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|pubkeyauthentication'
#   permitrootlogin no / passwordauthentication no / pubkeyauthentication yes
```

`sshd -T` dumps the *effective* running config, not just file contents.

Once confirmed, the original root terminal can be closed — `ssh vpa` is the
new safety net.

---

## 5. Host firewall (`ufw`)

`ufw` ("Uncomplicated Firewall") fronts the kernel packet filter. Goal:
default-deny all inbound, allow only what's needed.

**Ordering matters** — allow SSH *before* enabling, or you lock yourself out.

```bash
sudo ufw allow OpenSSH        # named profile = inbound TCP 22 (== `ufw allow 22/tcp`)
sudo ufw show added           # confirm the OpenSSH rule is staged BEFORE enabling
sudo ufw enable               # warns about disrupting SSH — answer "y"; current session survives
sudo ufw status verbose
```

Expected end state:
```
Status: active
Default: deny (incoming), allow (outgoing), disabled (routed)
22/tcp (OpenSSH)       ALLOW IN    Anywhere
22/tcp (OpenSSH (v6))  ALLOW IN    Anywhere (v6)
```

`allow (outgoing)` is kept — the box still needs to reach out for `apt`,
Docker pulls, etc.

**Test `ssh vpa` from a new terminal** immediately after enabling.

---

## 6. Automatic security updates

```bash
sudo apt install -y unattended-upgrades          # usually already present on Ubuntu Server
sudo dpkg-reconfigure -plow unattended-upgrades   # answer "Yes" to the enable prompt
cat /etc/apt/apt.conf.d/20auto-upgrades
#   APT::Periodic::Update-Package-Lists "1";
#   APT::Periodic::Unattended-Upgrade "1";
```

Default behaviour (correct, leave as-is): applies **security** updates only,
daily; does **not** auto-reboot for kernel updates (that stays a manual
decision). Check `/etc/apt/apt.conf.d/50unattended-upgrades` — the
`-security` origin is enabled, `-updates` is commented out.

---

## 7. Swap file (2 GB)

The box has 3.7 GB RAM and shipped with **zero swap**. Without swap, a memory
spike triggers the kernel OOM-killer, which kills a process outright (often
the biggest — e.g. the database). Swap turns "process killed" into "briefly
slow." 2 GB is the standard size for a box this size.

```bash
sudo fallocate -l 2G /swapfile      # reserve 2 GB instantly (no zero-writing)
sudo chmod 600 /swapfile            # root-only — swap can hold memory contents
sudo mkswap /swapfile               # format as swap
sudo swapon /swapfile               # activate now
free -h                             # -> Swap: 2.0Gi

echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # persist across reboots
cat /etc/fstab                      # confirm the line is there exactly once
```

Tune swap eagerness (server-appropriate):

```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system | grep swappiness       # -> vm.swappiness = 10
```

`swappiness` 0–100 = how eagerly the kernel moves idle RAM to swap. Default
60 suits desktops; **10** = "only swap when actually needed" is the common
server value.

*(Note: the 2 GB swap file counts against disk usage — `Usage of /` jumps
~5%. Expected.)*

---

## 8. Hostname

```bash
sudo hostnamectl set-hostname vpa-1              # writes /etc/hostname, applies live
sudo sed -i 's/ubuntu-4gb-fsn1-2/vpa-1/g' /etc/hosts   # keep local self-resolution working
cat /etc/hosts                                   # 127.0.1.1 line now -> vpa-1
exit && ssh vpa                                  # prompt becomes uri@vpa-1:~$
```

---

## Final baseline state

| # | Step | State |
|---|---|---|
| 1 | System fully patched, rebooted onto new kernel | ✓ |
| 2 | Non-root sudo user `uri` | ✓ |
| 3 | SSH key access for `uri` | ✓ |
| 4 | SSH: root login off, password auth off (key-only) | ✓ |
| 5 | `ufw`: default-deny inbound, SSH allowed | ✓ |
| 6 | `unattended-upgrades`: auto security patches | ✓ |
| 7 | 2 GB swap + `vm.swappiness=10` | ✓ |
| 8 | Hostname `vpa-1` | ✓ |

## Still TODO (tracked in `../CLAUDE.md`)

- Docker + Compose (next — the reason the box exists)
- Hetzner Cloud Firewall (network-level, after ports are known)
- `fail2ban`
- reverse proxy (nginx), `deploy.sh`
