#!/usr/bin/env python

from sqlalchemy import create_engine, text
import pandas as pd
import datetime
import shutil
import os, sys
import argparse

if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="Extract MPCORB from database")
    parser.add_argument("tstamp", type=str, help="Timestamp string")
    parser.add_argument("--db", type=str, help="Database connection string", default="postgresql+psycopg2://sssc@epyc.astro.washington.edu/mpc_sbn")
    args = parser.parse_args()

    # construct output filenames, quit if they already exist
    tstamp = args.tstamp
    fn_orb = f'outputs/catalogs/mpcorb-orbits.{tstamp}.csv'
    fn_clr = f'outputs/catalogs/mpcorb-colors.{tstamp}.csv'
    if os.path.exists(fn_orb) and os.path.exists(fn_clr):
        print(f"MPCORB files exist for {tstamp}. exiting.")
        sys.exit()

    # Create SQLAlchemy engine for PostgreSQL connection
    engine = create_engine(args.db)

    # The SQL query to extract mpcorb
    query = text("""
    SELECT packed_primary_provisional_designation as "ObjID", q, e, i as inc, node, argperi as "argPeri", peri_time as "t_p_MJD_TDB",
           epoch_mjd as "epochMJD_TDB", mpc_orb_jsonb->'orbit_fit_statistics'->>'arc_length_total' AS arc_length
    FROM mpc_orbits
    WHERE NOT mpc_orb_jsonb->'orbit_fit_statistics'->>'arc_length_total' IN ('0 days', '1 days', '2 days')
    """)

    # Execute query and load results into pandas DataFrame
    with engine.connect() as connection:
        df = pd.read_sql(query, connection)

    # store orbits
    df['FORMAT'] = 'COM'
    del df["arc_length"]
    df.to_csv(f"{fn_orb}.tmp", index=False)

    # store colors
    cdf = pd.DataFrame({"ObjID":  df['ObjID']})
    cdf['H_r'] = 10
    cdf[['u-r', 'g-r', 'i-r', 'z-r', 'y-r']] = 0.0
    cdf['GS'] = 0.15
    cdf.to_csv(f"{fn_clr}.tmp", index=False)

    # atomic move
    shutil.move(f"{fn_orb}.tmp", fn_orb)
    shutil.move(f"{fn_clr}.tmp", fn_clr)
