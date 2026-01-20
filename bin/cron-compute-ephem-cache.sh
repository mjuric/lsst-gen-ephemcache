#!/bin/bash
#
# Run this script from crontab to trigger the rebuild of ephemerides cache
#

set -e

# FIXME: right now we flip to the next version of MPCORB at UTC midnight. 
# By ops time we'll need to flip when some number of new/updated
# discoveries/observations becomes available in the MPC database.
TSTAMP=$(date -u +"%Y-%m-%d")

# Compute the MJD of the observing night at current date in Santiago.
mjd_12noon_santiago()
{
    tz=America/Santiago
    d=$(TZ=$tz date +%Y-%m-%d)
    # date: BSD || GNU compatibility
    e=$(TZ=$tz date -j -f "%Y-%m-%d %H:%M:%S" "$d 12:00:00" +%s 2>/dev/null || TZ=$tz date -d "$d 12:00:00" +%s)
    awk -v e="$e" 'BEGIN{print int(e/86400 + 40587)}'
}
MJD=$(mjd_12noon_santiago)

CACHEFN="outputs/caches/eph.$MJD.$TSTAMP.bin"
if [[ ! -f "$CACHEFN" ]]; then
	echo "Computing ephem cache $CACHEFN"
	time ./bin/compute-ephem-cache.sh "$MJD" "$TSTAMP" 100
else
	echo "$CACHEFN: cache for $MJD (with $TSTAMP MPCORB) found; skipping."
fi
