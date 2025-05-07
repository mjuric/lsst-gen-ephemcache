#!/bin/bash
#
# Install all that's needed to run the ephemerides cache generator
#

set -e

if [[ $# != 1 ]]; then
	echo "usage: $0 <condaenv-name-to-create>" 1>&2
	exit -1
fi
ENV="$1"

if [[ -f ephemcache.config ]]; then
	echo "ephemcache.config exists; this could overwrite an existing installation." 1>&2
	echo "cowardly refusing to proceed."
	exit -1
fi

#
# write configuration file
#
rm -f ephemcache.config
echo "ENV='$ENV'" >> ephemcache.config
echo "MPCDB='postgresql+psycopg2://sssc@epyc.astro.washington.edu/mpc_sbn'" >> ephemcache.config
echo "SRUN='srun --account=rubin:default@roma'" >> ephemcache.config
echo "SBATCH='sbatch --account=rubin:default@roma'" >> ephemcache.config
echo "KIND='parallel'" >> ephemcache.config

#
# set up micromamba
#
if ! command -v micromamba >/dev/null 2>&1; then
	echo "Need micromamba to work. Go install it firs." 1>&2
	echo "https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html" 1>&2
	exit -1
fi
eval "$(micromamba shell hook --shell bash)"

#
# make a new environment
#
micromamba create -n "$ENV" -c conda-forge sorcha fastapi pydantic pydantic-settings uvicorn starlette sqlalchemy psycopg2 --yes
micromamba activate "$ENV"
# bug workaround for "Cannot import name 'update_default_config' from 'astropy.config.configuration'"
# which occures in older versions of sbpy
micromamba install -c conda-forge "sbpy>=0.5.0"

#
# install mpsky from github
#
git clone https://github.com/mjuric/mpsky.git
(cd mpsky && pip install -e .)

#
# bootstrap sorcha
#
sorcha bootstrap --cache sorcha_cache

cat << EOF 
Ephemerides cache generator installed.

IMPORTANT: Make sure you also set up the credentials in ~/.pgpass to access
the MPC database replica. For example:

  epyc.astro.washington.edu:5432:mpc_sbn:sssc:xxxxxxxxxxxxx

Otherwise these scripts will fail to work.
EOF
