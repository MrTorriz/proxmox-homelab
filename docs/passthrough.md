# Passthrough: GPU and raw disks

VM 100 gets real hardware: an RTX 2060 for transcoding/ML and two 4 TB drives with data
that predates the hypervisor. Both passthroughs, both sets of gotchas.

## GPU — RTX 2060 → VM 100 (vfio)

### Host side

1. **IOMMU on** — GRUB cmdline: `intel_iommu=on iommu=pt`, then `update-grub` + reboot.
2. **Bind all four functions to vfio-pci.** A modern GPU is not one PCI device — this one
   exposes VGA, audio, USB-C and UCSI functions. Bind them all or the group won't detach
   cleanly:

   ```text
   # /etc/modprobe.d/vfio.conf
   options vfio-pci ids=10de:1f08,10de:10f9,10de:1ada,10de:1adb
   softdep nvidia pre: vfio-pci
   softdep snd_hda_intel pre: vfio-pci
   softdep xhci_hcd pre: vfio-pci
   ```

   Use `softdep`, **not** a global blacklist of `xhci_hcd`/`snd_hda_intel` — a blacklist
   would kill the host's own USB and audio drivers, not just the GPU's.
3. **Check the IOMMU group is clean** — the GPU's four functions should be alone in their
   group. If other devices share it, passthrough drags them along.
4. Attach: `qm set 100 -hostpci0 01:00,pcie=1` (whole device, all functions; VM must be
   q35 + OVMF).

Heads-up: this CPU has no iGPU, so binding the only GPU to vfio makes the host
**permanently headless**. SSH and the web UI are the only doors after this point — make
sure both work before rebooting.

### Guest side

- NVIDIA driver via DKMS + `nvidia-container-toolkit`, CDI spec generated
  (`nvidia.com/gpu=all`), modules autoloaded via `/etc/modules-load.d/`.
- `/etc/docker/daemon.json` declares the nvidia runtime + CDI. Without this file, no
  container sees the GPU — it's one of those host files that's easy to lose in a rebuild
  ([migration](migration.md#the-completeness-audits)).
- Verify end-to-end: `nvidia-smi` in the VM, then in a container (Jellyfin NVENC,
  Immich ML).

### GPU gotchas that cost real time

- **Repo keyring permissions.** The apt keyring for the NVIDIA repo landed as
  `0640 root:root`; the `_apt` user couldn't read it → `NO_PUBKEY` errors that look like
  a broken repo. `chmod 644` on the keyring. (The same permission trap hit the VPN
  vendor's keyring and a `systemd-resolved` drop-in — apparently a habit.)
- **Kernel upgrades rebuild DKMS, but containers can still break.** After a guest kernel
  bump, three GPU containers failed with a cgroup BPF error
  (`last insn is not an exit or jmp`) while others kept working. The failing ones used
  Docker's `device_requests` API; switching them to `runtime: nvidia` +
  `NVIDIA_VISIBLE_DEVICES` (the pattern the working containers already used) fixed it.

## Disks — two 4 TB drives → VM 100 (whole-disk)

The drives hold media and backup data from the bare-metal era. They were never migrated —
the same physical disks with the same filesystems were handed to the VM:

```bash
qm set 100 -scsi1 /dev/disk/by-id/ata-WDC_WD40EFPX-...   # → /mnt/storage in the guest
qm set 100 -scsi2 /dev/disk/by-id/ata-WDC_WD40EFPX-...   # → /mnt/plex in the guest
```

- **Always `/dev/disk/by-id/`**, never `/dev/sdX` — enumeration order is not stable.
- **In the guest, mount by UUID** in fstab. The filesystems are unchanged, so the
  bare-metal fstab entries kept working as-is.
- **Set `backup=0` on both.** Otherwise `vzdump` tries to image 8 TB of raw disk into
  every backup ([lesson #13](lessons.md#13-passthrough-disks-must-be-backup0)).

### Disk gotchas

- **Device names shuffle inside the VM.** On bare metal the HDDs were `sda`/`sdb` and the
  SSD was `nvme0n1`; in the VM the virtual OS disk claimed `sda` and pushed the HDDs to
  `sdb`/`sdc`. Anything that referenced `/dev/sdX` directly (here: a SMART-monitoring
  container) needed re-pointing. UUID/by-id references survived untouched.
- **SMART data passes through fine** — the guest sees the real drives, so in-guest SMART
  monitoring keeps working. The host *also* watches the same drives with smartmontools;
  they don't conflict.
- **Hypervisor discipline:** the host never mounts, formats, fscks, or "manages" these
  drives. They belong to the guest. The only host-side interaction is the initial
  `qm set` and SMART reads.

## Thin-disk TRIM: `discard` must be on at both ends

The guest can mount with `discard` all it wants — if the QEMU disk lacks `discard=on`,
TRIM commands are silently dropped and deleted blocks pile up in the thin pool (~51 GB of
ghost usage here before the fix):

```bash
qm set 100 --scsi0 local-lvm:vm-100-disk-1,discard=on,ssd=1
```

Space is reclaimed at the next VM restart. And never *shrink* a thin disk to "save
space" — the size is a cap, the pool only stores written blocks, shrinking risks the
filesystem for zero gain.
