#!/bin/bash
#
# Container entrypoint. Dispatches to a subcommand:
#
#   selftest      run every environment check, print a summary, exit non-zero
#                 if any FAILed. Needs no database and no secrets.
#   selftest --with-db
#                 additionally try to reach and authenticate to $MPCDB.
#   run           build the cache for the current observing night
#                 (bin/cron-compute-ephem-cache.sh)
#   <anything>    exec'd as given, so `bash`, `python`, ... still work
#
# The scripts use cwd-relative paths throughout (outputs/, configs/,
# sorcha_cache/), so everything runs from /app.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ---------------------------------------------------------------- selftest ---

pass=0
fail=0
warn=0

# ---------------------------------------------------------------- kernels ---

# /app/sorcha_cache is a symlink to outputs/sorcha_cache, so the kernels live on
# the mounted output volume rather than in the image. That keeps ~780 MB out of
# every pull, at the cost of a one-off download the first time a volume is used.
activate_env() {
	[[ -f ephemcache.config ]] || return 1
	# shellcheck disable=SC1091
	. ./ephemcache.config
	if [[ "${CONDA_DEFAULT_ENV:-}" != "${ENV:-}" ]]; then
		# conda's shell hook is not `set -u` safe; it reads $PS1 unguarded.
		set +u
		eval "$(${MAMBA:-mamba} shell hook --shell bash)" 2>/dev/null
		${MAMBA:-mamba} activate "$ENV" 2>/dev/null
		set -u
	fi
	[[ "${CONDA_DEFAULT_ENV:-}" == "${ENV:-}" ]]
}

# The planetary ephemeris is the largest file and the one a run dies on first, so
# use it as the marker for "the cache is usable" rather than merely present.
kernels_present() {
	[[ -r sorcha_cache/linux_p1550p2650.440 ]]
}

ensure_kernels() {
	kernels_present && return 0

	local real="outputs/sorcha_cache"    # what the sorcha_cache symlink points at
	echo "sorcha_cache absent at $real — bootstrapping (~780 MB, one-off per volume)"

	# Build in a temporary directory and move it into place, so that a second pod
	# starting concurrently cannot observe or inherit a half-written kernel set.
	# concurrencyPolicy: Forbid covers scheduled runs but not a manual Job racing
	# one.
	local tmp="${real}.incoming.$$"
	rm -rf "$tmp"; mkdir -p "$tmp" || { echo "cannot create $tmp" >&2; return 1; }
	if ! sorcha bootstrap --cache "$tmp"; then
		echo "sorcha bootstrap failed" >&2; rm -rf "$tmp"; return 1
	fi
	# pooch writes each download through a mode-600 temp file; make them readable
	# in case this pod's uid is ever not the one that reads them.
	chmod -R a+rX "$tmp" 2>/dev/null || true
	if [[ -d "$real" ]]; then
		echo "another process populated $real first — discarding ours"
		rm -rf "$tmp"
	else
		mv "$tmp" "$real" || { echo "could not move $tmp into place" >&2; rm -rf "$tmp"; return 1; }
	fi
	kernels_present
}

# D4 used to pin the kernels by baking them into the image, so the image tag
# answered "which physics produced this cache?". They now live on a mutable
# volume, so record what was actually used on every run instead.
log_kernel_inventory() {
	echo "-- kernel inventory ($(readlink -f sorcha_cache 2>/dev/null)) --"
	find sorcha_cache/ -maxdepth 1 -type f -printf '   %10s  %TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort -k4
}

ok()   { printf '  PASS  %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$*"; warn=$((warn+1)); }

selftest() {
	local with_db=0
	[[ "${1:-}" == "--with-db" ]] && with_db=1

	echo "=== ephemcache image selftest ==="
	echo "image built for: $(uname -m), $(cat /etc/os-release 2>/dev/null | sed -n 's/^PRETTY_NAME=//p' | tr -d '\"')"
	echo

	echo "-- layout --"
	[[ -d bin ]]          && ok "bin/ present"          || bad "bin/ missing"
	[[ -d configs ]]      && ok "configs/ present"      || bad "configs/ missing"
	[[ -f configs/eph.ini ]] && ok "configs/eph.ini present" || bad "configs/eph.ini missing"
	# The kernels are not in the image; they are fetched into the output volume on
	# first use. Absent is therefore a normal state to report, not a failure — but
	# when they ARE there, check they are usable rather than merely present.
	if ! kernels_present; then
		printf '  info  %s\n' "sorcha_cache/ not populated yet — \`run\` will bootstrap it"
		printf '  info  %s\n' "      into $(readlink sorcha_cache 2>/dev/null || echo outputs/sorcha_cache) (~780 MB, one-off per volume)"
	else
		ok "sorcha_cache/ present ($(du -sh sorcha_cache/ 2>/dev/null | cut -f1))"

		# Presence is not enough: pooch writes downloads through a mode-600
		# temporary file, so as built they are readable only by the user that
		# ran the build. A non-root pod then fails deep into a run with "The
		# JPL planet ephemeris file has not been found", which is a permission
		# denial wearing a missing-file message. Check readability, not
		# existence — `du` above stats without opening anything.
		local unreadable
		unreadable=$(find sorcha_cache -type f ! -readable 2>/dev/null | wc -l)
		if [[ "$unreadable" -eq 0 ]]; then
			ok "all $(find sorcha_cache -type f | wc -l) kernels readable as uid $(id -u)"
		else
			bad "$unreadable file(s) in sorcha_cache unreadable as uid $(id -u) — sorcha will"
			bad "      report them as missing. The bootstrap should chmod a+rX."
			find sorcha_cache -type f ! -readable -printf '        %M %u %n %f\n' 2>/dev/null | head -4
		fi

		# The planetary ephemeris is the one the run dies on first, so name it.
		for _k in linux_p1550p2650.440 de440s.bsp sb441-n16.bsp; do
			if [[ -r "sorcha_cache/$_k" ]]; then
				ok "$_k readable"
			else
				bad "$_k missing or unreadable — a real run will fail at sorcha-run"
			fi
		done
	fi

	echo
	echo "-- timezone (a silent-wrong-answer bug if broken) --"
	# glibc does NOT error on an unresolvable zone; it treats the name as a
	# literal abbreviation and stays on UTC. The night rollover is at 17:00
	# Santiago, so a missing tzdata quietly computes the wrong night.
	local zone=/usr/share/zoneinfo/America/Santiago
	[[ -f $zone ]] && ok "$zone exists" || bad "$zone missing — tzdata not installed"
	local off
	off=$(TZ=America/Santiago date +%z)
	if [[ "$off" == "+0000" ]]; then
		bad "TZ=America/Santiago gives $off — tzdata broken, night would be wrong"
	else
		ok "TZ=America/Santiago offset is $off"
	fi

	echo
	echo "-- required tools --"
	local t
	for t in parallel awk date bash git; do
		if command -v "$t" >/dev/null 2>&1; then
			ok "$t: $(command -v $t)"
		else
			bad "$t: MISSING"
		fi
	done
	# GNU date is required: the night calculation uses `date -d`.
	if date -d "17 hours ago" +%Y-%m-%d >/dev/null 2>&1; then
		ok "date supports -d (GNU)"
	else
		bad "date does not support -d — night calculation will fall back/fail"
	fi

	echo
	echo "-- configuration --"
	if [[ -f ephemcache.config ]]; then
		ok "ephemcache.config present"
		# shellcheck disable=SC1091
		. ./ephemcache.config
		[[ -n "${ENV:-}" ]]  && ok "ENV=$ENV"   || bad "ENV unset"
		[[ "${KIND:-}" == "parallel" ]] && ok "KIND=parallel" \
			|| bad "KIND=${KIND:-unset} — expected 'parallel' in a container"
		# Parse the DSN without ever echoing it whole: it is the one string
		# here that could carry a password.
		#   postgresql+psycopg2://[user[:pass]@]host[:port]/database
		local _auth _userinfo _dbhost
		_auth="${MPCDB#*://}"; _auth="${_auth%%/*}"     # authority
		_dbhost="${_auth##*@}"                          # host[:port]
		_userinfo=""
		[[ "$_auth" == *@* ]] && _userinfo="${_auth%@*}"

		if [[ -z "${MPCDB:-}" ]]; then
			bad "MPCDB unset"
		elif [[ "$MPCDB" == *epyc.astro.washington.edu* ]]; then
			# Deliberately does NOT print $MPCDB — it may carry a password.
			bad "MPCDB still points at epyc — the config was not rewritten"
		elif [[ "$_userinfo" == *:* ]]; then
			# A password in the DSN would reach argv, because
			# compute-ephem-cache.sh passes it as `get-mpcorb.py --db "$MPCDB"`,
			# and from there into any traceback that prints the command line.
			# Credentials belong in PGUSER/PGPASSWORD.
			bad "MPCDB embeds a password — move it to PGPASSWORD (it would leak via argv)"
		else
			ok "MPCDB set, host: $_dbhost, no credentials in DSN"
		fi

		# Credentials come from libpq's environment. Report only whether they
		# are present — never the values, and never their length.
		if [[ -n "${PGUSER:-}" ]]; then
			ok "PGUSER is set"
		else
			note "PGUSER unset — libpq will fall back to the OS user, which"
			note "      has no database account. Needed before \`run\`."
		fi
		if [[ -n "${PGPASSWORD:-}" ]]; then
			ok "PGPASSWORD is set"
		else
			note "PGPASSWORD unset — needed before \`run\`; harmless for selftest"
		fi
	else
		bad "ephemcache.config missing — install.sh did not complete"
	fi

	echo
	echo "-- python environment --"
	if [[ -n "${ENV:-}" ]]; then
		# The compute scripts self-activate, but do it here too so imports work.
		# conda/mamba's shell hook is not `set -u` safe — it reads $PS1 and
		# friends unguarded, which would abort this script outright — so drop
		# -u for the activation only.
		if [[ "${CONDA_DEFAULT_ENV:-}" != "$ENV" ]]; then
			set +u
			eval "$(${MAMBA:-mamba} shell hook --shell bash)" 2>/dev/null
			${MAMBA:-mamba} activate "$ENV" 2>/dev/null
			set -u
		fi
		[[ "${CONDA_DEFAULT_ENV:-}" == "$ENV" ]] && ok "conda env '$ENV' active" \
			|| bad "could not activate conda env '$ENV'"
	fi
	local mod
	for mod in sorcha sqlalchemy psycopg2 zstandard numpy pandas; do
		if python -c "import $mod" >/dev/null 2>&1; then
			ok "import $mod"
		else
			bad "import $mod FAILED"
		fi
	done
	for t in sorcha mpsky; do
		command -v "$t" >/dev/null 2>&1 && ok "$t: $(command -v $t)" || bad "$t: MISSING"
	done
	echo "  info  versions: $(python -c 'import sys;print("python "+sys.version.split()[0])' 2>/dev/null)$(python -c 'import sorcha,numpy;print(", sorcha "+sorcha.__version__+", numpy "+numpy.__version__)' 2>/dev/null)"

	echo
	echo "-- output directory --"
	# The scripts write here directly: this is both the working area and the
	# published location, so a cache appears where consumers read it as soon as
	# compute-ephem-cache.sh renames it into place. When a deployment mounts a
	# shared filesystem here it is scoped to the output directory alone, so
	# nothing this container does can reach the rest of that filesystem.
	local outdir="${EPHEMCACHE_OUTPUT_DIR:-/app/outputs}"
	if mkdir -p "$outdir/caches" "$outdir/catalogs" 2>/dev/null && [[ -w "$outdir" ]]; then
		ok "$outdir writable ($(df -h "$outdir" 2>/dev/null | awk 'NR==2{print $4" free"}'))"
		printf '  info  %s\n' "fstype $(stat -fc %T "$outdir" 2>/dev/null), $(ls -ldn "$outdir" | awk '{print $1, "uid="$3, "gid="$4}')"

		# Is it actually a separate mount, or just the container's own layer?
		# Same device as /app means nothing was mounted and any output would be
		# discarded when the pod exits — which for `run` is silent data loss.
		if [[ "$(stat -c %d /app 2>/dev/null)" == "$(stat -c %d "$outdir" 2>/dev/null)" ]]; then
			note "$outdir is on the SAME filesystem as /app — nothing is mounted"
			note "      there, so anything written would be lost with the pod."
		else
			ok "$outdir is a separate mount (output survives the pod)"
		fi

		local probe="$outdir/.selftest-$(hostname)-${RANDOM}"
		if touch "$probe" 2>/dev/null; then
			printf '  info  %s\n' "new files land as $(ls -ln "$probe" | awk '{print "uid="$3" gid="$4}')"
			rm -f "$probe" && ok "create and delete in $outdir both work"
		else
			bad "$outdir not writable as uid $(id -u) gid $(id -g)"
		fi
	else
		bad "$outdir does not exist or is not writable — nothing can run"
	fi

	echo
	echo "-- parallelism --"
	# nproc reports the NODE's cpu count, not the cgroup cpu limit, so the
	# scripts' NCORES default will oversubscribe a limited pod. Stage 3 uses
	# ~4 GB per chunk, so an unset NCORES on a big node can OOM the pod.
	local np; np=$(nproc)
	if [[ -n "${NCORES:-}" ]]; then
		ok "NCORES=$NCORES explicitly set (nproc reports $np)"
	else
		note "NCORES unset — scripts will use nproc=$np. In a CPU-limited pod"
		note "      this oversubscribes (~4 GB/chunk at stage 3). Set NCORES."
	fi

	if [[ $with_db -eq 1 ]]; then
		echo
		echo "-- database (opt-in) --"
		if [[ -z "${MPCDB:-}" ]]; then
			bad "MPCDB unset, cannot test"
		else
			# The DSN is passed via the environment, not argv, and only the
			# exception CLASS is reported. libpq error text routinely echoes
			# the full connection info, so printing str(exception) here would
			# put credentials in the pod log.
			# MPCDB is sourced from ephemcache.config as a shell variable and is
			# not exported, so it must be placed in the environment explicitly
			# for this one command. Passing it as an argument instead would put
			# the DSN in argv, which is what this whole arrangement avoids.
			MPCDB="$MPCDB" python <<'PY' && ok "connected and queried mpc_orbits" || bad "database check failed"
import os, sys
from sqlalchemy import create_engine, text
try:
	e = create_engine(os.environ["MPCDB"])
	with e.connect() as c:
		c.execute(text("SELECT 1 FROM mpc_orbits LIMIT 1"))
except Exception as ex:
	# Class name only. Deliberately not str(ex) — see above.
	print(f"        failed with {type(ex).__module__}.{type(ex).__name__}")
	print("        (message suppressed: libpq includes connection info in it)")
	sys.exit(1)
PY
		fi
	fi

	echo
	echo "=== selftest: $pass passed, $fail failed, $warn warnings ==="
	[[ $fail -eq 0 ]]
}

# ------------------------------------------------------------------ dispatch ---

case "${1:-run}" in
	selftest)
		shift
		selftest "$@"
		;;
	run)
		# The kernels live on the output volume, not in the image, so make sure
		# they are there before handing off. Activating the environment here is
		# also free for the scripts, which skip their own activation when
		# CONDA_DEFAULT_ENV already matches.
		activate_env || { echo "could not activate the conda environment" >&2; exit 1; }
		ensure_kernels || { echo "sorcha_cache unavailable; refusing to start" >&2; exit 1; }
		log_kernel_inventory
		exec ./bin/cron-compute-ephem-cache.sh
		;;
	*)
		exec "$@"
		;;
esac
