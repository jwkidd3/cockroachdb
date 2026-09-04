# Instructor Setup Guide — Provisioning Student VMs

Everything needed to stand up one VM per student for the 4-day CockroachDB course, verify it,
and tear it down. Budget **half a day** the first time you build the image, and **~20 minutes**
per delivery after that.

---

## 1. What the Labs Actually Require

Read this before sizing. The demanding labs are 7, 10, 13, and 16.

> **Everything runs in containers.** Students install nothing but Docker; the labs drive a
> 3-node cluster through `scripts/crdb`. That removes the single biggest source of
> "works on my machine" problems, and makes Windows laptops first-class.

| Lab | Needs | Peak RAM | Peak disk | Notes |
| --- | --- | --- | --- | --- |
| 1–6 | Docker | ~4 GB | 5 GB | the shared 3-node compose cluster |
| 7 Multi-region | 9-node demo, in a container | ~8 GB | 10 GB | `docker run ... demo --global --nodes 9` |
| 8 Throughput | 3-node + `workload` + CSV | ~6 GB | 15 GB | 100k-row CSV, IMPORT |
| 9 Observability | 3-node + Prometheus + Grafana | ~6 GB | 10 GB | Docker |
| 10 TPC-C | 3-node + TPC-C at 40 warehouses | ~10 GB | 30 GB | Heaviest disk user |
| 11 Backup/DR | **two** compose clusters | ~8 GB | 20 GB | `docker/labs-b.yml`, shared backup volume |
| 12 Security | 1 secure node | ~2 GB | 5 GB | `docker/labs-secure.yml`, auto-generated certs |
| 13 CDC | 3-node + Kafka container | ~7 GB | 10 GB | Docker |
| 14 Outbox | 3-node + Python | ~5 GB | 5 GB | psycopg2 |
| 15 MOLT | 3-node + PostgreSQL container | ~7 GB | 15 GB | Docker |
| 16 Kubernetes | kind (4 nodes) + 5 CRDB pods | ~10 GB | 25 GB | Docker-in-Docker; heaviest RAM user |

### Recommended student VM

| | Minimum (Days 1–2 only) | **Recommended (all 4 days)** | Comfortable |
| --- | --- | --- | --- |
| vCPU | 4 | **8** | 8–16 |
| RAM | 16 GB | **32 GB** | 32 GB |
| Disk | 60 GB SSD | **150 GB SSD (gp3/pd-ssd)** | 200 GB |
| OS | Ubuntu 22.04/24.04 LTS | **Ubuntu 24.04 LTS** | same |

> **Do not undersize RAM.** A student whose Lab 16 kind cluster OOMs loses 40 minutes and the
> lesson. 32 GB is the difference between "it works" and a room full of raised hands.

### Instance types by cloud

| Cloud | Recommended | Minimum | Approx. on-demand $/hr |
| --- | --- | --- | --- |
| AWS | `m6i.2xlarge` (8 vCPU / 32 GB) | `m6i.xlarge` | ~$0.38 |
| GCP | `n2-standard-8` | `n2-standard-4` | ~$0.39 |
| Azure | `Standard_D8s_v5` | `Standard_D4s_v5` | ~$0.38 |

**Cost for a 12-student class, 4 days × 8 hours:** `12 × 32 h × $0.38 ≈ $146` compute, plus
~$25 storage. Stop instances overnight and it drops by roughly a third.

---

## 2. Build the Golden Image Once

Provision **one** VM, run the provisioning script, verify it, then snapshot it. Every student
VM is a clone of that snapshot — identical, pre-warmed, and fast to launch.

### 2.1 Launch the builder VM

```bash
# AWS example
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --instance-type m6i.2xlarge \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":150,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=crdb-course-builder}]'
```

### 2.2 Run the provisioning script

```bash
scp setup/provision_student_vm.sh ubuntu@<builder-ip>:/tmp/
ssh ubuntu@<builder-ip> 'sudo bash /tmp/provision_student_vm.sh'
```

The script is in this repo at [`setup/provision_student_vm.sh`](provision_student_vm.sh).
It installs and pre-warms:

- Docker CE + Compose plugin, with the `student` user in the `docker` group
  (**this is what runs CockroachDB** — no database binary is installed on the host)
- `kind` + `kubectl` (Lab 16)
- `psql` client, `python3`, `psycopg2`, `sqlalchemy-cockroachdb` (Labs 1, 14, 15)
- `molt` fetch/verify binaries (Lab 15)
- Go toolchain (optional — Lab 14 Go variants)
- `jq`, `nc`, `lsof`, `bc`, `openssl`, `unzip`, `git`, `tmux`, `htop`
- **Pre-pulled container images** — `prom/prometheus`, `grafana/grafana`, `apache/kafka`,
  `postgres:16`, `kindest/node`, `cockroachdb/cockroach` — so no lab waits on a download
- The course repo cloned to `/home/student/cockroachdb-course`
- Kernel/ulimit tuning (`nofile=65536`, `vm.max_map_count`) that CockroachDB and kind need

### 2.3 Verify before you snapshot

```bash
ssh ubuntu@<builder-ip> 'sudo -u student bash /home/student/cockroachdb-course/setup/verify_student_vm.sh'
```

Every check must pass. The script exits non-zero on the first failure and tells you what's
missing.

### 2.4 Snapshot

```bash
# AWS
aws ec2 create-image --instance-id <builder-id> \
  --name "crdb-course-$(date +%Y%m%d)" --description "CockroachDB 4-day course student image"

# GCP
gcloud compute images create crdb-course-$(date +%Y%m%d) \
  --source-disk=<builder-disk> --source-disk-zone=<zone> --family=crdb-course

# Azure
az image create --resource-group "$RG" --name crdb-course-$(date +%Y%m%d) --source <builder-vm>
```

---

## 3. Launch Student VMs

### AWS

```bash
STUDENTS=12
AMI=ami-xxxxxxxx          # from step 2.4

for i in $(seq -w 1 $STUDENTS); do
  aws ec2 run-instances \
    --image-id "$AMI" --instance-type m6i.2xlarge \
    --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=crdb-student-$i},{Key=Course,Value=crdb-4day}]" \
    --user-data "file://setup/cloud-init-student.yaml" \
    --query 'Instances[0].InstanceId' --output text
done
```

### GCP

```bash
for i in $(seq -w 1 12); do
  gcloud compute instances create crdb-student-$i \
    --image-family=crdb-course --machine-type=n2-standard-8 \
    --boot-disk-size=150GB --boot-disk-type=pd-ssd \
    --metadata-from-file=user-data=setup/cloud-init-student.yaml \
    --labels=course=crdb-4day &
done; wait
```

### Azure

```bash
for i in $(seq -w 1 12); do
  az vm create --resource-group "$RG" --name crdb-student-$i \
    --image crdb-course-latest --size Standard_D8s_v5 \
    --admin-username student --ssh-key-values ~/.ssh/course_key.pub \
    --custom-data setup/cloud-init-student.yaml --tags course=crdb-4day &
done; wait
```

### Collect the connection sheet

```bash
bash setup/make_student_sheet.sh > /tmp/student-sheet.md
```

Produces a table of student number → hostname/IP → SSH command → DB Console URL, ready to
paste into the class chat.

---

## 4. Networking and Access

### Security group / firewall rules

| Port | Purpose | Source |
| --- | --- | --- |
| 22 | SSH | **Instructor IP + student IPs only** |
| 8080–8090 | DB Console | Student IP, or tunnel over SSH (preferred) |
| 3000 | Grafana (Lab 9) | Student IP, or SSH tunnel |
| 9090 | Prometheus (Lab 9) | Student IP, or SSH tunnel |
| 26257–26260 | SQL | **Do not expose.** Loopback only |

> **Strongly prefer SSH tunnels over open ports.** These are insecure clusters running with
> `--insecure` for teaching purposes; an exposed 26257 on a public IP is found by scanners in
> minutes. Give students this one-liner instead:
>
> ```bash
> ssh -L 8080:localhost:8080 -L 3000:localhost:3000 -L 9090:localhost:9090 student@<their-ip>
> ```
>
> Then everything is at `localhost` in their own browser.

### Access options, ranked

1. **SSH + local browser tunnel** (recommended) — no extra infrastructure, works everywhere.
2. **`code-server`** (VS Code in the browser) — add `--install-code-server` to the provisioning
   script. Good for students on locked-down laptops with no SSH client.
3. **Apache Guacamole / DCV** — full desktop. Heaviest; only worth it if students need a GUI.

If corporate laptops block outbound 22, run `sshd` on 443 as well:
```bash
echo "Port 22" | sudo tee -a /etc/ssh/sshd_config
echo "Port 443" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh
```

---

## 5. Pre-Class Checklist

**One week out**
- [ ] Golden image built and verified with `verify_student_vm.sh`
- [ ] Quota confirmed: `12 × 8 vCPU = 96 vCPU` in the target region — request an increase early
- [ ] Course repo pushed and the image's clone points at the right branch
- [ ] Test one student VM end to end: run **Lab 7**, **Lab 10**, and **Lab 16** in full

**Day before**
- [ ] Student VMs launched from the image
- [ ] `verify_student_vm.sh` run against every VM (`setup/verify_all.sh` loops for you)
- [ ] Connection sheet generated and sent
- [ ] SSH key or credentials distributed
- [ ] Instructor VM launched (same image, plus the presentation files)
- [ ] Budget alert set on the cloud account

**Morning of Day 1**
- [ ] Every VM reachable
- [ ] `scripts/crdb.sh up` brings up 3 live nodes on a spot-checked VM
- [ ] Docker daemon running on a spot-checked VM
- [ ] A spare VM or two provisioned for late joiners and casualties

---

## 6. Per-Day Warm-Up

Some labs benefit from a head start. Run these on all VMs the evening before.

**Before Day 3** (Lab 10 TPC-C data load takes several minutes):
```bash
setup/run_on_all.sh 'cd /home/student && cockroach start-single-node --insecure --background --store=/tmp/warm && \
  cockroach workload fixtures import tpcc --warehouses=10 "postgresql://root@localhost:26257?sslmode=disable" && \
  cockroach quit --insecure'
```

**Before Day 4** (Lab 16 pulls several container images):
```bash
setup/run_on_all.sh 'docker pull kindest/node:v1.29.2; \
  docker pull cockroachdb/cockroach:v23.2.5; \
  docker pull apache/kafka:3.9.0; docker pull postgres:16'
```

---

## 7. Teardown

```bash
# AWS — terminate everything tagged for this course
aws ec2 describe-instances --filters "Name=tag:Course,Values=crdb-4day" \
  --query 'Reservations[].Instances[].InstanceId' --output text \
  | xargs -r aws ec2 terminate-instances --instance-ids

# GCP
gcloud compute instances list --filter="labels.course=crdb-4day" --format="value(name,zone)" \
  | while read n z; do gcloud compute instances delete "$n" --zone="$z" --quiet & done; wait

# Azure
az vm list --resource-group "$RG" --query "[?tags.course=='crdb-4day'].name" -o tsv \
  | xargs -r -I{} az vm delete --resource-group "$RG" --name {} --yes
```

- [ ] Instances terminated
- [ ] Orphaned disks/snapshots deleted (these are what shows up on next month's bill)
- [ ] Keep the golden image if you're teaching again within ~3 months; otherwise delete it
- [ ] Final cost pulled and recorded for the next delivery's estimate

---

## 8. Alternatives to Per-Student VMs

| Option | Works for | Trade-off |
| --- | --- | --- |
| **Student laptops** | Days 1–2 | Free; but Windows/corporate-IT variance eats teaching time. Requires 16 GB RAM and admin rights |
| **One shared big VM, one Linux user per student** | Days 1–2 | Cheap; but port collisions and one student's runaway workload affects everyone. Needs per-student port ranges |
| **GitHub Codespaces / Gitpod** | Days 1–2 | Zero setup; but Lab 16 (kind) and Lab 7 (9 nodes) usually exceed the container's resources |
| **Per-student VM** (this guide) | **All 4 days** | Costs money; everything works |

If you must run Days 1–2 on laptops, the README's install section is the student-facing
instructions. Days 3–4 need Docker, kind, and 32 GB — plan for VMs.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `cockroach demo --nodes 9` OOM-kills | Under 16 GB RAM free | Resize, or have them use `--nodes 3` and pair up for Lab 7 |
| `too many open files` | ulimit not applied | `ulimit -n 65536`; confirm `/etc/security/limits.d/99-cockroach.conf` exists and they logged out/in |
| kind cluster never becomes ready | Docker memory under 6 GB, or `vm.max_map_count` too low | `sysctl -w vm.max_map_count=262144`; check Docker resources |
| `IMPORT INTO` fails with a permission error | `userfile` not writable by the SQL user | Run as `root` SQL user, or `GRANT` on the userfile table |
| DB Console unreachable | Port not forwarded | Use the SSH tunnel one-liner in §4 |
| Docker image pulls time out mid-lab | Images not pre-warmed | Run the §6 warm-up; consider a local registry mirror |
| Cluster from a previous lab still running | Cleanup block skipped | `pkill -f 'cockroach start'; rm -rf /tmp/crdb-*` — or `setup/reset_labs.sh` |
| Ports already in use | Prior lab's cluster alive | `setup/reset_labs.sh` resets to a clean state |

Give students `setup/reset_labs.sh` on day one. "Have you run the reset script?" resolves a
surprising share of lab problems.
