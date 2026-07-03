# Metrics — the numbers, with receipts

Every figure the README claims traces back to a command on the live system. Values
below were measured 2026-07-03; the commands are the source of truth, the table is
just a snapshot.

| Figure | Measured | Command / source |
|---|---|---|
| VMs on the host | 6 | `qm list` on the host ([screenshot](img/qm-list.png)) |
| Running containers in VM 100 | 42 | `docker ps -q \| wc -l` inside the guest |
| Raw disk passed through | 8 TB (2 × 4 TB) | `qm config 100` → `scsi1`/`scsi2`, ~3.64 TiB each, `backup=0` |
| Open inbound ports | 0 | the router's port-forward table is empty — external access is an outbound Cloudflare Tunnel from VM 100 ([architecture](architecture.md#network-two-bridges-two-trust-zones)) |
| CPU package power | ~17 W | `scaph_host_power_microwatts` from scaphandre's Prometheus exporter on the host (RAPL) — 16.5 W at measurement |
| GPU power (idle) | ~15–18 W | `nvidia-smi --query-gpu=power.draw --format=csv` inside the guest — 15.1 W at measurement |
| Total draw | ~35 W | CPU package + GPU ≈ 32 W; RAPL doesn't see drives, RAM, or the board, so ~35 W is the working figure for the wall |
| VM boot-disk pool | 349 GB, 27% used | `pvesm status` → `local-lvm` ([screenshot](img/pvesm-status.png)) |
| vzdump target | ~1 TB, 14% used | `pvesm status` → the dedicated `dir` storage |
| VM 100 RAM cap | 8 GB | `qm config 100` → `memory: 8192` |

Two honesty notes:

- **Container count drifts.** Services get added and pruned; the docs round to ~40.
  Re-run the command, don't trust a README.
- **Power is idle-workload.** Transcodes and ML jobs spike the GPU well past its
  idle draw; ~35 W is the steady state the box actually spends its day at.
