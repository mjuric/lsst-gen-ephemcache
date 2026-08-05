# Ephemerides cache generator — MVP image.
#
# Installs via this repo's own install.sh, unchanged, per ephemcache-deploy
# D16. install.sh has several baked-in assumptions that are wrong for a
# container; they are corrected here rather than by editing the script, so
# that this repo's existing (epyc, SLURM) workflow keeps working.
#
# Build:  podman build -t ephemcache:dev .      (or docker, or GitHub Actions)
# On USDF podman needs extra flags — see ephemcache-deploy
# notes/2026-08-05-podman-on-usdf.md.

FROM docker.io/condaforge/miniforge3:latest

# GNU parallel is NOT in the base image, and compute-ephem-cache.sh needs it
# for the KIND=parallel fan-out. tzdata is required too: without it glibc
# does NOT error on TZ=America/Santiago, it silently stays on UTC, and the
# 17:00 night rollover then computes the wrong observing night.
#
# APT::Sandbox::User=root: apt normally drops privileges to _apt (uid 42),
# which fails under a single-uid rootless podman mapping (no subuid range on
# USDF). Harmless under rootful docker, so it stays in the committed file.
RUN apt-get -o APT::Sandbox::User=root update \
 && apt-get -o APT::Sandbox::User=root install -y --no-install-recommends \
      parallel tzdata \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Patch the in-image copy of install.sh before running it. Two problems:
#
#  1. conda-forge sorcha 1.2.0 does not declare shapely among its
#     dependencies, but sorcha/modules/PPVisitsFootprintFilter.py imports it,
#     so `sorcha bootstrap` dies with ModuleNotFoundError.
#  2. install.sh constrains no versions at all, so a fresh solve picks the
#     newest interpreter — Python 3.14 at time of writing, newer than this
#     stack has been exercised against.
#
# Done as a pre-step, not as `install.sh || true` plus a repair: sorcha
# bootstrap is the LAST thing install.sh does, so there is no later step to
# recover in, and `|| true` would mask real failures.
RUN sed -i 's/ zstandard --yes/ zstandard shapely "python<3.14" --yes/' install.sh

# install.sh looks for micromamba; miniforge3 ships mamba.
RUN MAMBA=mamba ./install.sh ephemcache

# install.sh hardcodes epyc as the database:
#   MPCDB='postgresql+psycopg2://sssc@epyc.astro.washington.edu/mpc_sbn'
# bin/compute-ephem-cache.sh and bin/exec-sorcha.sh source this file, so left
# alone the container would query epyc over the WAN with a credential we do
# not provision. Default to the USDF-internal replica, overridable by env.
RUN sed -i \
      -e "s|^MPCDB=.*|MPCDB=\"\${MPCDB:-postgresql+psycopg2://rubin@172.24.5.71/mpc_sbn}\"|" \
      ephemcache.config \
 && grep -nE '^MPCDB|^ENV=|^KIND=' ephemcache.config

# Nothing above is version-pinned, so record what was actually resolved.
# Until a lockfile lands, this is the only way to answer "which sorcha
# produced eph.<MJD>.<date>.bin?".
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && mamba list --explicit > /app/build-manifest.conda.txt 2>/dev/null || true \
 && pip freeze > /app/build-manifest.pip.txt 2>/dev/null || true \
 && (cd /app/mpsky && git rev-parse HEAD > /app/build-manifest.mpsky-sha.txt) || true

# NCORES is deliberately NOT defaulted here. The scripts fall back to nproc,
# which reports the NODE's cpu count rather than the pod's cpu limit, and
# stage 3 uses ~4 GB per parallel chunk — so an unset NCORES on a large node
# oversubscribes and can OOM the pod. The CronJob must set it to match
# resources.limits.cpu. `selftest` warns when it is unset.

RUN chmod +x /app/bin/container-entrypoint.sh
ENTRYPOINT ["/app/bin/container-entrypoint.sh"]
CMD ["run"]
