#!/bin/bash
#SBATCH --job-name=sorcha
#SBATCH --array=0-99
#SBATCH --account=rubin:default@roma
#SBATCH --partition=roma
#SBATCH --mail-type=FAIL                     # Mail events (NONE, BEGIN, END, FAIL, ALL)
#SBATCH --mail-user=mjuric@uw.edu            # Where to send mail
#SBATCH --mem=4gb                            # Job Memory
#SBATCH --output=outputs/_workdir/out.slurm.%a.log   # Standard output and error log

set -e

# load configuration file. The complexity here is because SLURM
# copies our script to a temporary directory (and then we should
# use the $SLURM_SUBMIT_DIR variable to find it again).
if [[ -z "$SLURM_SUBMIT_DIR" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
	SCRIPT_DIR="$SLURM_SUBMIT_DIR/bin"
fi
. "$SCRIPT_DIR/../ephemcache.config"

## set up the conda environment
if [[ "$CONDA_DEFAULT_ENV" != "$ENV" ]]; then
	eval "$($MAMBA shell hook --shell bash)"
	$MAMBA activate "$ENV"
fi

# quick sanity check, that we aren't missing tasks
NFILES=$(ls -1 outputs/_workdir/orbits-*.csv | wc -l)
if [[ $NFILES -ne $SLURM_ARRAY_TASK_COUNT ]]; then
	echo "sanity check failed: there are $NFILES input files, but $SLURM_ARRAY_TASK_COUNT scheduled jobs." 1>&2
	exit -1
fi

# because we write chunks/files zero-padded
PADDED_ID=$(printf "%05d" $SLURM_ARRAY_TASK_ID)

# run sorcha
sorcha run \
	-c outputs/_workdir/eph.ini \
	--pd outputs/_workdir/eph.db \
	-o outputs/_workdir \
	-t out."$PADDED_ID" \
	--ob outputs/_workdir/orbits-"$PADDED_ID".csv \
	-p outputs/_workdir/physical-"$PADDED_ID".csv \
	--st out.dets."$PADDED_ID" \
	--ew out.eph."$PADDED_ID" \
	--ar sorcha_cache/ \
	-f

# verify that the eph and output files have the same number of rows
# (if they don't, it means some object was for some reason too faint)
[ $(wc -l <"outputs/_workdir/out.eph.$PADDED_ID.csv") -eq $(wc -l <"outputs/_workdir/out.$PADDED_ID.csv") ] || { echo "ERROR: Files out.eph.$PADDED_ID.csv and out.$PADDED_ID.csv are not the same length."; exit -1; }

# convert to HDF5
CONVERT=$(cat <<EOF
import pandas as pd

cols="ObjID fieldMJD_TAI Obs_Sun_x_km Obs_Sun_y_km Obs_Sun_z_km Obj_Sun_x_LTC_km Obj_Sun_y_LTC_km Obj_Sun_z_LTC_km RA_deg Dec_deg PSFMagTrue".split()

pd.read_csv(f'outputs/_workdir/out.$PADDED_ID.csv')[cols].to_hdf(f'outputs/_workdir/out.eph.$PADDED_ID.h5', key='data')
EOF
)

python -c "$CONVERT"
