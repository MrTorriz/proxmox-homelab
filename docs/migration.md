# The migration: bare metal → hypervisor, same box, zero data loss

The [homelab](https://github.com/MrTorriz/homelab) ran on bare-metal Ubuntu 24.04. This
is how the same physical machine became a Proxmox host with that server living on as
VM 100 — same IP, same data, one afternoon of downtime.

## The shape of the problem

One machine, no second box to stage on. The plan:

1. Back up the SSD's "soul" (appdata, configs, secrets) offsite, encrypted.
2. Wipe the SSD, install Proxmox VE.
3. Recreate the server as a VM via cloud-init, restore the soul.
4. Hand the data drives (2 × 4 TB, untouched by the wipe) to the VM as raw passthrough.
5. Pass through the GPU.

The 6+ TB of media never moves. The drives are physically unplugged from a bare-metal OS
and logically re-plugged into a VM — that's the trick that keeps the migration small.

## Backing up: 56 000 small files vs one big pipe

First attempt streamed appdata file-by-file to cloud storage — and died against the
provider's per-file rate limit (~10 ops/s): 56k small files would take hours. Second
attempt packed everything into **three tar archives** and uploaded those instead: ~28 GB
in minutes on fiber.

- `appdata.tar` — all container appdata + fresh DB dumps (Postgres etc.)
- `home-config.tar.gz` — dotfiles, scripts, compose stack, SSH keys, `.env` files
- `system-config.tar.gz` — the `/etc` pieces no package owns (VPN device keys, etc.)

The archives go to an **rclone crypt** remote. The rclone config is the one secret that
can't live inside the backup it decrypts — it goes in a password manager. Everything
else (SSH keys, all `.env`, WireGuard keys) is *inside* the encrypted archives and needs
no separate handling.

Re-ran the full backup right before the wipe, then verified byte-for-byte against local
staging, test-decrypted, and gzip-CRC-checked the streams. Paranoia level: appropriate.

## The completeness audits

The most useful thing done in the whole migration: **three passes of "what does a
restore need that isn't in the backup or the repo?"** before wiping. Each pass found
real gaps:

**Pass 1 — `/etc` files no package owns:**

- `/etc/docker/daemon.json` (nvidia runtime + CDI) — without it, **no GPU containers**.
- A `systemd-resolved` drop-in (`DNSStubListener=no`) — without it, the DNS container
  can't bind :53 and **LAN DNS dies**.
- The VPN client's `/etc` state (device key + hardening settings) — without it, broken
  VPN after restore.

**Pass 2 — invisible glue:**

- The Docker network was `external: true` in compose — `docker compose up` on a fresh
  box fails with *network not found* until you create it (with the exact subnet UFW
  rules and `extra_hosts` hardcode).
- Three `sudoers.d` files enabling passwordless sudo for cron automation — in neither
  repo nor backup.
- PAM notify hooks (cosmetic, but documented).

**Pass 3 — exhaustive sweep** (named volumes, apt sources, `/opt`, `/usr/local/bin`,
crontabs):

- Custom apt sources **and their keyrings** — without them, `apt install` fails for
  every third-party package on the fresh VM.
- A manually-installed binary in `/usr/local/bin` that a health-check script depended on.

Every gap went into the config repo or the restore runbook *before* the wipe. If you take
one thing from this doc: **audit for what's missing, not what's present** — a backup of
everything you thought of is exactly as good as your memory.

## Rebuild highlights

- **Host relocated to a new IP first**, freeing the old one for the VM — every LAN device
  already pointed at that IP for DNS, and keeping it meant zero client reconfiguration.
- **VM built with cloud-init** (Ubuntu cloud image, no interactive install): right
  user with **UID/GID 1000 pinned** — container volume permissions depend on it — SSH key
  injected, static IP. Fully scripted, so a rebuild is a runbook, not an adventure.
- **Restore**: rclone config from the password manager → pull three archives → verify →
  unpack → `docker network create` → `docker compose up -d`. 41 of 45 containers up on
  the first evening; the GPU set followed after passthrough.
- **Passthrough**: disks by `/dev/disk/by-id`, GPU per the [vfio recipe](passthrough.md).
  Data drives mounted by UUID with their bare-metal fstab lines unchanged.

## Gotchas worth stealing

- **Ubuntu 24.04 socket-activates SSH.** `Port` in `sshd_config` doesn't take effect via
  `reload` — a generator bakes the port into `ssh.socket`, so a *socket* restart is
  required. A dead-man timer (scheduled rollback of the firewall/ssh change unless
  cancelled) is cheap insurance when changing SSH ports remotely.
- **DNS bootstrapping order.** The server is the LAN's DNS — but the VM itself must
  resolve *before* its DNS container is up, and the host needs working DNS before any of
  it. Point the host and the VM's own resolver at something that exists without the
  stack (router / upstream), never at the stack itself
  ([lesson #4](lessons.md#4-the-server-points-its-own-dns-away-from-itself)).
- **Non-root tar unpacking flattens ownership.** Restored appdata came back owned
  `1000:1000`; containers running as other UIDs (Grafana 472, Prometheus 65534) failed
  until re-`chown`ed. Restore as root or fix ownership per service.
- **Old host keys linger.** The workstation's `known_hosts` still had the bare-metal
  server's key on the same IP/port — `ssh-keygen -R` and move on.

## Aftermath

Databases were verified live rather than restored from dumps (row counts, user counts,
asset counts — all matched). The dumps stayed as fallback and were never needed. Power
metering was the one service that couldn't survive virtualization: RAPL doesn't exist in
a VM, so it moved to the hypervisor — the only workload the host gained.
