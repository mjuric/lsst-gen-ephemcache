#!/bin/bash
#
# Run this script from crontab to trigger the rebuild of ephemerides cache
#

set -e

# Compute the MJD of the current observing night in Santiago. A new
# night is defined to start at 5pm (17hrs), with the night MJD
# being the MJD at that moment.
get_current_night_mjd()
{
    tz=America/Santiago
    hrs_night_begins=17
    # date: GNU || BSD compatibility
    d=$(TZ=$tz date -d "${hrs_night_begins} hours ago" +%Y-%m-%d 2>/dev/null || TZ=$tz date -v -${hrs_night_begins}H +%Y-%m-%d)
    e=$(TZ=$tz date -j -f "%Y-%m-%d %H:%M:%S" "$d 00:00:00" +%s 2>/dev/null || TZ=$tz date -d "$d 00:00:00" +%s)
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

MJD=$(get_current_night_mjd)
TSTAMP=$(mjd_to_ymd $MJD)

CACHEFN="outputs/caches/eph.$MJD.$TSTAMP.bin"
if [[ ! -f "$CACHEFN" ]]; then
	echo "Computing ephem cache $CACHEFN"
	time ./bin/compute-ephem-cache.sh "$MJD" "$TSTAMP" 100
else
	echo "$CACHEFN: cache for $MJD (with $TSTAMP MPCORB) found; skipping."
fi
