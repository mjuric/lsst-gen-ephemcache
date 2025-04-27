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

## set up the conda environment
#if [[ "$CONDA_DEFAULT_ENV" != "mpsky" ]]; then
#        eval "$(micromamba shell hook --shell bash)"
#        micromamba activate mpsky
#fi

# quick sanity check, that we aren't missing tasks
NFILES=$(ls -l outputs/_workdir/orbits-000*.csv | wc -l)
if [[ "$NFILES" != "$SLURM_ARRAY_TASK_COUNT" ]]; then
	echo "sanity check failed: there are $NFILES input files, but $SLURM_ARRAY_TASK_COUNT scheduled jobs." 1>&2
	exit -1
fi

# because we write chunks/files zero-padded
PADDED_ID=$(printf "%05d" $SLURM_ARRAY_TASK_ID)

# run sorcha
sorcha run \
	-c outputs/_workdir/eph.ini \
	-pd outputs/_workdir/eph.db \
	-o outputs/_workdir \
	-t out."$PADDED_ID" \
	-ob outputs/_workdir/orbits-"$PADDED_ID".csv \
	-p outputs/_workdir/physical-"$PADDED_ID".csv \
	-st out.dets."$PADDED_ID" \
	-ew out.eph."$PADDED_ID" \
	-ar sorcha_cache/ \
	-f

# convert to HDF5
CONVERT="import pandas as pd; pd.read_csv(f'outputs/_workdir/out.eph.$PADDED_ID.csv').to_hdf(f'outputs/_workdir/out.eph.$PADDED_ID.h5', key='data')"
python -c "$CONVERT"
