#!/usr/bin/env python

from sqlalchemy import create_engine, text, event
import sqlite3
import pandas as pd
import datetime
import shutil
import os, sys
import argparse
import psycopg2.extras
import zstandard as zstd
from tqdm import tqdm

def zstd_compress_file(filename: str) -> str:
    """
    Zstd-compress a file using compression level 12 and multithreading.

    Output file is f"{filename}.zst".
    Returns the output filename.
    """
    out = f"{filename}.zst"
    size = os.path.getsize(filename)

    cctx = zstd.ZstdCompressor(level=12, threads=-1)

    with open(filename, "rb") as fin, open(out, "wb") as fout:
        with cctx.stream_writer(fout) as zw:
            with tqdm(total=size, unit="B", unit_scale=True, desc=os.path.basename(out)) as pbar:
                while True:
                    chunk = fin.read(1 << 20)
                    if not chunk:
                        break
                    zw.write(chunk)
                    pbar.update(len(chunk))

    return out

if __name__ == "__main__":

    parser = argparse.ArgumentParser(description="Extract MPCORB from database")
    parser.add_argument("tstamp", type=str, help="Timestamp string")
    parser.add_argument("--db", type=str, help="Database connection string", default="postgresql+psycopg2://sssc@epyc.astro.washington.edu/mpc_sbn")
    args = parser.parse_args()

    # construct output filenames, quit if they already exist
    tstamp = args.tstamp
    fn_pq = f'outputs/catalogs/mpc_orbits.{tstamp}.parquet'
    fn_db = f'outputs/catalogs/mpc_orbits.{tstamp}.sqlite'
    fn_orb = f'outputs/catalogs/mpcorb-orbits.{tstamp}.csv'
    fn_clr = f'outputs/catalogs/mpcorb-colors.{tstamp}.csv'
    if os.path.exists(fn_orb) and os.path.exists(fn_clr):
        print(f"MPCORB files exist for {tstamp}. exiting.")
        sys.exit()

    # Create SQLAlchemy engine for PostgreSQL connection
    engine = create_engine(args.db)

    @event.listens_for(engine, "connect")
    def _keep_jsonb_serialized(dbapi_conn, connection_record):
        # Return JSON/JSONB as raw text (str) instead of dict/list
        psycopg2.extras.register_default_json(dbapi_conn, loads=lambda s: s)
        psycopg2.extras.register_default_jsonb(dbapi_conn, loads=lambda s: s)
        # Set encoding to UTF-8
        dbapi_conn.set_client_encoding("UTF8")

    # The SQL query to extract the full mpc_orbits table
    query = text("""
    SELECT unpacked_primary_provisional_designation as designation, *
    FROM mpc_orbits
    WHERE NOT mpc_orb_jsonb->'orbit_fit_statistics'->>'arc_length_total' IN ('0 days', '1 days', '2 days')
    """)

    # Execute query and load results into pandas DataFrame
    print("Querying remote db for the catalog...")
    with engine.connect() as connection:
        df = pd.read_sql(query, connection)
    df.sort_values(["designation"], inplace=True)
    ## df.to_parquet(fn_pq, compression='brotli', index=False)

    # store mpc_orbits into a sqlite3 file, indexed on designation
    try:
        os.remove(fn_db)
    except FileNotFoundError:
        pass
    con = sqlite3.connect(fn_db)
    cur = con.cursor()
    cur.executescript("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        PRAGMA temp_store=MEMORY;
        PRAGMA cache_size=-262144;
        PRAGMA mmap_size=0;
        PRAGMA locking_mode=EXCLUSIVE;
        PRAGMA foreign_keys=OFF;
    """)

    print("Writing to sqlite file...")
    df.to_sql("mpc_orbits", con, if_exists="replace", index=False, chunksize=1_000, method="multi")
    print("Creating index on designation...")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_mpcorb_designation ON mpc_orbits(designation)")

    print("Running ANALYZE...")
    cur.executescript("ANALYZE;")
    con.commit()
    con.close()

    # compress
    print("Compressing...")
    zstd_compress_file(fn_db)
    os.remove(fn_db)
    print("Database created.")

    # store colors
    cdf = pd.DataFrame({"ObjID":  df['unpacked_primary_provisional_designation']})
    cdf['H_r'] = df["h"]
#    cdf[['u-r', 'g-r', 'i-r', 'z-r', 'y-r']] = 0.0
    cdf['GS'] = df["g"]
    cdf.to_csv(f"{fn_clr}.tmp", index=False)

    # store orbits for Sorcha
    odf = pd.DataFrame(dict(
        ObjID=df['unpacked_primary_provisional_designation'], q=df["q"], e=df["e"], inc=df["i"], node=df["node"], argPeri=df["argperi"], t_p_MJD_TDB=df["peri_time"],
        epochMJD_TDB=df["epoch_mjd"]
    ))
    odf['FORMAT'] = 'COM'
    odf.to_csv(f"{fn_orb}.tmp", index=False)

    # atomic move
    shutil.move(f"{fn_clr}.tmp", fn_clr)
    shutil.move(f"{fn_orb}.tmp", fn_orb)
