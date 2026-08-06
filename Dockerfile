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
#  3. pandas 3 makes Copy-on-Write mandatory, so arrays from `.values` are
#     read-only. mpsky/core.py:124 does an in-place `t -= tmin` on one, which
#     was legal under pandas 2 and now raises
#         ValueError: output array is read-only
#     killing `mpsky build` at stage 4 after the whole fan-out has completed.
#     CoW cannot be disabled in pandas 3 — the opt-out was removed — so the
#     version has to be held back. sorcha only asks for pandas>=2.0, so 2.x
#     satisfies it. Tracked upstream for a proper fix in mpsky.
#
# Done as a pre-step rather than `install.sh || true` plus a repair, because a
# `|| true` would mask real failures.
#
# Also drop `sorcha bootstrap` from install.sh: the kernels are no longer baked
# into the image at all, and are fetched by the entrypoint on first use instead.
# Removing it here is the only option -- it is the LAST thing install.sh does, so
# there is no later step in which to undo it.
RUN sed -i 's/ zstandard --yes/ zstandard shapely "pandas<3" "python<3.14" --yes/' install.sh \
 && sed -i '/^sorcha bootstrap --cache sorcha_cache$/d' install.sh \
 && ! grep -q '^sorcha bootstrap' install.sh \
 && sed -i 's/parallel --halt now,fail=1 --bar /parallel --halt now,fail=1 /' \
      bin/compute-ephem-cache.sh \
 && ! grep -q -- '--bar' bin/compute-ephem-cache.sh

# GNU parallel's --bar renders its progress display to /dev/tty, which does not
# exist in a pod, so every refresh spawns `sh` and fails with
#   sh: 1: cannot open /dev/tty: No such device or address
# once per update -- interleaved with fragments of the bar itself. Harmless (the
# bar's shell is separate from the job shells, so --halt never sees it) but it
# buries real errors in the pod log. Removed above, in the same spirit as the
# repo's own bin/clean-tqdm.py, which exists to strip progress bars for exactly
# this reason.

# install.sh looks for micromamba; miniforge3 ships mamba.
RUN MAMBA=mamba ./install.sh ephemcache

# The kernels are NOT baked in. They live in a subdirectory of the mounted output
# directory and are fetched on first use by the entrypoint, which keeps ~780 MB
# out of the image. Only two places reference them and both are cwd-relative
# (compute-ephem-cache.sh's -d test and exec-sorcha.sh's --ar), so a symlink is
# enough and no script needs changing. It has to be made at build time because
# /app is root-owned and the pod runs non-root; it dangles until the volume is
# mounted, which is fine because nothing dereferences it before then.
#
# This reverses D4's "bake sorcha_cache into the image". The cost is hermeticity:
# the kernels become mutable state outside the image, so "which kernels produced
# this cache?" is no longer answerable from the image tag alone. The entrypoint
# logs a kernel inventory on every run to compensate.
RUN ln -s outputs/sorcha_cache /app/sorcha_cache

# sorcha's observatory-code URL still has to be patched here rather than at
# runtime, because the edit is to an installed module and /opt/conda is
# root-owned. The Minor Planet Center refuses that file from datacenter address
# ranges -- GitHub runners retry ~25 times and fail -- so it comes from a mirror
# serving a byte-identical copy. The JPL/NAIF kernel URLs are left alone; those
# fetch fine. `sorcha bootstrap` accepts no --config, so the module is the only
# place this can be set. The grep records the effective URL in the build log.
ARG OBSCODES_URL=https://epyc.astro.washington.edu/~mjuric/obscodes_extended.json.gz
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && CFG="$(python -c 'import sorcha.utilities.sorchaConfigs as m; print(m.__file__)')" \
 && sed -i "s|https://minorplanetcenter.net/Extended_Files/obscodes_extended.json.gz|${OBSCODES_URL}|" "$CFG" \
 && grep -n 'obscodes_extended' "$CFG"

# ephemcache.config is meant to be edited after install.sh seeds it with a
# default; in a container this Dockerfile is the editor. install.sh writes
#   MPCDB='postgresql+psycopg2://sssc@epyc.astro.washington.edu/mpc_sbn'
# and bin/compute-ephem-cache.sh sources that file, so left alone the container
# would query epyc over the WAN. Point it at the USDF-internal replica.
#
# NO USERNAME OR PASSWORD IN THE DSN, deliberately. Credentials come from
# libpq's PGUSER/PGPASSWORD, which psycopg2 honours when the URL omits them.
# That keeps the password out of the process arguments: compute-ephem-cache.sh
# passes this value to get-mpcorb.py as `--db`, so a password embedded here
# would sit in argv and in any traceback that prints it.
#
# Mind the form. "//172.24.5.71/mpc_sbn" parses to username=None, which is what
# lets PGUSER apply. Adding an @ -- "//@172.24.5.71/mpc_sbn" -- instead yields
# username='', an explicit empty user that overrides PGUSER. Verified with
# sqlalchemy.engine.make_url.
#
# ${MPCDB:-...} keeps it overridable from the environment; install.sh's plain
# assignment would otherwise clobber whatever the pod sets, because the config
# is sourced after the environment is in place.
RUN sed -i \
      -e "s|^MPCDB=.*|MPCDB=\"\${MPCDB:-postgresql+psycopg2://172.24.5.71/mpc_sbn}\"|" \
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

# / is mode 555 and HOME is unset, so anything that expects a writable home
# directory fails. matplotlib is the one that shows up in the logs --
#   mkdir -p failed for path /.config/matplotlib: [Errno 13] Permission denied
# once per sorcha chunk -- but it is a general problem, so point HOME somewhere
# writable rather than special-casing one library. /tmp is mode 1777.
ENV HOME=/tmp
ENV MPLCONFIGDIR=/tmp/matplotlib

# Silence two lines that sbpy provokes on every interpreter start -- 2 lines x
# 100 sorcha chunks per run:
#   WARNING: AstropyDeprecationWarning: The TestRunner class is deprecated ...
#   WARNING: AstropyDeprecationWarning: The TestRunnerBase class is deprecated ...
# Nothing is running tests. sbpy imports astropy.tests.runner, whose TestRunner
# and TestRunnerBase classes carry @deprecated, and that decorator fires when the
# class is DEFINED, i.e. at import. Verified: `import astropy` alone emits
# nothing, `import sbpy` emits both.
#
# Matched on message prefix only. "The TestRunner" also prefixes
# "The TestRunnerBase", so one filter covers both, and it deliberately does NOT
# filter by category: suppressing AstropyDeprecationWarning wholesale would also
# hide real deprecations from sorcha's numerics. Verified that unrelated
# DeprecationWarnings and other AstropyDeprecationWarning text still appear.
#
# Naming the category here would also force an astropy import at every
# interpreter startup just to resolve it, which is not worth it for a message
# this specific.
ENV PYTHONWARNINGS="ignore:The TestRunner"

RUN chmod +x /app/bin/container-entrypoint.sh
ENTRYPOINT ["/app/bin/container-entrypoint.sh"]
CMD ["run"]
