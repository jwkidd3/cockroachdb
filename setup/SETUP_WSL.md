# Student Setup — Windows VM with WSL2

The class runs on 12 GB Windows VMs. Students work inside **WSL2**, which is Linux — so every
command in every lab works exactly as written, with no `.bat` translation and no cmd quoting
surprises.

Nothing installs CockroachDB. It runs in Docker, like everything else.

---

## 1. Windows side (once per VM)

### 1.1 Install WSL2 and Ubuntu

In an **administrator** PowerShell:

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot if prompted, then open the Ubuntu app and create the UNIX user when asked.

```powershell
wsl --status          # confirm "Default Version: 2"
```

### 1.2 Give WSL enough memory — do this before anything else

**This is the step that decides whether Lab 16 works.** WSL2 does not hand Linux the whole
machine: recent builds default to about **half** of host RAM, so a 12 GB VM gives WSL ~6 GB.
Lab 16's kind cluster needs ~8 GB and Lab 7's nine-node demo needs ~6 GB.

Create `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=9GB
processors=4
swap=2GB
```

9 GB leaves 3 GB for Windows itself, and is enough for every lab in the course — Lab 16 was
measured completing in 7.6 GB, including its scale-out to five pods.

Apply it:

```powershell
wsl --shutdown
```

Reopen Ubuntu, then confirm Linux actually got it:

```bash
free -g
```

### 1.3 Docker Desktop

Install Docker Desktop, then **Settings → Resources → WSL integration → enable Ubuntu-24.04**,
and Apply & Restart.

> Do **not** `apt install docker-ce` inside the distro. Docker Desktop provides the daemon;
> integration provides the client. Installing both fights over the socket.

Confirm from inside Ubuntu:

```bash
docker info --format '{{.MemTotal}}'
```

---

## 2. Linux side (inside WSL)

### 2.1 Clone the course into the Linux filesystem

Put it wherever you like — the scripts work out their own location, so nothing depends on the
directory being named a particular thing or matching another machine:

```bash
git clone <course-repo-url> ~/cockroachdb-course
cd ~/cockroachdb-course
```

> **One rule: not `/mnt/c/...`.** The Windows filesystem is reachable from WSL but painfully
> slow for bind mounts and git, and ownership of the directories the labs mount (`lab9/`,
> `lab12/`) behaves oddly there. Keep the repo somewhere under `~`.
> `provision_wsl.sh` warns if it finds itself under `/mnt`.

> **Nothing is path-dependent.** `scripts/crdb.sh` and the tests locate the repo from their own
> position; the compose files use relative bind mounts and pin their project names, so the
> cluster network is `crdb-labs_default` no matter what the folder is called; and
> `provision_wsl.sh` writes shell aliases pointing at wherever you actually put it.

### 2.2 Provision

```bash
sudo bash setup/provision_wsl.sh
```

It installs only what genuinely cannot be a container:

| Installed | Why |
| --- | --- |
| `kind`, `kubectl` | Lab 16. `kind` drives the Docker daemon to build Kubernetes nodes, so it cannot itself run in one. |
| `psql` | Labs 8 and 15 use client-side `\copy` against local files. |
| `python3` + `psycopg2` | Six labs run Python against the cluster. |

Everything else is an image, pre-pulled so the first lab is instant: `cockroach`,
`kindest/node`, `prometheus`, `grafana`, `kafka`, `postgres`, `molt`, `helm`.

The script also turns on systemd in `/etc/wsl.conf`. Without it WSL ignores
`/etc/sysctl.d`, `vm.max_map_count` stays at 65530, and **kind fails to start**. If it says so,
run `wsl --shutdown` in PowerShell and reopen the shell.

### 2.3 Verify

```bash
bash setup/verify_student_vm.sh
```

It detects WSL and reports the WSL VM's resources — the numbers that actually govern the labs.
Expect `Pass` with no `Fail`. It prints the `.wslconfig` fix if memory is short.

### 2.4 Smoke test

```bash
scripts/crdb up
scripts/crdb sql -e "SELECT 'ready' AS status;"
scripts/crdb down
```

The DB Console is at <http://localhost:8080> in the Windows browser — WSL2 forwards published
ports to the host automatically.

---

## 3. Things that bite on WSL specifically

| Symptom | Cause | Fix |
| --- | --- | --- |
| kind cluster never starts; pods `Pending` | `vm.max_map_count` = 65530 | systemd enabled by the provisioning script, then `wsl --shutdown` |
| Lab 16 OOM-kills mid-rollout | WSL got ~6 GB of the 12 | `.wslconfig` → `memory=9GB`, `wsl --shutdown` |
| Labs feel sluggish; git is slow | repo lives on `/mnt/c` | re-clone into `~` |
| `docker: command not found` | WSL integration off | Docker Desktop → Resources → WSL integration |
| `ulimit -n` is 1024 | systemd off, so `limits.d` ignored | same as row 1 |
| Cluster won't start after Windows sleep | Docker Desktop lost the socket | restart Docker Desktop, then `scripts/crdb up` |

## 4. Which wrapper to use

Inside WSL, always `scripts/crdb.sh` — WSL is Linux. `scripts\crdb.bat` exists only for a
native `cmd`/PowerShell shell, and is not the path this class takes.

## 5. Running the test suite on this machine

The suite is bash, so run it **inside WSL** — not in `cmd` or PowerShell. It drives the same
Docker stacks the labs do, so a green run here means the labs work on this machine.

```bash
cd ~/cockroachdb-course          # wherever you cloned it
git pull

bash setup/verify_student_vm.sh  # check the machine first — 30 seconds
```

Fix any `FAIL` before going further; a short WSL memory allocation will surface here.

```bash
./tests/lab_cluster_test.sh      # the student path: compose + scripts/crdb   (~3 min)
./tests/crdb_wrappers_test.sh    # crdb.sh / crdb.bat parity                  (~2 min)
./tests/run_all.sh               # all 16 labs                            (~60-90 min)
```

Useful knobs:

| Command | Effect |
| --- | --- |
| `DAY=3 ./tests/run_all.sh` | just that day's four labs |
| `LABS_OVERRIDE="lab08_test.sh lab10_test.sh" ./tests/run_all.sh` | an explicit subset |
| `KEEP_ON_FAIL=1 ./tests/lab11_test.sh` | leave the cluster up to inspect a failure |
| `FORCE_LAB16=1 ./tests/lab16_test.sh` | run Lab 16 even if the memory check objects |

Expect skips rather than failures where a dependency is genuinely absent — the summary names
each one. A run is healthy when the final line reads `Fail: 0`.

> **Run it once before the first class.** It is the difference between finding a
> machine-specific problem on a quiet afternoon and finding it in front of twelve people.

## 6. Freeing memory for the heavy labs

12 GB fits every lab, one heavy stack at a time. Before **Lab 7**, **Lab 10** and **Lab 16**:

```bash
scripts/crdb down
```

The 3-node cluster holds ~4 GB; those three labs each want 6–8 GB on their own.
