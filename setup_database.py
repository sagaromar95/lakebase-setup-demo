# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "5"
# ///
# MAGIC %md
# MAGIC # Data on Tap — Database Setup
# MAGIC
# MAGIC A small notebook to create and seed the Lakebase (Postgres) schema by running the
# MAGIC `.sql` files in this repo. Edit the config cell at the top (just your Lakebase
# MAGIC project name), then **Run All**.
# MAGIC
# MAGIC - Connects to the Lakebase instance with an OAuth token generated in code (no password).
# MAGIC - Reads `schema.sql` / `seed.sql` from the repo and executes them.
# MAGIC - Re-runnable: `schema.sql` drops and recreates the tables, `seed.sql` reloads fresh.

# COMMAND ----------

# MAGIC %pip install --upgrade 'databricks-sdk>=0.118.0'
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Config
# MAGIC Edit these, then **Run All**. In most cases only `INSTANCE_NAME` needs changing.

# COMMAND ----------

import os

# ── Config: edit INSTANCE_NAME, then Run All ──────────────────────────────
INSTANCE_NAME = "your-lakebase-project"   # <-- your Lakebase project name (see README)
DATABASE_NAME = "databricks_postgres"     # the default database every project ships with
RUN_SCHEMA    = True                      # run schema.sql (drops + recreates the tables)
RUN_SEED      = True                      # run seed.sql  (loads demo data)
VERIFY        = True                      # print the table list + row counts at the end
# ──────────────────────────────────────────────────────────────────────────

SQL_DIR = os.getcwd()  # the repo folder holding schema.sql / seed.sql / backend/

print(f"instance : {INSTANCE_NAME}")
print(f"database : {DATABASE_NAME}")
print(f"sql dir  : {SQL_DIR}")
print(f"schema   : {RUN_SCHEMA} | seed: {RUN_SEED} | verify: {VERIFY}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Connect
# MAGIC Generates a short-lived OAuth token via the Databricks SDK and hands it to `psycopg2`
# MAGIC as the password. The host also comes from the SDK — never hardcoded.
# MAGIC
# MAGIC `psycopg2` already ships on the Databricks runtime — do **not** pip install extra copies.

# COMMAND ----------

import sys

# COMMAND ----------

# Point db.py at this project/database, then reuse the app's own connection logic
# (backend/db.py) so the notebook and the app connect exactly the same way.
os.environ["LAKEBASE_INSTANCE_NAME"] = INSTANCE_NAME
os.environ["PGDATABASE"] = DATABASE_NAME

REPO_ROOT = SQL_DIR if os.path.isdir(os.path.join(SQL_DIR, "backend")) else os.getcwd()
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from backend import db  # noqa: E402
import importlib
importlib.reload(db)

conn = db.get_connection()
print(f"Connected to Lakebase project '{INSTANCE_NAME}' (database {DATABASE_NAME}).")
print("(First connect can take a few seconds if the endpoint scaled to zero.)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Helper — run a .sql file
# MAGIC `psycopg2` executes all `;`-separated statements in the file in a single call.

# COMMAND ----------

def run_sql_file(filename):
    path = os.path.join(SQL_DIR, filename)
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"Could not find {path}. Run this notebook from the repo folder that holds {filename}."
        )
    with open(path) as f:
        sql = f.read()
    with conn.cursor() as cur:
        cur.execute(sql)
    conn.commit()
    print(f"Ran {filename} ({len(sql)} chars)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Create schema

# COMMAND ----------

if RUN_SCHEMA:
    run_sql_file("schema.sql")
else:
    print("Skipped schema.sql (run_schema = no)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. Seed data

# COMMAND ----------

if RUN_SEED:
    run_sql_file("seed.sql")
else:
    print("Skipped seed.sql (run_seed = no)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Verify
# MAGIC Confirms the tables exist and the seed landed.

# COMMAND ----------

if VERIFY:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'public' ORDER BY table_name;"
        )
        tables = [r[0] for r in cur.fetchall()]
        print("Tables:", tables)

        for t in ("branches", "menu", "inventory", "customers", "delivery_partners"):
            cur.execute(f"SELECT count(*) FROM {t};")
            print(f"  {t:20s} {cur.fetchone()[0]:>4} rows")

        print("\nMenu:")
        cur.execute("SELECT pizza_name, price, diet_type FROM menu ORDER BY id;")
        for name, price, diet in cur.fetchall():
            print(f"  {name:16s} {price:>6}  {diet}")
else:
    print("Skipped verification (verify = no)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. Close

# COMMAND ----------

conn.close()
print("Connection closed. Database setup complete.")