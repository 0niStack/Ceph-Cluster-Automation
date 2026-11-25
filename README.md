# ceph-ansible-lab

Ceph (cephadm, containerized) on **3 x AWS t3.medium** (2 vCPU / 4 GiB) with Ansible.
Every node runs a MON and one OSD; two nodes run a MGR. Ubuntu 22.04/24.04.

## Storage backend (set `osd_backend` in `group_vars/all.yml`)

**`loop` (default, lab only):** no extra disk needed. A 15 GiB file on the OS disk is
exposed as a loop device, wrapped in LVM, and used as the OSD. Slower than a real disk, and
it shares space with the OS, so never make the file larger than about half the root disk.
Usable space: 3 x 15 GiB with 3 replicas = about **15 GiB**.

**`disk`:** attach one extra empty EBS volume per VM (e.g. 20 GiB gp3). On t3 (Nitro) it appears as
`/dev/nvme1n1` (check `lsblk`, set `osd_device`). Usable space about 20 GiB.

Switching later: set `osd_backend: disk`, run `make osds`, then remove the loop OSDs one by one with
`ceph orch osd rm <id>` and delete `/var/lib/ceph-osd.img`.

### Security group (self-referencing, between the 3 nodes)
| Port | Use |
|---|---|
| 22 | SSH / cephadm |
| 3300, 6789 | MON |
| 6800-7300 | OSD / MGR / MDS |
| 8443 | Dashboard (open to your IP only) |

## Run

```bash
# 1. edit inventory/hosts.ini (IPs) and group_vars/all.yml (password, disk)
sudo apt install -y ansible    # on your control machine
make ping
make all          # prepare -> bootstrap -> add hosts -> OSDs -> verify
make pools        # optional: RBD pool + CephFS
```

Or step by step: `make prepare`, `make bootstrap`, `make hosts`, `make osds`, `make verify`.

Healthy result on `ceph1`:
```bash
sudo ceph -s     # HEALTH_OK, 3 mons, 2 mgrs, 3 osds up/in
```
Dashboard: `https://<ceph1-ip>:8443` (user/password from `group_vars/all.yml`).

## Notes
- Monitoring stack (Prometheus/Grafana) is skipped to save RAM; set `skip_monitoring_stack: false` to enable it.
- OSD memory is capped at 1 GiB (`osd_memory_target`). Avoid heavy RGW/MDS workloads on 4 GiB nodes.
- `HEALTH_WARN` right after boot is normal for a minute or two; run `make verify` again.
- Wipe everything (including OSD disks): `make destroy`.
- Encrypt the dashboard password: `ansible-vault encrypt_string 'pw' --name ceph_dashboard_password`.
