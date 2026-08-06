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

# Patch the in-image copy of install.sh before running it. Four problems:
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
#  4. install.sh clones mpsky with no ref, so the image tracks whatever `main`
#     happens to be at build time. The mpsky service deployed at usdfdev runs
#     9fd38d2 from the `auto-load` branch, which is NOT an ancestor of main --
#     eight-plus commits exist only there. The two have already diverged far
#     enough to be incompatible on the wire: a main-built client cannot parse
#     the deployed service's /ephemerides response at all, failing in
#     `ipc_read` with "Expected to read 1699226235 metadata bytes, but only
#     read 13". Since this image *builds* the caches that service reads, it
#     should be built from the same branch.
#
#     Still not pinned. `auto-load`'s tip is 9fd38d2 as of 2026-08-06, exactly
#     what is deployed, but a branch tip moves; only the branch has changed, not
#     the floating. A commit pin belongs with the rest of the version pinning
#     (D16/D13).
#
# Done as a pre-step rather than `install.sh || true` plus a repair, because a
# `|| true` would mask real failures.
#
# Also drop `sorcha bootstrap` from install.sh and run it ourselves below, so
# that sorcha's download URLs can be adjusted first. Removing it here rather
# than letting it run and fail is the only option: it is the LAST thing
# install.sh does, so there is no later step to recover in.
RUN sed -i 's/ zstandard --yes/ zstandard shapely "pandas<3" "python<3.14" --yes/' install.sh \
 && sed -i '/^sorcha bootstrap --cache sorcha_cache$/d' install.sh \
 && ! grep -q '^sorcha bootstrap' install.sh \
 && sed -i 's|^git clone https://github.com/mjuric/mpsky.git$|git clone -b auto-load https://github.com/mjuric/mpsky.git|' install.sh \
 && grep -q '^git clone -b auto-load https://github.com/mjuric/mpsky.git$' install.sh \
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
#
# The clean must be in this same RUN. A later layer cannot shrink an earlier one,
# so cleaning separately would leave the package cache in the image and merely
# add a whiteout on top of it.
RUN MAMBA=mamba ./install.sh ephemcache \
 && conda clean -afy

# Fetch the SPICE/JPL kernels and the observatory-code table, in their own
# layer so a code change does not re-download ~780 MB.
#
# The chmod at the end is not cosmetic. pooch writes each download through a
# temporary file with mode 600, and this build runs as root, so every kernel
# lands root-owned and unreadable by anyone else. A non-root pod then fails with
# "The JPL planet ephemeris file has not been found" -- which is a permission
# denial wearing a missing-file error message. The previously deployed install
# never hit this because it ran as the user who owned the files.
#
# The observatory-code table comes from a mirror rather than upstream.
# sorcha defaults to
#   https://minorplanetcenter.net/Extended_Files/obscodes_extended.json.gz
# which the Minor Planet Center appears to refuse from datacenter address
# ranges: GitHub-hosted runners retry it ~25 times and fail, while the same
# fetch succeeds from USDF. The mirror serves a byte-identical file (77299
# bytes) and is reachable from CI. The JPL/NAIF kernel URLs are left alone —
# those download from runners without trouble.
#
# `sorcha bootstrap` accepts no --config, so this default cannot be overridden
# from a configuration file; the installed module has to be edited. The grep
# both proves the substitution landed and records the effective URL in the
# build log.
ARG OBSCODES_URL=https://epyc.astro.washington.edu/~mjuric/obscodes_extended.json.gz
RUN . /opt/conda/etc/profile.d/conda.sh && conda activate ephemcache \
 && CFG="$(python -c 'import sorcha.utilities.sorchaConfigs as m; print(m.__file__)')" \
 && sed -i "s|https://minorplanetcenter.net/Extended_Files/obscodes_extended.json.gz|${OBSCODES_URL}|" "$CFG" \
 && grep -n 'obscodes_extended' "$CFG" \
 && sorcha bootstrap --cache sorcha_cache \
 && chmod -R a+rX sorcha_cache \
 && ls -l sorcha_cache | head -3

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

# stdout is a pipe rather than a tty in a pod, so Python block-buffers by
# default and emits in 4-8 KB bursts. That defeats live log following and makes
# the per-line timestamps added by bin/clean-tqdm.py record when the buffer was
# flushed rather than when the line was produced.
ENV PYTHONUNBUFFERED=1

RUN chmod +x /app/bin/container-entrypoint.sh
ENTRYPOINT ["/app/bin/container-entrypoint.sh"]
CMD ["run"]
