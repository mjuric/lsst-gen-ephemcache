#!/bin/bash
#
# Run this script from crontab to trigger the rebuild of ephemerides cache
#

set -e

# FIXME: right now we flip to the next version of MPCORB at UTC midnight. 
# By ops time we'll need to flip when some number of new/updated
# discoveries/observations becomes available in the MPC database.
TSTAMP=$(date -u +"%Y-%m-%d")

# Compute the MJD of the current (local time) night.
# FIXME: this should also be made nicer (at least made sure to follow Chilean local time)
MJD=$(echo "$(date --date="$(date +%D)" +%s) / 86400.0 + 2440587.5 - 2400000.5" | bc -l | cut -f 1 -d .)

CACHEFN="outputs/caches/eph.$MJD.$TSTAMP.bin"
if [[ ! -f "$CACHEFN" ]]; then
	echo "Computing ephem cache $CACHEFN"
	time ./bin/compute-ephem-cache.sh "$MJD" "$TSTAMP" 100
else
	echo "$CACHEFN: cache for $MJD (with $TSTAMP MPCORB) found; skipping."
fi
