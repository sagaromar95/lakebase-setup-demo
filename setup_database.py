# Databricks notebook source
# /// script
# [tool.databricks.environment]
# environment_version = "5"
# ///
# MAGIC %md
# MAGIC # Data on Tap — Database Setup
# MAGIC
# MAGIC Parametrized notebook to create and seed the Lakebase (Postgres) schema by running
# MAGIC the `.sql` files that live in this Git repo. Fill in the widgets at the top, then
# MAGIC **Run All**.
# MAGIC
# MAGIC - Connects to the Lakebase instance with an OAuth token generated in code (no password).
# MAGIC - Reads `schema.sql` / `seed.sql` from the repo and executes them.
# MAGIC - Re-runnable: `schema.sql` drops and recreates the tables, `seed.sql` reloads fresh.

# COMMAND ----------

# MAGIC %pip install --upgrade 'databricks-sdk>=0.118.0'
# MAGIC dbutils.library.restartPython()

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Parameters
# MAGIC Set these via the widget bar at the top of the notebook (they appear after this cell runs).

# COMMAND ----------

dbutils.widgets.text("instance_name", "data-on-tap", "Lakebase instance name")
dbutils.widgets.text("database_name", "databricks_postgres", "Postgres database name")
dbutils.widgets.text("pg_user", "", "Postgres user (blank = current Databricks user)")
dbutils.widgets.text("sql_dir", "", "Folder holding the .sql files (blank = this notebook's folder)")
dbutils.widgets.text("app_client_id", "", "App service-principal client id to GRANT access (blank = skip)")
dbutils.widgets.dropdown("run_schema", "yes", ["yes", "no"], "Run schema.sql?")
dbutils.widgets.dropdown("run_seed", "yes", ["yes", "no"], "Run seed.sql?")
dbutils.widgets.dropdown("verify", "yes", ["yes", "no"], "Verify with SELECTs at the end?")

# COMMAND ----------

import os

INSTANCE_NAME = dbutils.widgets.get("instance_name").strip()
DATABASE_NAME = dbutils.widgets.get("database_name").strip()
PG_USER = dbutils.widgets.get("pg_user").strip()
SQL_DIR = dbutils.widgets.get("sql_dir").strip() or os.getcwd()
APP_CLIENT_ID = dbutils.widgets.get("app_client_id").strip()
RUN_SCHEMA = dbutils.widgets.get("run_schema") == "yes"
RUN_SEED = dbutils.widgets.get("run_seed") == "yes"
VERIFY = dbutils.widgets.get("verify") == "yes"

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
            f"Could not find {path}. Set the 'sql_dir' widget to the folder holding {filename}."
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
# MAGIC ## 5b. Grant the Databricks App access
# MAGIC
# MAGIC A deployed app connects as its **service principal**, whose Postgres role name is
# MAGIC the SP's **client id**. Tables created here are owned by *you*, so the app's role
# MAGIC needs privileges granted. Set the `app_client_id` widget to your app's service
# MAGIC principal client id (find it on the app's page in Databricks, or it is the
# MAGIC `PGUSER` value inside the app). Leave blank to skip.
# MAGIC
# MAGIC Run as the table owner (this notebook connects as you). Grants cover current
# MAGIC tables/sequences and set default privileges so future ones are covered too.

# COMMAND ----------

if APP_CLIENT_ID:
    # Role name is an identifier, not a literal — quote it and reject anything
    # that isn't a plain client id so it can't be used for SQL injection.
    import re

    if not re.fullmatch(r"[0-9a-fA-F-]+", APP_CLIENT_ID):
        raise ValueError(f"app_client_id looks unexpected: {APP_CLIENT_ID!r}")

    role = '"' + APP_CLIENT_ID + '"'
    grants = f"""
        GRANT USAGE ON SCHEMA public TO {role};
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {role};
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {role};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT USAGE, SELECT ON SEQUENCES TO {role};
    """
    with connection() as conn:
        with conn.cursor() as cur:
            cur.execute(grants)
        conn.commit()
    print(f"Granted table/sequence privileges to role {role}")
else:
    print("Skipped grants (app_client_id blank)")

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