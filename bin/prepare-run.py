#!/usr/bin/env python

import os
import shutil
import astropy.table as tb
from multiprocessing import Pool
import sqlite3
import pandas as pd
import numpy as np
from tqdm import tqdm, trange

if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument('mjd', type=int)
    parser.add_argument('input_orbits', type=str)
    parser.add_argument('input_physical', type=str)
    parser.add_argument('chunks', type=int)
    parser.add_argument('--outdir', type=str, required=True)
    args = parser.parse_args()

    nchunks = args.chunks
    os.mkdir(args.outdir)

    #
    # config setup
    #
    shutil.copyfile("configs/eph.ini", f"{args.outdir}/eph.ini")

    # build the input "simulation database" -- an opsim-compatible
    # sqlite database that covers 24 hours around the requested day (MJD)
    with sqlite3.connect(f"file:configs/eph.db?mode=ro") as con:
        pointings = pd.read_sql("select * from observations", con)
        # this generates a grid of times (approx) centered on Chilean midnight,
        # starting in the evening of t0
        new_times = np.linspace(0.1, 0.9, 20) + args.mjd + 4./24. + 0.5
        pointings['observationStartMJD'] = new_times
    with sqlite3.connect(f"{args.outdir}/eph.db") as con:
        pointings.to_sql('observations', con)


    #
    # input chunking
    #
    orbits = tb.Table.read(args.input_orbits)
    physical = tb.Table.read(args.input_physical)

    print("chunking input files...")
    norbits = 0
    for i in trange(args.chunks):
        sub_orb  =   orbits[i::nchunks]
        sub_phys = physical[i::nchunks]

        sub_orb.write(f"{args.outdir}/orbits-{i:05d}.csv", overwrite=True)
        sub_phys.write(f"{args.outdir}/physical-{i:05d}.csv", overwrite=True)

        norbits += len(sub_orb)

    assert norbits == len(orbits)
