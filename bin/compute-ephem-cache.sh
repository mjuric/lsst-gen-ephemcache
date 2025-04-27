#!/bin/bash

# load configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../ephemcache.config"

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

rm -rf outputs/_workdir

# 1. extract MPCORB from the database
# 2. chunk up MPCORB and prepare sorcha inputs
# 3. run sorcha
# 4. run mpsky build to generate the caches
$SRUN                                   ./bin/get-mpcorb.py --db "$MPCDB" "$TSTAMP"
$SRUN                                   ./bin/prepare-run.py --outdir outputs/_workdir "$MJD" outputs/catalogs/mpcorb-orbits.$TSTAMP.csv outputs/catalogs/mpcorb-colors.$TSTAMP.csv "$NCHUNKS"
$SBATCH --array=0-$((NCHUNKS-1)) --wait ./bin/exec-sorcha.sh
$SRUN   --ntasks=1 --cpus-per-task=16   mpsky build outputs/_workdir/out.eph.*.h5 --output "$CACHEFN.tmp" -j 16

mv "$CACHEFN.tmp" "$CACHEFN"
