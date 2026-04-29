# Operating the Rubin Solar System Ephemerides Service

## What this service does and why it exists

Every night, the Rubin Observatory takes hundreds of images of the sky.
Each image is processed within about 60 seconds by the **prompt processing
(PP) pipeline**, which detects sources that have changed or moved since the
last observation — these are called *difference-image sources*
(**diasources**). Some of those diasources are genuinely new or interesting
(supernovae, near-Earth asteroids on their first pass, etc.), and some are
just known asteroids going about their predictable orbits.

To tell the two apart, PP needs to answer a question for every diasource:
**"Is there a known solar system object at this position in the sky, at
this time?"** That's what this service provides. Given a sky coordinate
(RA, Dec), a search radius, and a time, it returns the list of known solar
system objects predicted to be there.

An **ephemeris** (plural: *ephemerides*) is the predicted position of a
celestial object at a given time, computed from its orbital elements. The
Minor Planet Center (MPC) maintains a database of ~1.3 million known
asteroid and comet orbits. This service propagates all of those orbits
forward to the current observing night, pre-indexes the results for fast
spatial lookup, and serves them over HTTP.

### How it works: two halves

The system is split into a heavy **batch backend** that runs once per day
and a lightweight **query service** that runs continuously:

1. **Backend (cache builder)** — this repository,
   [`mjuric/lsst-gen-ephemcache`](https://github.com/mjuric/lsst-gen-ephemcache)
   (branch `unpacked-desig`). Once a day, before the observing night
   begins, a cron job on USDF:
   - Pulls the latest orbital elements from the MPC database replica.
   - Splits the ~1.3 million orbits into 100 chunks and fans them out as a
     SLURM array job. Each task runs
     [Sorcha](https://github.com/dirac-institute/sorcha), which propagates
     the orbits forward and computes predicted positions.
   - Collects the results and builds a single binary **cache file** — a
     compact blob containing Chebyshev polynomial fits and a HEALPix
     spatial index, optimised for fast cone-search queries.
   - Places the cache on an HTTP-accessible filesystem so the service can
     download it.

   A full build takes roughly 30–60 minutes of wall-clock time.

2. **Service (`mpsky`)** —
   [`mjuric/mpsky`](https://github.com/mjuric/mpsky) (branch `auto-load`),
   deployed as a Phalanx Kubernetes app
   ([`lsst-sqre/phalanx`](https://github.com/lsst-sqre/phalanx),
   application `mpsky`). The service:
   - Polls the backend's HTTP directory every 60 seconds; when a new
     night's cache appears, it downloads and loads it into memory.
   - Answers queries in milliseconds — it's a read-only server whose only
     job is to look things up in the pre-built cache.
   - Is consumed by the PP pipeline (via the `mpsky-wrapper` library) and
     can also be queried directly with `curl` or the `mpsky query` CLI.

In short: all the expensive computation happens in the backend; the service
is just a fast lookup layer.

### Audience

This runbook is for USDF / SQuaRE SREs. It assumes familiarity with SLURM,
Kubernetes, Argo CD, and Phalanx; minimal astronomy background is required
(the paragraphs above should suffice).

---

## Table of contents

1. [Architecture and data flow](#1-architecture-and-data-flow)
2. [Backend: nightly cache builder at USDF](#2-backend-nightly-cache-builder-at-usdf)
3. [Service: `mpsky` pod (Phalanx)](#3-service-mpsky-pod-phalanx)
4. [Routine tasks](#4-routine-tasks)
5. [Reference](#5-reference)

---

## 1. Architecture and data flow

```
   MPC USDF replica            sdfcron001 (cron)            SLURM (S3DF)
   172.24.5.71/mpc_sbn   ─►   lsst-gen-ephemcache    ─►   partition: torino
   user: rubin                bin/cron-compute-...        account: rubin:developers
                                     │                    array: 0..99 (Sorcha)
                                     ▼
                    /sdf/group/rubin/web_data/mpsky-data/
                    (HTTP-served by S3DF as
                     https://s3df.slac.stanford.edu/data/rubin/mpsky-data/)
                                     │
                                     ▼
                    mpsky pod (Phalanx app `mpsky`)
                    image: ghcr.io/mjuric/mpsky-daily:auto-load
                    `mpsky serve --datastore <URL>`
                                     │
                                     ▼
                    prompt processing pipelines (PP)
                    GET /ephemerides/?t=&ra=&dec=&radius=
```

There are **two independent backend installs** producing caches:

- **USDF backend** (the one ops will own). Runs on USDF SLURM. The cache is
  written **directly into the HTTP-served directory**
  (`/sdf/group/rubin/web_data/mpsky-data`), reachable at
  `https://s3df.slac.stanford.edu/data/rubin/mpsky-data/`. There is **no
  rsync step** at USDF; `EPHEM_RSYNC_TO` is unused here.
- **epyc backend** (legacy / parallel; for context only). A separate install
  of the same repo on `epyc.astro.washington.edu` running locally with GNU
  parallel (`KIND=parallel`), publishing to
  `https://epyc.astro.washington.edu/~mjuric/mpsky-data`.

**Datastore in transition.** The Phalanx-deployed `mpsky` pod currently
points its `--datastore` at the **epyc** URL. Once ops takes over, this
should be flipped to the USDF s3df URL. See
[§4.2 Cut over the datastore URL](#42-cut-over-the-datastore-url-epyc--s3df).

Glossary
- **Night MJD**. The MJD that labels an observing night. The cron uses
  17:00 America/Santiago as the night-flip moment (so a "night" starts at
  Chilean dusk). The service uses UTC midnight via `ac.utc_to_night`. These
  agree most of the time and can differ by ±1 day right around UTC midnight.
- **Datastore**. The HTTP root from which `mpsky serve` discovers and
  downloads cache files (`<datastore>/caches/*.bin` and
  `<datastore>/catalogs/*`).
- **Cache** (`eph.<MJD>.<date>.bin`). The binary blob built by `mpsky build`
  containing Tchebyshev polynomials and healpix indices for fast lookup.
- **Catalog**. Zstd-compressed sqlite of the MPC `mpc_orbits` table,
  optionally consumed by the service when a client asks for orbital
  elements (`return_elements=basic|extended`).

---

## 2. Backend: nightly cache builder at USDF

### 2.1 Where it runs

| Item                      | Value (USDF, today)                                                              |
|---------------------------|----------------------------------------------------------------------------------|
| Cron host                 | `sdfcron001`                                                                     |
| Cron user                 | `mjuric` (will move to a service / shared account when ops takes over)           |
| Repo clone (active)       | `/sdf/home/m/mjuric/projects/github.com/mjuric/lsst-gen-ephemcache-dev`          |
| Repo clone (inactive)     | `/sdf/home/m/mjuric/projects/github.com/mjuric/lsst-gen-ephemcache` (cron line commented out) |
| Conda env (build)         | `lsst-gen-ephemcache` — managed via `micromamba`                                 |
| Conda env (cron filter)   | `mpsky` at `/sdf/data/rubin/user/mjuric/micromamba/envs/mpsky` (used to run `bin/clean-tqdm.py`; reused because it has the same packages) |
| MPC database              | `postgresql+psycopg2://rubin@172.24.5.71/mpc_sbn` (USDF-internal replica)        |
| SLURM partition           | `torino`                                                                         |
| SLURM account             | `rubin:developers`                                                               |
| Cache output (on disk)    | `outputs/caches/eph.<MJD>.<YYYY-MM-DD>.bin` under the active repo                |
| HTTP-served directory     | `/sdf/group/rubin/web_data/mpsky-data` (the active repo's `outputs/` is a symlink to this path) |
| Public URL                | `https://s3df.slac.stanford.edu/data/rubin/mpsky-data/`                          |

> **Note**: the repo's `install.sh` writes USDF-default-looking values into
> `ephemcache.config` (`MPCDB=...epyc.astro.washington.edu...`,
> `--account=rubin:default@roma`, partition `roma`) that are **wrong for
> the USDF cluster as it operates today**. After `install.sh` you must
> overwrite `ephemcache.config` with the values in [§2.2](#22-installing-or-reinstalling-the-backend).

### 2.2 Installing or reinstalling the backend

On `sdfcron001`, as the cron user:

```bash
# 1. Clone (and pick a path under your home dir).
cd ~/projects/github.com/mjuric
git clone https://github.com/mjuric/lsst-gen-ephemcache.git
cd lsst-gen-ephemcache
git checkout unpacked-desig

# 2. Create the conda env. install.sh names it from its argument; use
#    "lsst-gen-ephemcache" so it matches what the cron expects.
./install.sh lsst-gen-ephemcache

# 3. Overwrite the generated ephemcache.config with USDF settings:
cat > ephemcache.config <<'EOF'
ENV='lsst-gen-ephemcache'
MPCDB='postgresql+psycopg2://rubin@172.24.5.71/mpc_sbn'
SRUN='srun -p torino -A rubin:developers'
SBATCH='sbatch -p torino -A rubin:developers'
KIND='SLURM'
MAMBA=micromamba
EOF

# 4. Set up ~/.pgpass with credentials for the USDF replica.
#    Format: host:port:db:user:password
echo '172.24.5.71:5432:mpc_sbn:rubin:<PASSWORD>' >> ~/.pgpass
chmod 600 ~/.pgpass

# 5. Symlink outputs/ to the HTTP-served directory so caches land where
#    the public URL serves them. If outputs/ already exists (e.g. created
#    by install.sh or a prior run) move/empty it first.
rm -rf outputs
ln -s /sdf/group/rubin/web_data/mpsky-data outputs

# 6. Bootstrap Sorcha's auxiliary data (planetary ephemeris kernels, etc.).
#    install.sh runs this once; rerun after a sorcha update if needed.
micromamba activate lsst-gen-ephemcache
sorcha bootstrap --cache sorcha_cache
```

`~/.pgpass` is the only secret on this host. If the password rotates,
update this file; the build will fail with "no password supplied"
otherwise. There is no ssh key requirement at USDF (no rsync).

### 2.3 The cron job

On `sdfcron001`, as the cron user, `crontab -e`:

```cron
MAILTO=<your-ops-email>
BASH_ENV=/sdf/home/<u>/<user>/.bash_profile
TQDM_DISABLE=1

0 * * * * cd /sdf/home/<u>/<user>/projects/github.com/mjuric/lsst-gen-ephemcache && { ./bin/cron-compute-ephem-cache.sh 2>&1 | /sdf/data/rubin/.../envs/<env>/bin/python ./bin/clean-tqdm.py; }
```

The currently-active line on `sdfcron001` is:

```cron
MAILTO=mjuric@uw.edu
BASH_ENV=/sdf/home/m/mjuric/.bash_profile
TQDM_DISABLE=1

0 * * * * cd /sdf/home/m/mjuric/projects/github.com/mjuric/lsst-gen-ephemcache-dev && { ./bin/cron-compute-ephem-cache.sh 2>&1 | /sdf/data/rubin/user/mjuric/micromamba/envs/mpsky/bin/python ./bin/clean-tqdm.py; }
```

What the cron does, hour by hour:

1. `cron-compute-ephem-cache.sh` computes the **current observing-night
   MJD**: a "night" begins at 17:00 America/Santiago, so until ~17:00
   Chilean local time the script targets *yesterday's* MJD; afterwards,
   today's.
2. If `outputs/caches/eph.<MJD>.<date>.bin` already exists, it logs
   "skipping" and exits. This is why hourly is safe.
3. Otherwise it calls `bin/compute-ephem-cache.sh <MJD> <date> 100` which
   runs the four pipeline stages described below.
4. `EPHEM_RSYNC_TO` is **not set** in the USDF cron; the rsync branch is
   inert here and exists for the epyc install / other deployments.
5. All stdout/stderr is piped through `bin/clean-tqdm.py`, which strips
   `tqdm` progress bars and prefixes each emitted line with a UTC ISO-8601
   timestamp. `TQDM_DISABLE=1` reduces the volume tqdm produces in the
   first place. The cleaned stream is what lands in the cron mail to
   `MAILTO`.

### 2.4 What `compute-ephem-cache.sh` does

```
get-mpcorb.py    →  outputs/catalogs/mpcorb-orbits.<date>.csv
                    outputs/catalogs/mpcorb-colors.<date>.csv
                    outputs/catalogs/mpc_orbits.<date>.sqlite.zst
prepare-run.py   →  outputs/_workdir/{eph.ini, eph.db, orbits-NNNNN.csv,
                                      physical-NNNNN.csv}
exec-sorcha.sh   →  sbatch --array=0-99 ...   (Sorcha + HDF5 conversion;
                                               outputs/_workdir/out.eph.NNNNN.h5)
mpsky build      →  outputs/caches/eph.<MJD>.<date>.bin.tmp  →  .bin
```

SLURM resource expectations:

- `xrun`: 32 GB memory single task — used for the catalog query and
  prepare step.
- `xrun2`: 64 GB, 64 cores — used for `mpsky build`.
- `xbatch`: an array of 100 tasks, 4 GB each (set in `bin/exec-sorcha.sh`
  via `#SBATCH --mem=4gb`). Currently `--mail-user=mjuric@uw.edu` is
  hard-coded in that file; ops should override it (see §4.4).

A successful run takes on the order of 30–60 minutes wall-clock when the
queue is healthy.

### 2.5 Where to find logs

- **Cron mail**: goes to `MAILTO`. This is the first place to look. The
  `clean-tqdm.py` filter prefixes each line with a UTC timestamp, so it's
  easy to grep.
- **Per-array Sorcha logs**: `outputs/_workdir/out.slurm.<task-id>.log`.
  Note that `compute-ephem-cache.sh` runs `rm -rf outputs/_workdir` at the
  start of each invocation, so these only persist for the *most recent*
  build attempt. If you need to retain a failed `_workdir`, copy it out
  before re-running.
- **SLURM**: `squeue -u <user>` for in-flight jobs, `sacct -X -u <user>
  --starttime now-2hours` for recently-finished ones.

### 2.6 Common backend failures

| Symptom in cron mail / log | Likely cause | First-pass fix |
|---|---|---|
| `password authentication failed for user "rubin"` from `get-mpcorb.py` | `~/.pgpass` missing or stale | Update `~/.pgpass` (`172.24.5.71:5432:mpc_sbn:rubin:<pw>`), verify perms `600` |
| `could not connect to server: ... 172.24.5.71` | USDF MPC replica down or networking issue | Check with the team that owns the replica; rerun next hour |
| `sorcha: command not found` / Python ImportError | wrong conda env active | Confirm `ENV` in `ephemcache.config` matches an existing env; `micromamba env list` |
| `sbatch: error: Batch job submission failed` | SLURM queue full or account/partition wrong | `sinfo -p torino`, `sacctmgr show assoc user=$USER`; verify `ephemcache.config` |
| `sanity check failed: there are N input files, but M scheduled jobs` (in `exec-sorcha.sh`) | Stale `_workdir` from a previous run | Delete `outputs/_workdir` and rerun |
| `ERROR: Files out.eph.NNNNN.csv and out.NNNNN.csv are not the same length` | A Sorcha task dropped objects (e.g. fading-function corner case) | Open the offending `out.slurm.<id>.log`; usually re-running the whole build clears it |
| `No space left on device` while writing `outputs/caches/...` | `/sdf/group/rubin/web_data/mpsky-data` full | Reclaim space by deleting old caches/catalogs older than the retention window |
| `skipping` logged every hour but no fresh `.bin` ever appears | Night-MJD was computed but the `.bin` exists from a previous run for that night, so the cron believes it's done | This is correct behaviour; verify with `ls -la outputs/caches/`. To force a rebuild, see §4.1 |

### 2.7 Manually building a cache

To force a rebuild for a specific night (for example, after a partial
failure or to fill in a missed night):

```bash
cd <repo>
micromamba activate lsst-gen-ephemcache

# arguments: <MJD> <YYYY-MM-DD label> <nchunks=100 at USDF>
./bin/compute-ephem-cache.sh 60792 2025-04-27 100
```

The MJD is the night MJD (17:00 Santiago rule). The YYYY-MM-DD label is
arbitrary but conventionally the UTC date the build is performed.

To force the cron to rebuild a night that already exists, `rm` the target
`.bin` before the next hourly tick:

```bash
rm /sdf/group/rubin/web_data/mpsky-data/caches/eph.<MJD>.<date>.bin
```

The next cron run will recompute it; the file is replaced atomically (the
script writes `.bin.tmp` and `mv`s into place).

---

## 3. Service: `mpsky` pod (Phalanx)

### 3.1 App identity

| Item                | Value                                                                  |
|---------------------|------------------------------------------------------------------------|
| Phalanx app         | `mpsky` (`lsst-sqre/phalanx`, `applications/mpsky/`)                   |
| Source repo         | `mjuric/mpsky` (branch `auto-load`)                                    |
| Container image     | `ghcr.io/mjuric/mpsky-daily:auto-load` (`pullPolicy: Always`)          |
| Replicas            | 1                                                                      |
| Container port      | 8080                                                                   |
| Service             | `LoadBalancer`, port 80 → 8080                                         |
| Environment(s)      | `usdf-dev` only (file `values-usdfdev.yaml`)                           |
| Public host (dev)   | `http://usdf-mpsky.sdf.slac.stanford.edu`                              |
| usdf-dev MetalLB IP | `172.24.10.34` (pool `sdf-rubin-ingest`)                               |
| `tmp` storage       | `emptyDir` mounted at `/tmp` (on-disk cache evaporates on pod restart) |
| NetworkPolicy       | Only allows ingress from pods labelled `gafaelfawr.lsst.io/ingress: "true"` |

The pod is launched as:

```
mpsky serve --host 0.0.0.0 --port 8080 --verbose \
            --datastore https://epyc.astro.washington.edu/~mjuric/mpsky-data \
            --max-loaded-nights 7 --max-ondisk-nights 3
```

Note `--max-ondisk-nights 3` — significantly tighter than the CLI default
of 14, because `/tmp` is a small `emptyDir`. If you ever raise this in the
Phalanx values, also check the pod's `tmp` `emptyDir` sizing.

### 3.2 Auto-load behaviour (what the pod is doing under the hood)

When the pod starts:

1. If `--cache_path` is given (it isn't in the Phalanx deployment), the
   single referenced `.bin` is loaded and that's it.
2. Otherwise the service spawns an asyncio task `rollover_to_new_night`
   that wakes every 60 s. Each tick:
   - Computes the **current night** as `utc_to_night(now)` (UTC midnight
     boundary).
   - Calls `get_cache(night)`, which:
     - returns from in-memory LRU if present;
     - else acquires a per-process lock and downloads the matching
       `<datastore>/caches/eph.<night>.<date>.bin` and the latest
       matching catalog (preferring
       `<datastore>/catalogs/mpc_orbits.<date>.sqlite.zst`, falling
       back to `mpcorb-orbits.<date>.csv`);
     - decompresses the `.zst` on the fly, drops the file into
       `/tmp/mpsky-caches.<user>/night-<MJD>/`, and loads it into
       memory.
   - In-memory LRU is capped at `--max-loaded-nights` (deployed: 7).
   - On-disk LRU is capped at `--max-ondisk-nights` (deployed: 3); old
     directories are `rm -rf`'d, but only if they contain the
     `.mpsky-cache-dir` sentinel file.
3. The list of available nights at the datastore is HTML-scraped from
   `<datastore>/caches/` (BeautifulSoup over an Apache-style index) and
   memoized for 60 s.

Practical implication: the pod will retry every minute until it sees the
cache for the current night appear at the datastore. If the backend cron
slips by a few minutes, you'll see retries in the logs; that's normal.

### 3.3 kubectl recipes

Auth (one-time per session):

```bash
# Visit https://k8s.slac.stanford.edu/usdf-rsp-dev , execute the kubectl
# config commands it prints, then:
module load kubectl
kubectl config use-context <usdf-rsp-dev-context>
```

Find the pod and look at its state:

```bash
MPSKY_POD=$(kubectl get pod -n mpsky \
  -l app.kubernetes.io/instance=mpsky,app.kubernetes.io/name=mpsky \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n mpsky get pod "$MPSKY_POD" -o wide
kubectl -n mpsky describe pod "$MPSKY_POD"
kubectl -n mpsky top pod "$MPSKY_POD"
kubectl -n mpsky logs --tail=200 "$MPSKY_POD"
kubectl -n mpsky logs -f "$MPSKY_POD"            # follow
kubectl -n mpsky exec -it "$MPSKY_POD" -- /bin/bash
```

Smoke-test the deployed service from outside the cluster:

```bash
curl -fsS http://usdf-mpsky.sdf.slac.stanford.edu/version
mpsky query 60792.5 32 11 --radius=1.8 \
  --source http://usdf-mpsky.sdf.slac.stanford.edu/ephemerides
```

(`mpsky query` is provided by the `mpsky` Python package; install with
`pip install mpsky` if you don't have it.)

Force a fresh load (the pod has no built-in reload hook):

```bash
kubectl -n mpsky delete pod "$MPSKY_POD"
# Argo CD/the deployment recreates it; on next start it re-downloads
# from the datastore (since /tmp is emptyDir).
```

### 3.4 Logs and monitoring

Logs are aggregated into the SQuaRE Loki/Grafana stack. Bookmark these:

- All `mpsky` app log lines (last 24 h):
  https://grafana.slac.stanford.edu/explore?schemaVersion=1&panes=%7B%220eu%22:%7B%22datasource%22:%223NYPBf44k%22,%22queries%22:%5B%7B%22refId%22:%22A%22,%22expr%22:%22%7Bapp%3D%5C%22mpsky%5C%22%7D%22,%22queryType%22:%22range%22,%22datasource%22:%7B%22type%22:%22loki%22,%22uid%22:%223NYPBf44k%22%7D,%22editorMode%22:%22builder%22,%22maxLines%22:999999%7D%5D,%22range%22:%7B%22from%22:%22now-24h%22,%22to%22:%22now%22%7D,%22panelsState%22:%7B%22logs%22:%7B%22columns%22:%7B%220%22:%22Time%22,%221%22:%22Line%22%7D,%22visualisationType%22:%22table%22,%22labelFieldName%22:%22labels%22%7D%7D%7D%7D&orgId=1
  (Loki query: `{app="mpsky"}`)
- mpsky queries from the prompt-processing namespace (last 24 h):
  https://grafana.slac.stanford.edu/explore?schemaVersion=1&panes=%7B%22b40%22%3A%7B%22datasource%22%3A%223NYPBf44k%22%2C%22queries%22%3A%5B%7B%22refId%22%3A%22A%22%2C%22expr%22%3A%22%7Bnamespace%3D%5C%22vcluster--usdf-prompt-processing%5C%22%7D+%7C%3D+%60mpSkyEphemerisQuery%60%22%2C%22queryType%22%3A%22range%22%2C%22datasource%22%3A%7B%22type%22%3A%22loki%22%2C%22uid%22%3A%223NYPBf44k%22%7D%2C%22editorMode%22%3A%22builder%22%7D%5D%2C%22range%22%3A%7B%22from%22%3A%22now-24h%22%2C%22to%22%3A%22now%22%7D%2C%22panelsState%22%3A%7B%22logs%22%3A%7B%22columns%22%3A%7B%220%22%3A%22Time%22%2C%221%22%3A%22Line%22%7D%2C%22visualisationType%22%3A%22table%22%2C%22labelFieldName%22%3A%22labels%22%7D%7D%7D%7D&orgId=1
  (Loki query:
   `{namespace="vcluster--usdf-prompt-processing"} |= ` `mpSkyEphemerisQuery`)

Useful log lines to grep for:

| Substring                                  | Means                                                       |
|--------------------------------------------|-------------------------------------------------------------|
| `Initial cache file to load:`              | Startup; should immediately be followed by `Cache data store URL:` |
| `rollover_to_new_night: loading current night=` | A new night was detected; download began                |
| `downloading https://.../caches/eph.`      | A `.bin` is being fetched                                  |
| `Loading ephemerides cache from`           | A downloaded `.bin` is being loaded into memory            |
| `evicting night=N from in-memory cache`    | LRU evicted a night (capacity = `max-loaded-nights`)       |
| `evicting <dir> from on-disk cache`        | LRU evicted a downloaded directory                         |
| `Processing time X msec [GET /ephemerides...]` | Per-request timing for queries                         |
| `no cache for night=...`                   | The datastore listing didn't have a `.bin` for that night  |

**Alerting gap.** There are no Prometheus/Alertmanager alerts wired up
today. Suggested alerts (none of these exist yet):

- Pod has no cache for `today`'s night MJD T+90 min after the cron should
  have produced it (page).
- Pod restart loop / `OOMKilled`.
- `image-pull` failures from `ghcr.io/mjuric/mpsky-daily`.
- `/version` returns non-200 from an in-cluster prober.

### 3.5 Common service failures

| Symptom | Likely cause | Fix |
|---|---|---|
| Logs spam `no cache for night=N present in <datastore>` | Backend cron didn't produce tonight's cache | Check §2: cron mail, Sorcha logs, SLURM queue. Service will recover on its own once the cache appears |
| Logs spam `couldn't download .sqlite db, falling back to .csv` | The new sqlite.zst path didn't propagate yet | Harmless; service uses CSV fallback. If persistent, verify `mpc_orbits.<date>.sqlite.zst` exists at the datastore |
| Pod `OOMKilled` | `--max-loaded-nights` too high for pod memory limits | Lower it in `applications/mpsky/templates/deployment.yaml` and resync, or raise pod memory in `values.yaml` |
| `/tmp` exhausted, downloads fail with `ENOSPC` | `--max-ondisk-nights` too high vs. emptyDir size | Lower the flag, or size up `volumes.tmp` `emptyDir` `sizeLimit` in values |
| `ImagePullBackOff` | ghcr image missing/private; the chart pulls `auto-load` tag with `pullPolicy: Always` | Confirm `ghcr.io/mjuric/mpsky-daily:auto-load` exists publicly; rebuild with §4.3 if needed |
| External clients get 403/404 even though the pod looks healthy | NetworkPolicy only admits pods labelled `gafaelfawr.lsst.io/ingress: "true"`; or DNS for `usdf-mpsky.sdf.slac.stanford.edu` not resolving | Confirm ingress label; `dig usdf-mpsky.sdf.slac.stanford.edu`; check MetalLB allocation |
| `/ephemerides` returns 400 with a JSON `{"message": "..."}` body | The service's catch-all exception handler converted an internal error to a 400; details are in pod logs | `kubectl logs` and look at the matching `Processing time` line |

---

## 4. Routine tasks

### 4.1 Force a rebuild of a specific night

```bash
# On sdfcron001 as the cron user.
cd <repo>
rm -f outputs/caches/eph.<MJD>.<date>.bin   # deletes from the served dir
./bin/compute-ephem-cache.sh <MJD> <date> 100   # or wait for the next cron tick
```

If the cache has already been downloaded and loaded by the running mpsky
pod, the pod will keep serving the *old* version from memory until a
restart or until that night ages out of the in-memory LRU (after
`max-loaded-nights` newer nights have been loaded). To make it pick up the
fresh `.bin` immediately:

```bash
kubectl -n mpsky delete pod "$MPSKY_POD"
```

### 4.2 Cut over the datastore URL (epyc → s3df)

Today the deployed Phalanx args contain:

```
--datastore https://epyc.astro.washington.edu/~mjuric/mpsky-data
```

To flip the pod to the USDF backend:

1. **Pre-flight check**. Confirm the USDF datastore is healthy:
   ```bash
   curl -fsI https://s3df.slac.stanford.edu/data/rubin/mpsky-data/caches/ \
     | head -1
   curl -fsS https://s3df.slac.stanford.edu/data/rubin/mpsky-data/caches/ \
     | grep -E 'eph\.[0-9]+\.[0-9-]+\.bin' | tail -3
   ```
   You should see at least the cache for the current observing night.
2. **Edit the Phalanx values**. In `lsst-sqre/phalanx`:
   - Either change `--datastore` directly in
     `applications/mpsky/templates/deployment.yaml`, or (preferred) hoist
     it into `values.yaml` (e.g. `mpsky.datastoreUrl`) and set the new URL
     in `values-usdfdev.yaml`.
   - Open a PR; once merged, Argo CD picks it up.
3. **Sync via Argo CD**. The `mpsky` application syncs in the
   usdf-rsp-dev cluster.
4. **Verify**:
   ```bash
   kubectl -n mpsky logs --tail=20 "$MPSKY_POD" | grep -i 'data store'
   curl -fsS http://usdf-mpsky.sdf.slac.stanford.edu/version
   mpsky query 60792.5 32 11 --radius=1.8 \
     --source http://usdf-mpsky.sdf.slac.stanford.edu/ephemerides
   ```
5. **Rollback**. Revert the Phalanx PR; Argo CD will resync.

### 4.3 Rebuild and publish a new `mpsky` container image

There is no CI for the image today; this is manual and not reproducible
(no version pins). The Dockerfile lives in `mjuric/mpsky` at
`docker/Dockerfile`.

```bash
git clone https://github.com/mjuric/mpsky.git
cd mpsky/docker
make build         # builds ghcr.io/mjuric/mpsky-daily locally, branch defaults
                   # to main; override with: make build MPSKY_BRANCH=auto-load
make push          # pushes to ghcr.io/mjuric/mpsky-daily
```

You'll need write access to `ghcr.io/mjuric/mpsky-daily`. If the Phalanx
chart is pinned to a specific tag (it is — `auto-load`), bump
`image.tag` in `values.yaml` to the new tag and open a PR; otherwise
because `pullPolicy: Always`, just deleting the pod will pick up the
latest content of the `auto-load` tag.

> **Open improvements**: the docker README itself flags the build as
> not-yet-ready-for-broad-use and irreproducible. Migrating to a
> versioned, CI-built image is recommended; out of scope for this
> runbook.

### 4.4 Promote dev → prod (`usdfprod`)

There is no `values-usdfprod.yaml` today and no firm timeline for one.
When you're ready, the rough checklist is:

1. **Argo CD environment**. Ensure the Phalanx `usdfprod` (or whatever
   prod env name) is registered.
2. **Values file**. Add `applications/mpsky/values-usdfprod.yaml` with at
   minimum:
   - `serviceAnnotations` selecting the prod MetalLB pool and IP.
   - Any environment-specific `--datastore` URL override (if you don't
     hoist it into `values.yaml`).
3. **Image**. Decide whether prod tracks the same `auto-load` tag as dev
   (with `pullPolicy: Always`) or pins to an immutable tag (recommended
   for prod once you have versioned images).
4. **Resource sizing**. Set explicit `resources.requests` and
   `resources.limits` in the values file. Today they're empty in the
   chart.
5. **Smoke test**. `mpsky query` against the prod public host once Argo
   CD has synced.
6. **DNS / ingress**. Register the prod public hostname (analogous to
   `usdf-mpsky.sdf.slac.stanford.edu`).
7. **Network policy**. Confirm prompt processing pods in prod carry the
   `gafaelfawr.lsst.io/ingress: "true"` label.

### 4.5 Updating the backend code on `sdfcron001`

```bash
ssh sdfcron001
cd <repo>
git fetch origin
git checkout unpacked-desig
git pull --ff-only

# If install.sh changed or new conda deps were added, recreate or update
# the env (cheaper to recreate from scratch when in doubt):
micromamba env remove -n lsst-gen-ephemcache
./install.sh lsst-gen-ephemcache
# then re-apply the USDF ephemcache.config (§2.2)
```

The cron has `BASH_ENV=...bash_profile` so any env-var changes you make in
`.bash_profile` apply to the next tick automatically.

---

## 5. Reference

### 5.1 File-name conventions on the datastore

```
<datastore>/caches/eph.<MJD>.<YYYY-MM-DD>.bin
<datastore>/catalogs/mpcorb-orbits.<YYYY-MM-DD>.csv
<datastore>/catalogs/mpcorb-colors.<YYYY-MM-DD>.csv
<datastore>/catalogs/mpc_orbits.<YYYY-MM-DD>.sqlite.zst
```

- `<MJD>` is the **observing-night MJD** (17:00 Santiago rollover).
- `<YYYY-MM-DD>` is the build label; conventionally the UTC date the
  build was performed. Multiple builds for the same `<MJD>` may exist
  with different labels — the service picks the most recent label
  alphabetically (`max(avail_caches[night])`).

### 5.2 Service HTTP API

| Endpoint                                           | Description                                                             |
|----------------------------------------------------|-------------------------------------------------------------------------|
| `GET /`                                            | Liveness probe; returns `{"Hello": "World"}`                            |
| `GET /version`                                     | Returns `{"version": ..., "commit_id": ...}`                            |
| `GET /ephemerides/?t=&ra=&dec=&radius=&return_elements=` | Main query. Returns Apache Arrow IPC bytes (`application/octet-stream`). `t` is MJD; `ra`/`dec`/`radius` are degrees; `return_elements` is `none` (default), `basic`, or `extended` (or legacy bool) |

The Arrow payload columns are `name, ra, dec, ast_cheby, topo_cheby,
tmin, tmax`, plus the requested element columns when
`return_elements != none`. The Python client API is `mpsky.client.query()`
or the `mpsky query` CLI.

### 5.3 Night-MJD definitions

- **Backend (cron)**: a "night" begins at 17:00 America/Santiago. The
  conversion is in `bin/cron-compute-ephem-cache.sh` (`get_current_night_mjd`):
  subtract 17 hours from current Chilean local time, take the date, and
  convert that midnight to MJD.
- **Service (rollover)**: a "night" is `int(mjd_utc)`, i.e. the night
  flips at UTC midnight (`ac.utc_to_night`).

The two definitions agree most of the time. Around 03:00–04:00 UTC (which
is 00:00–01:00 in Santiago, summer time) the backend definition will
sometimes be one MJD behind the service's definition for a few hours.
Practically this means the service may briefly look for a cache the
backend hasn't yet built; the service retries every 60 s.

### 5.4 Repos and branches

| Component                  | Repo                                                  | Branch         |
|----------------------------|-------------------------------------------------------|----------------|
| Backend (cache builder)    | https://github.com/mjuric/lsst-gen-ephemcache         | `unpacked-desig` |
| Service (`mpsky`)          | https://github.com/mjuric/mpsky                       | `auto-load`    |
| Phalanx app                | https://github.com/lsst-sqre/phalanx                  | `main`, path `applications/mpsky/` |
| Service container image    | `ghcr.io/mjuric/mpsky-daily`                          | tag `auto-load`  |

### 5.5 Known drift and follow-ups for ops

These are items the runbook deliberately documents because the code/config
doesn't match operational reality and should eventually be cleaned up:

- `install.sh` writes an `ephemcache.config` whose `MPCDB`, `SRUN`, and
  `SBATCH` defaults do not match USDF reality (epyc DB, partition `roma`,
  account `rubin:default@roma`). USDF uses the values in §2.2.
- The Phalanx deployment hard-codes `--datastore
  https://epyc.astro.washington.edu/~mjuric/mpsky-data` even though the
  USDF backend writes to `https://s3df.slac.stanford.edu/data/rubin/mpsky-data/`.
  This is the cutover described in §4.2.
- `bin/exec-sorcha.sh` hard-codes `--mail-user=mjuric@uw.edu`. Once ops
  takes over, change this to an ops mailbox.
- The container image (`ghcr.io/mjuric/mpsky-daily:auto-load`) is built
  manually with no version pinning and no CI. Migrating to a CI-built,
  versioned image is recommended.
- There are no Prometheus/Alertmanager alerts on the pod or on stale
  caches. See §3.4 for suggested alerts.
