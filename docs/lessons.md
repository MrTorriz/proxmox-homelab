# Operational lessons

Fourteen things this setup taught the hard way. Numbered because the other docs
cross-reference them.

## 1. `onboot=1` on every production VM

A VM that isn't flagged `onboot` does not come back after a host reboot — the whole
stack sat dark after the first kernel-upgrade reboot until someone noticed and started
it by hand. Set it the moment a VM becomes load-bearing: `qm set <vmid> --onboot 1`.

## 2. Keep the host minimal

Only virtualization and hardware health belong on the hypervisor. Docker, apps, and DNS
run in guests. Then the host can be rebooted or upgraded without the services caring
(given #1). Every package on the host is one more reason a host upgrade can break a
workload.

## 3. Decide where truth lives — and mean it

This lab flipped from "repo is truth, deploy to live" to "live is truth, mirror to
repo". Either works; **half-and-half doesn't.** If the repo auto-deploys, never edit
live. If live is truth, a forgotten mirror only costs repo freshness — the running
system is unaffected. Pick the failure mode you can live with.

## 4. The server points its own DNS away from itself

The workload VM *serves* DNS for the LAN, but its own resolver points elsewhere. Pointing
a DNS server at itself is a circular dependency: DNS container down → no resolution → the
tooling that would fix it can't resolve either. Self-hosted DNS is for the clients, never
for the box that runs it.

## 5. VPN lives in the workload layer, not the hypervisor

The VPN client (with killswitch) runs where the traffic originates — inside the VM next
to the containers it protects. Putting it on the host would tunnel *everything*
(including hypervisor management) and turn one VM's requirement into everyone's problem.

## 6. Backups don't capture clone-on-demand frameworks

Anything installed by `git clone` into the home directory (shell frameworks and the
like) is not config — dotfile backups pick up the *rc* files but not the framework, and
first login after restore breaks. Keep a list of "reinstall these by hand" in the
restore runbook.

## 7. If it must survive a wipe, the restore flow must own it

A custom MOTD lived in the repo but the deploy script never handled it — gone after the
rebuild. Files that exist only on the machine and only in memory of "yeah that's
handled" are the ones you lose. The [completeness audits](migration.md#the-completeness-audits)
exist because of this class of loss.

## 8. Proxmox's subscription nag resurrects

The `proxmoxlib.js` patch that removes the no-subscription dialog is reverted on every
`proxmox-widget-toolkit` upgrade. Keep the re-patch as a one-liner alias; expect to run
it after host updates.

## 9. A self-updating deploy script lags by one run

If the deploy script deploys *itself*, a change to it takes two runs: the first installs
the new version, the second executes its logic. Budget for it or special-case it.

## 10. Serial console needs a getty in the guest

Pointing the VM's display at `serial0` gives you a console in the web UI *only if* the
guest runs `serial-getty@ttyS0`. Blank console ≠ broken VM — press Enter, then check the
getty.

## 11. Thin-disk `discard` must be enabled on both ends

Guest-side TRIM is silently discarded unless the QEMU disk has `discard=on`. ~51 GB of
deleted-but-not-freed blocks had accumulated in the thin pool before this clicked.
And never shrink a thin disk — the size is a cap, not usage; shrinking risks data for
zero gain.

## 12. Single host means no Ceph/ZFS pool

Distributed storage wants 3+ nodes and wants to initialize (wipe) its disks. On one
16 GB box with irreplaceable data on passthrough drives, "let the platform manage
storage" is an active hazard. Passthrough + protect beats pooled + hopeful.

## 13. Passthrough disks must be `backup=0`

Otherwise `vzdump` dutifully tries to image the entire raw disk — here, 8 TB into what
should be a 40 GB backup.

## 14. Ballooning does not return host RAM on a running VM

`memory=13G, balloon=8G` still ended at 13 GB host-RSS: Linux fills its cap with page
cache, and without free-page reporting the host never gets it back. The web UI then
shows the VM eating the host. The real lever is the **`memory=` cap itself** — lower it
(takes effect at VM restart, not live) to what the workload actually uses. Cap 13→8 GB
freed 5 GB for other guests; actual workload was ~5 GB all along. Same mental model as
thin disks (#11): the number is a ceiling the guest *will* grow into, not a measurement.
