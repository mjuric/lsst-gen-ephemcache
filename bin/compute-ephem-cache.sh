#!/bin/bash

# load configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../ephemcache.config"

NCORES=${NCORES:-$(nproc)}

if [[ $# != 3 ]]; then
	echo "usage: $0 <mjd> <mpcorb-tstamp> <nchunks>" >&2
	exit -1
fi

MJD="$1"
TSTAMP="$2"
NCHUNKS="$3"

CACHEFN="outputs/caches/eph.$MJD.$TSTAMP.bin"

set -e

if [[ ! -d sorcha_cache ]]; then
	echo "sorcha_cache/ subdirectory not found." >&2
	echo "run this from the directory with input and cache files" >&2
fi

if [[ "$CONDA_DEFAULT_ENV" != "$ENV" ]]; then
	eval "$(micromamba shell hook --shell bash)"
	micromamba activate "$ENV"
fi


xrun() {
	[[ $KIND == "SLURM"    ]] && { $SRUN "$@"; return; }
	[[ $KIND == "parallel" ]] && { "$@"; return; }
}

xrun2() {
	[[ $KIND == "SLURM"    ]] && { $SRUN --ntasks=1 --cpus-per-task=16 "$@"; return; }
	[[ $KIND == "parallel" ]] && { "$@"; return; }
}

xbatch() {
	NCHUNKS="$1"
	shift

	[[ $KIND == "SLURM"    ]] && { $SBATCH --array=0-$((NCHUNKS-1)) --wait "$@"; return; }
	[[ $KIND == "parallel" ]] && {
		export SLURM_ARRAY_TASK_COUNT=$NCHUNKS
		seq 0 $((NCHUNKS-1)) | parallel --bar --env '*' -j$NCORES 'env SLURM_ARRAY_TASK_ID={} '"$@";
		return;
	}
}

# 1. extract MPCORB from the database
# 2. chunk up MPCORB and prepare sorcha inputs
# 3. run sorcha
# 4. run mpsky build to generate the caches

rm -rf outputs/_workdir

xrun            ./bin/get-mpcorb.py --db "$MPCDB" "$TSTAMP"
xrun            ./bin/prepare-run.py --outdir outputs/_workdir "$MJD" outputs/catalogs/mpcorb-orbits.$TSTAMP.csv outputs/catalogs/mpcorb-colors.$TSTAMP.csv "$NCHUNKS"
xbatch $NCHUNKS ./bin/exec-sorcha.sh
xrun2           mpsky build outputs/_workdir/out.eph.*.h5 --output "$CACHEFN.tmp" -j $NCORES

mv "$CACHEFN.tmp" "$CACHEFN"
