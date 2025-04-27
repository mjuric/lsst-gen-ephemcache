# Ephgemerides Cache Generator scripts for LSST Operations

## Overview

This repository holds the scripts to build input ephemerides caches which
the `mpsky` service uses to quickly find which solar system objects are in a
given field of view.  The `mpsky` service runs in k8s and is invoked by the
prompt processing pipelines.

These caches are typically built at least once a day, usually in the
evening, in preparation for the next night's run. They're intented to be
triggered from something like `cron`.

## Installation

Clone this github repository, then run:

```
./install.sh gen-ephemcache
```

Where `gen-ephemcache` is the name of a conda environment to create
which will hold all the necessary software (most notably `sorcha` and
`mpsky`). 

The install script will generate an `ephemcache.config` file that configures
the way in which to submit jobs to a SLURM batch system.  The SLURM configuration
should work out-of-the-box for USDF (if it doesn't let us know; it's a bug). 
Adjust it for other clusters.

This file also contains the connection string for the upstream MPC database;
make sure you have the credentials for it set in your `~/.pgpass`.

## Running

To run manually (e.g., for testing or to build a missing cache), run:

```
./bin/compute-ephem-cache.sh <mjd> <mpcorb-tstamp> <nchunks>
```

where `mjd` is the MJD of the night for which to build the cache (typically
the current night), the `mpcorb-tstamp` is a string with which we'll label
the file storing the queried MPCORB catalog used to build the cache
(typically, the current time in YYYY-MM-DD format), and `nchunks` is the
level of parallelization when computing the ephemerides (typically 100 for
USDF).  Example:

```
./bin/compute-ephem-cache.sh 60792 2025-04-27 100
```

### Outputs

The run creates two sets of files:

 * Files named `mpcorb-orbits.2025-04-27.csv` and
   `mpcorb-colors.2025-04-27.csv`. These are the catalogs queried from the
   MPC postgres database replica. They're useful for understanding which
   objects went into the caches (e.g., when debugging).
 * A file named `eph.60792.2025-04-27.bin` in the current directory.  This
   is what should be passed on as input to `mpsky serve`.

### Automated execution

This package is primarily indented to be driven from crontab.  At USDF, this
is set up by logging onto `sdfcron001` host, and setting up a crontab such
as this using `crontab -e`:

```
MAILTO=...your_email...
BASH_ENV=/...your_homedir.../.bash_profile
0 * * * * cd ...where_you_cloned_this_repo... && ./bin/cron-compute-ephem-cache.sh
```

This will set up a cron job to try to build the caches every hour, using the
current (UTC) time for both the MJD and MPCORB (note: how we do the labeling
will change in the future; see the FIXME notes in the
`cron-compute-ephem-cache.sh` file).  It's safe to run it as hourly frequency
as it checks if the cache already exists before attempting to rebuild it.

In the future, this entire repository may be baked into a docker container
and run as a k8s CronJob.

## Details

What this code does:

 * Queries the MPC postgres database MPCORB table for all asteroids with
   apropriately certain orbits (see `bin/get-mpcorb.py`)
 * Stores the output into the `outputs/catalogs/mpcorb-*.csv` files, in the format
   expected by `sorcha`
 * Chunks up the catalogs into pieces in temporary directory `_workdir`,
   so it can be processed by many Sorcha instances in parallel.
 * Prepares the input files for Sorcha which generate ephemerides on a
   ~hour spaced grid in the night of interest.
 * Runs `sorcha` to compute these ephemerides. As Sorcha outputs are CSV files,
   also runs a small afterburner to convert them to HDF5 files.
 * Runs `mpsky build` to take the ephemerides computed by Sorcha and
   calculate the Tchebyshev polynomials and healpix indices that allow for
   fast spatial search and accurate ephemerides computation within the
   night. These are stored in `outputs/caches/*.bin` files, and can be fed to
   `mpsky serve`
