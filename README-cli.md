# Lakebase terminal demo

One Bash file, separate actions. Use VS Code to read the script and its integrated terminal to run it.

## Add it to the companion repository

Place `lakebase-demo.sh` and this README in the repository root, alongside `schema.sql` and `seed.sql`. Optionally add `tests/test_cli.py` for offline verification. The script does not download or execute remote SQL. It uses the local schema and seed files you can inspect in the editor.

Expected layout:

```text
lakebase-setup-demo/
  lakebase-demo.sh
  README-cli.md
  schema.sql
  seed.sql
  tests/test_cli.py       # optional offline tests
```

## Requirements

- Bash 3.2+ (including macOS's built-in Bash), Databricks CLI, jq, and psql.
- Checked against a recent Databricks CLI (run `databricks --version` to see yours). `branch-demo` checks that `create-branch --ttl` is available — it's a recent addition, so upgrade older CLIs if that check fails.
- A Databricks workspace with Lakebase Autoscaling available in its region, plus permission to manage the demo project and access its Postgres database.
- Interactive user OAuth authentication. This script is for a personal hands-on walkthrough, not unattended service-principal automation.

macOS client tools:

```bash
brew install libpq jq
export PATH="$(brew --prefix libpq)/bin:$PATH"
```

Install the [Databricks CLI](https://docs.databricks.com/aws/en/dev-tools/cli/install) separately, then check:

```bash
databricks --version
psql --version
jq --version
```

## Run from VS Code's terminal

Open the repository folder in VS Code. All commands below run in its terminal, not inside psql. Invoke the file with `bash`; executable permission is not required.

### 1. Edit your settings, then log in

Open `lakebase-demo.sh` in VS Code and fill in the two values under **EDIT YOUR SETTINGS HERE**:

```bash
CONFIG_WORKSPACE_URL="https://YOUR-WORKSPACE.cloud.databricks.com"
CONFIG_PROJECT_ID="pizza-demo"
```

Choose your own project ID; it has no relationship to the repository or folder name. Use 1–63 lowercase letters, digits, or hyphens, starting with a letter. If reusing a project, enter its existing resource ID. Save the file. These settings persist across terminal sessions; no exports are needed. Keep the optional defaults unless you need to change them. Keep passwords and tokens out of the file, and restore the two empty values before publishing a reusable copy.

```bash
bash lakebase-demo.sh login
bash lakebase-demo.sh projects
```

The named profile defaults to `lakebase-demo`. The ID is the final component of `projects/<project-id>`, not the project's display name. Free Edition has a one-project limit: reuse your dedicated demo project from the earlier post.

Only if you need to create a new project and have quota:

```bash
bash lakebase-demo.sh create-project
```

This asks you to type `CREATE projects/<project-id>`. It never deletes or replaces an existing project to make room.

### 2. Inspect and connect

```bash
bash lakebase-demo.sh status
bash lakebase-demo.sh connect
```

The script discovers the default branch and requires a single read-write endpoint. It prints the selected resource names. To select another source branch explicitly, pass `--branch actual-branch-id` or export `LAKEBASE_BRANCH_ID`.

In psql:

```sql
SELECT current_user, current_database();
```

Type `\q` to return to the terminal. Each action reads the saved settings at the top of the script, so they also work in a new terminal.

### 3. Load the demo

```bash
bash lakebase-demo.sh seed
bash lakebase-demo.sh verify
```

**`seed` is a destructive reset.** It drops and recreates the nine tables using the companion `schema.sql`, then loads `seed.sql`. Existing orders, customer edits, and stock changes are erased. It asks you to type the full target, for example:

```text
RESET projects/my-demo/branches/production/databricks_postgres
```

Copy the exact resource shown in your prompt; the default branch can have another ID. There is no `--yes` bypass. Both SQL files run within one transaction and stop on the first SQL error. This assumes the companion files: do not add transaction-control statements or commands incompatible with a transaction to those files.

Clean-seed counts: branches 6, menu 6, inventory 36, customers 5, delivery partners 4, customer addresses 2, staff 2, orders 0, order items 0. `seed_orders.sql` is deliberately not invoked: the connection and branching walkthrough does not require synthetic orders.

### 4. Demonstrate branch isolation

```bash
bash lakebase-demo.sh branch-demo
```

This action:

1. Counts source inventory and requires it to be nonempty.
2. Creates a uniquely named child branch with a one-hour expiry.
3. Checks that branch, endpoint, and hostname differ from the source.
4. Checks the copied inventory count, then deletes inventory on the new child only.
5. Confirms the child has zero rows and the source retains its original count.
6. Deletes only the branch successfully created by this run, including on most errors or interruptions.

Keep the source quiet while demonstrating: concurrent writes can change counts. This is a row-count demonstration, not a complete integrity audit. If creation returns an ambiguous failure, the script reports the exact candidate branch instead of deleting an unconfirmed resource. If cleanup fails or the process is forcibly killed, the one-hour expiry is the fallback; inspect the branch in Lakebase. Compute and storage usage can still incur charges on paid accounts.

### Or branch by hand

`branch-demo` runs the whole isolation check in one shot. To do it step by step — and keep the branch to work in — use the granular verbs. The project and source branch come from your `CONFIG_PROJECT_ID` and the discovered default branch, so you pass only the new branch's name:

```bash
bash lakebase-demo.sh create-branch inventory-test    # 1h expiry; times it, prints "ready in Ns"
bash lakebase-demo.sh connect --branch inventory-test # work in the copy
bash lakebase-demo.sh delete-branch inventory-test    # remove it when done
```

`create-branch` reports how long the branch plus its read-write endpoint took to come online; the data itself is an instant copy-on-write snapshot. It prints only the branch name and timing — never the branch JSON or any credential.

## Options

```bash
bash lakebase-demo.sh help
bash lakebase-demo.sh status --project my-demo --profile lakebase-demo
bash lakebase-demo.sh seed --sql-dir /path/to/companion-repo
```

Environment variables: `LAKEBASE_PROFILE`, `LAKEBASE_PROJECT_ID`, `LAKEBASE_BRANCH_ID`, `LAKEBASE_DATABASE`, `LAKEBASE_SQL_DIR`, and `LAKEBASE_WORKSPACE_URL`. Precedence is command-line options, then nonempty environment variables, then the saved `CONFIG_*` settings. If an old export overrides your saved settings, unset that environment variable. No separate configuration file is sourced and no tokens are saved to disk by this script.

OAuth credentials are minted before each psql invocation and passed via the process environment. Do not record debug output from authentication tooling or modify the script to print tokens. The script disables shell tracing.

## Validation and limits

Bash syntax and 14 offline tests were checked. Tests use fake CLI and database clients; they cover array/wrapped JSON responses, ambiguous endpoints, missing tokens, cancelled resets, SQL failures, branch isolation guards, and cleanup behavior. No live Lakebase project was created or changed during validation. Before publishing an end-to-end success claim, run against a disposable Lakebase project with your installed CLI and confirm the actual JSON field names and permissions.

```bash
bash -n lakebase-demo.sh
python3 tests/test_cli.py
```

The tests require Python 3 and jq, but not a live Databricks login or Postgres server. The script itself does not require Python.

If resource selection fails, inspect `list-branches` or `list-endpoints` with `--output json`. It deliberately refuses ambiguous selections or partial paginated responses. Fix the mismatch rather than choosing the first entry. A connection timeout can also mean a suspended endpoint is waking, networking is blocked, or the selected role lacks access; verify the endpoint and retry. The script does not retry destructive SQL automatically.

Reference: [Databricks Lakebase CLI guide](https://docs.databricks.com/aws/en/oltp/projects/cli).
