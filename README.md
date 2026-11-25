# Ceph Cluster Automation

Deploy a 3-node **Ceph** cluster (cephadm, containerized) on AWS EC2 with **Ansible**.

| | |
|---|---|
| Nodes | 3 x `t3.medium` (2 vCPU, 4 GiB RAM, 30 GiB root disk) |
| OS | Ubuntu 24.04 (22.04 also works) |
| Ceph | Squid (19.x), deployed with `cephadm` |
| Layout | MON on every node, MGR on two nodes, one OSD per node |
| Storage | A 15 GiB loopback file on the OS disk (lab), or a real extra EBS disk |

> The loopback mode is for learning and testing only. It shares the root disk with the OS and is slower than a real disk. Do not store important data on it.

---

## 1. Requirements

### AWS
- 3 Ubuntu EC2 instances in the same VPC/subnet, reachable over SSH with your key pair.
- A security group that allows **all traffic between the 3 nodes** (self-referencing), plus:

| Port | Source | Use |
|---|---|---|
| 22 | your IP | SSH |
| 8443 | your IP | Ceph dashboard |
| 3300, 6789, 6800-7300 | the group itself | MON / OSD / MGR / MDS |

- Root volume of **at least 30 GiB** (see "Storage backend" for the free-space rule).

### Control machine (where you run `make`)
Ansible must be recent. The Ubuntu `ansible` apt package is often too old for Ubuntu 24.04 targets (Python 3.12) and fails with `No module named 'ansible.module_utils.six.moves'`. Use a virtualenv:

```bash
sudo apt remove -y ansible ansible-core 2>/dev/null
sudo apt install -y python3-venv
python3 -m venv ~/ansible-venv
~/ansible-venv/bin/pip install --upgrade pip ansible-core
echo 'export PATH=$HOME/ansible-venv/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

ansible --version                      # 2.16 or newer
ansible-galaxy collection install ansible.posix
```

`ansible.posix` is needed for the `authorized_key` module (`ansible-core` does not include it).

### SSH key
SSH ignores private keys that other users can read:

```bash
chmod 600 ~/.ssh/id_rsa        # or your .pem file
```

---

## 2. Project layout

```
Ceph-Cluster-Automation/
├── ansible.cfg
├── Makefile
├── inventory/
│   ├── hosts.ini               # your 3 nodes
│   └── group_vars/
│       └── all.yml             # all settings (must live next to hosts.ini)
└── playbooks/
    ├── 01-prepare.yml          # hostname, /etc/hosts, Docker, chrony, cephadm
    ├── 02-bootstrap.yml        # cephadm bootstrap + ceph CLI wrapper
    ├── 03-add-hosts.yml        # SSH key, add hosts, place MON/MGR
    ├── 03a-loop-osd.yml        # loopback file -> loop device -> LVM (loop mode)
    ├── 04-osds.yml             # create the OSDs
    ├── 05-verify.yml           # status, health, dashboard URL
    ├── 06-pools.yml            # optional: RBD pool + CephFS
    ├── 99-destroy.yml          # wipe everything
    └── site.yml                # runs 01 to 05
```

---

## 3. Configure

### `inventory/hosts.ini`

```ini
[ceph]
ceph1 ansible_host=<public-ip-1> private_ip=<private-ip-1>
ceph2 ansible_host=<public-ip-2> private_ip=<private-ip-2>
ceph3 ansible_host=<public-ip-3> private_ip=<private-ip-3>

[bootstrap]
ceph1

[ceph:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/id_rsa
ansible_python_interpreter=/usr/bin/python3
```

- `ansible_host`: the IP you SSH to (public, or private if you run Ansible inside the VPC).
- `private_ip`: the VPC private IP. Ceph uses it for cluster traffic.

### `inventory/group_vars/all.yml`

```yaml
ceph_dashboard_user: admin
ceph_dashboard_password: "ChangeMe-Ceph123!"     # change this

ceph_mon_count: 3
ceph_mgr_count: 2
ceph_pool_size: 3
ceph_pool_min_size: 2
osd_memory_target: 1073741824                    # 1 GiB per OSD (4 GiB nodes)
skip_monitoring_stack: true                      # saves RAM

# Storage backend: loop (file on OS disk) or disk (real extra disk)
osd_backend: loop
osd_loop_file: /var/lib/ceph-osd.img
osd_loop_size_gb: 15
osd_vg: ceph-vg
osd_lv: osd0
osd_device: /dev/nvme1n1                         # only used when osd_backend: disk
```

Keep each variable **once** in the file. Duplicate keys produce "duplicate dict key" warnings and only the last value is used.

Check that the variables load:

```bash
ansible-inventory --host ceph1 | grep osd_backend
```

---

## 4. Storage backend

### `loop` (default, lab only)
No extra disk needed. A file (`osd_loop_size_gb`, default 15 GiB) is created on each node's root disk, attached as a loop device through a systemd service (`ceph-loop.service`, so it survives reboots), wrapped in LVM (`ceph-vg/osd0`) and used as the OSD.

- Before the file exists, the playbook requires **free space greater than `osd_loop_size_gb` + 4 GiB** on `/`. With a 30 GiB root disk and about 8 GiB used by the OS, Docker and the Ceph image, 15 GiB fits. If you have less free space, lower `osd_loop_size_gb` or grow the volume.
- Once the file exists, the space check is skipped, so re-running is safe.
- Usable space: 3 nodes x 15 GiB with 3 replicas = about **15 GiB** in total.

### `disk` (real disk)
1. Attach one empty EBS volume (e.g. 20 GiB) to each node. On t3 instances it appears as `/dev/nvme1n1` (check with `lsblk`).
2. Set `osd_backend: disk` and `osd_device` in `group_vars/all.yml`.

Moving from loop to disk later: attach the disks, set `osd_backend: disk`, run `make osds`, then remove the loop OSDs one by one with `ceph orch osd rm <id>` and delete `/var/lib/ceph-osd.img`.

---

## 5. Install

```bash
make ping       # all three nodes must answer SUCCESS
make all        # prepare -> bootstrap -> add hosts -> loop volumes -> OSDs -> verify
```

`make all` takes roughly 10 to 20 minutes. The `cephadm bootstrap` task is the slowest because it pulls the Ceph image. Re-running is safe: finished steps are skipped.

Run steps individually if you prefer:

```bash
make prepare      # 01
make bootstrap    # 02
make hosts        # 03
make loop         # 03a  (loop backend)
make osds         # 04
make verify       # 05
make pools        # 06  (optional)
```

### Check the result
On `ceph1`:

```bash
sudo ceph -s
```

Expected:

```
health: HEALTH_OK
mon: 3 daemons
mgr: ceph1.xxxx(active), standbys: ...
osd: 3 osds: 3 up, 3 in
```

`HEALTH_WARN` for the first minute or two is normal while the cluster settles.

Dashboard: `https://<ceph1-public-ip>:8443` (user and password from `group_vars/all.yml`; the certificate is self-signed).

---

## 6. How the `ceph` command works on `ceph1`

Ubuntu's `ceph-common` package is older than the Ceph container image that cephadm pulls (for example 19.2.3 on the host and 19.2.7 in the cluster). The older client cannot read the newer keyring format and fails with `Malformed input` and `RADOS I/O error`.

To avoid this, `02-bootstrap.yml` installs small wrappers at `/usr/local/bin/ceph` and `/usr/local/bin/rbd`:

```sh
#!/bin/sh
exec cephadm shell -- ceph "$@"
```

They run the CLI inside the cluster's own container, so the version always matches. The "Inferring fsid..." lines go to stderr and can be ignored.

---

## 7. Optional: pools and CephFS

```bash
make pools
```

Creates an `rbd` pool (initialised for RBD) and a CephFS volume named `cephfs` (this also deploys an MDS, which uses extra RAM on 4 GiB nodes).

---

## 8. Destroy

Removes the cluster and wipes the OSD disks. You must type `destroy` to confirm:

```bash
make destroy
```

In loop mode, also remove the loopback files and LVM if you want the space back:

```bash
ansible ceph -b -a "systemctl disable --now ceph-loop"
ansible ceph -b -a "vgremove -f ceph-vg"
ansible ceph -b -a "rm -f /var/lib/ceph-osd.img"
```

---

## 9. Troubleshooting

| Error | Cause and fix |
|---|---|
| `UNPROTECTED PRIVATE KEY FILE` / `Permission denied (publickey)` | Key permissions too open. Run `chmod 600 ~/.ssh/id_rsa`. If it persists, the key is not the one the instances were launched with. |
| `No module named 'ansible.module_utils.six.moves'` | Ansible on the control machine is too old for Python 3.12 targets. Install `ansible-core` 2.16+ in a virtualenv (section 1). |
| `couldn't resolve module/action 'ansible.builtin.authorized_key'` | The module is in `ansible.posix`. Run `ansible-galaxy collection install ansible.posix` and use `ansible.posix.authorized_key` in `03-add-hosts.yml`. |
| `Invalid callback for stdout specified: yaml` | Removed in newer ansible-core. In `ansible.cfg` use `stdout_callback = default` and `result_format = yaml`. |
| `'osd_backend' is undefined` | `group_vars` is not being loaded. It must be at `inventory/group_vars/all.yml`, next to `hosts.ini`. |
| `duplicate dict key (osd_backend)` | Variables are in `all.yml` twice. Remove one copy. |
| `Malformed input` / `RADOS I/O error` for `ceph -s` | Old host CLI against a newer cluster. The wrapper in section 6 fixes it. |
| `Not enough free space on / for a 15 GiB file` | Less than 19 GiB free and the file does not exist yet. Free space, lower `osd_loop_size_gb`, or grow the EBS volume (`growpart /dev/nvme0n1 1`, then `resize2fs /dev/root`). If the file already exists (`ls -lh /var/lib/ceph-osd.img`), the check must be skipped via the `stat` task in `03a-loop-osd.yml`. |
| `mon: 2 daemons`, `osd: 0 osds` in the middle of a run | Normal. The third MON is still starting and OSDs are created in step 04. |
| OSD stays `down` after a reboot | Check `systemctl status ceph-loop` and `losetup -a`. The loop device must exist before Docker starts. |

---

## 10. Notes

- 4 GiB of RAM per node is tight: each node runs a MON, a MGR (on two nodes), an OSD and Docker. OSD memory is capped at 1 GiB. Do not add RGW or large CephFS workloads.
- With 3 replicas and 3 OSDs, losing one node leaves the cluster working but degraded. Losing two stops writes.
- Change `ceph_dashboard_password` before exposing port 8443, and encrypt it with `ansible-vault encrypt_string 'password' --name ceph_dashboard_password`.
- To enable Prometheus and Grafana, set `skip_monitoring_stack: false` (needs more RAM).
