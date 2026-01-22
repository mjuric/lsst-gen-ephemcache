#!/bin/bash
#
# Run this script from crontab to trigger the rebuild of ephemerides cache
#

set -e

# Compute the MJD of the observing night at current date in Santiago.
mjd_12noon_santiago()
{
    tz=America/Santiago
    d=$(TZ=$tz date +%Y-%m-%d)
    # date: BSD || GNU compatibility
    e=$(TZ=$tz date -j -f "%Y-%m-%d %H:%M:%S" "$d 12:00:00" +%s 2>/dev/null || TZ=$tz date -d "$d 12:00:00" +%s)
    awk -v e="$e" 'BEGIN{print int(e/86400 + 40587)}'
}

# Compute the timestamp given the MJD
mjd_to_ymd() {
    s=$(( ($1 - 40587) * 86400 ))
    # date: GNU || BSD compatibility
    date -u -d "@$s" +"%Y-%m-%d" 2>/dev/null || date -u -r "$s" +"%Y-%m-%d"
}

# FIXME: in ops, we'll want this to flip over after the MPC has processed
# our submissions from previous night, probably closer to 5pm than Chilean
# noon

MJD=$(mjd_12noon_santiago)
TSTAMP=$(mjd_to_ymd $MJD)

CACHEFN="outputs/caches/eph.$MJD.$TSTAMP.bin"
if [[ ! -f "$CACHEFN" ]]; then
	echo "Computing ephem cache $CACHEFN"
	time ./bin/compute-ephem-cache.sh "$MJD" "$TSTAMP" 100
else
	echo "$CACHEFN: cache for $MJD (with $TSTAMP MPCORB) found; skipping."
fi
