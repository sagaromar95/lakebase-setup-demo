#!/usr/bin/env bash
# Companion to "Lakebase from the Terminal". One Bash file with a verb per
# step: login, projects, create-project, status, connect, seed, verify,
# create-branch / delete-branch (a timed branch you keep), and branch-demo
# (the create -> mutate -> verify -> clean-up isolation check in one shot).
# Run `bash lakebase-demo.sh help` for the full list.
# Requires Bash 3.2+, jq, psql, and a current Databricks CLI supporting
# postgres create-branch --ttl. Place beside schema.sql and seed.sql in the
# companion repository.
set +x                           # Never trace OAuth credentials, even with bash -x.
set -euo pipefail

# ================= EDIT YOUR SETTINGS HERE =================
# Enter your workspace URL and chosen project ID between the quotes.
# Example URL: https://your-workspace.cloud.databricks.com
# Example ID: pizza-demo (independent of your local folder name).
# For an existing project, use its actual resource ID, not its display name.
CONFIG_WORKSPACE_URL=""
CONFIG_PROJECT_ID=""

# Optional settings: these defaults work for the companion walkthrough.
CONFIG_PROFILE="lakebase-demo"
CONFIG_BRANCH_ID=""                 # Empty = discover the default branch.
CONFIG_DATABASE="databricks_postgres"
CONFIG_SQL_DIR=""                   # Empty = folder containing this script.
# Do not put passwords or access tokens in this file.
# ================= END OF USER SETTINGS ====================

# Advanced overrides: command-line options > environment > settings above.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROFILE=${LAKEBASE_PROFILE:-$CONFIG_PROFILE}
PROJECT_ID=${LAKEBASE_PROJECT_ID:-$CONFIG_PROJECT_ID}
BRANCH_ID=${LAKEBASE_BRANCH_ID:-$CONFIG_BRANCH_ID}
DATABASE=${LAKEBASE_DATABASE:-$CONFIG_DATABASE}
SQL_DIR=${LAKEBASE_SQL_DIR:-${CONFIG_SQL_DIR:-$SCRIPT_DIR}}
WORKSPACE_URL=${LAKEBASE_WORKSPACE_URL:-$CONFIG_WORKSPACE_URL}
CREATED_BRANCH=''

usage() {
  cat <<'HELP'
Usage: bash lakebase-demo.sh ACTION [OPTIONS]

Actions:
  login           Browser OAuth login to the named workspace profile
  projects        List projects (use an existing demo project on Free Edition)
  create-project  Create a project; asks for confirmation, never replaces one
  status          Show selected branch, endpoint, database, and CLI version
  connect         Open an interactive psql session; type \q to leave
  seed            RESET the nine demo tables, then load schema.sql + seed.sql
  verify          Display table names and row counts
  branch-demo     Create an expiring branch, delete its inventory, verify source
                  is unchanged, and delete ONLY the branch created by this run
  create-branch NAME  Create a branch NAME from the source (1h expiry); times it
  delete-branch NAME  Delete the branch NAME
  help            Show this help

Options (or corresponding environment variables):
  --profile NAME    LAKEBASE_PROFILE        default: lakebase-demo
  --project ID      LAKEBASE_PROJECT_ID     required except login/projects/help
  --branch ID       LAKEBASE_BRANCH_ID      default: discover default branch
  --database NAME   LAKEBASE_DATABASE       default: databricks_postgres
  --sql-dir DIR     LAKEBASE_SQL_DIR        default: this script's directory
  --host URL        LAKEBASE_WORKSPACE_URL  required for login

First edit CONFIG_WORKSPACE_URL and CONFIG_PROJECT_ID at the top of this file.
Project ID is independent of the local folder name.

Examples:
  bash lakebase-demo.sh login
  bash lakebase-demo.sh projects
  bash lakebase-demo.sh create-project
  bash lakebase-demo.sh status
  bash lakebase-demo.sh connect
  bash lakebase-demo.sh seed
  bash lakebase-demo.sh verify
  bash lakebase-demo.sh branch-demo
  bash lakebase-demo.sh create-branch inventory-test
  bash lakebase-demo.sh connect --branch inventory-test
  bash lakebase-demo.sh delete-branch inventory-test

Seed requires you to type the exact target to confirm data deletion.
Tokens are generated at connection time, never stored in this file or printed.
HELP
}
log() { printf '%s\n' "$*" >&2; }
die() { log "Error: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1. See README-cli.md."; }
valid_id() {
  [[ "$1" =~ ^[a-z][a-z0-9-]*$ && ${#1} -le 63 ]] ||
    die "Invalid resource ID '$1': use 1–63 lowercase letters/digits/hyphens, starting with a letter."
}
confirm() {
  local expected=$1 answer
  printf 'Type exactly "%s" to continue: ' "$expected" >&2
  IFS= read -r answer || die 'No confirmation received; nothing changed.'
  [[ "$answer" == "$expected" ]] || die 'Confirmation did not match; nothing changed.'
}
dbx() { databricks --profile "$PROFILE" "$@"; }
# Fail on paginated responses rather than selecting from an incomplete collection.
collection() {
  jq -e --arg key "$1" '
    if type == "array" then .
    elif type == "object" then
      if (.next_page_token // "") != "" then error("Paginated output: narrow the selection or update CLI")
      else .[$key] end
    else error("Unexpected list response") end
    | if type == "array" then . else error("Expected a resource array") end'
}
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$CREATED_BRANCH" ]]; then
    log "Cleaning up this run's branch: $CREATED_BRANCH"
    if ! dbx postgres delete-branch "$CREATED_BRANCH" >/dev/null; then
      log "Cleanup failed. Branch has a one-hour expiry; check it in Lakebase: $CREATED_BRANCH"
      [[ $result -ne 0 ]] || result=1
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_source() {
  local branches
  dbx postgres get-project "$PROJECT" --output json >/dev/null
  if [[ -n "$BRANCH_ID" ]]; then
    SOURCE_BRANCH="$PROJECT/branches/$BRANCH_ID"
    dbx postgres get-branch "$SOURCE_BRANCH" --output json >/dev/null
  else
    branches=$(dbx postgres list-branches "$PROJECT" --output json | collection branches)
    SOURCE_BRANCH=$(printf '%s' "$branches" | jq -er '
      map(select(.status.default == true))
      | if length == 1 then .[0].name
        else error("Expected one default branch; supply --branch ID") end
      | strings | select(length > 0)')
  fi
  [[ "$SOURCE_BRANCH" == "$PROJECT/branches/"* ]] || die 'Branch belongs to another project.'
  valid_id "${SOURCE_BRANCH##*/}"
}
resolve_endpoint() {
  local branch=$1 resources endpoint details
  resources=$(dbx postgres list-endpoints "$branch" --output json | collection endpoints)
  endpoint=$(printf '%s' "$resources" | jq -er '
    map(select((.status.endpoint_type // .spec.endpoint_type) == "ENDPOINT_TYPE_READ_WRITE"))
    | if length == 1 then .[0].name
      else error("Expected exactly one read-write endpoint; inspect list-endpoints output") end
    | strings | select(length > 0)')
  [[ "$endpoint" == "$branch/endpoints/"* ]] || die 'Endpoint belongs to another branch.'
  valid_id "${endpoint##*/}"
  details=$(dbx postgres get-endpoint "$endpoint" --output json)
  [[ $(printf '%s' "$details" | jq -er '.name') == "$endpoint" ]] || die 'Endpoint response name mismatch.'
  DB_HOST=$(printf '%s' "$details" | jq -er '.status.hosts.host | strings | select(length > 0)')
  [[ "$DB_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die 'Invalid endpoint hostname.'
  DB_ENDPOINT=$endpoint
}
identify_user() {
  DB_USER=$(dbx current-user me --output json |
    jq -er '.userName | strings | select(length > 0)')
}
# Positional connection arguments avoid URI-encoding issues with email usernames.
# Clear libpq service/options overrides that could change the selected connection.
sql() {
  local endpoint=$1 host=$2 credential
  shift 2
  credential=$(dbx postgres generate-database-credential "$endpoint" --output json |
    jq -er '.token | strings | select(length > 0)')
  (
    unset PGSERVICE PGSERVICEFILE PGOPTIONS PGHOSTADDR
    PGPASSWORD="$credential" PGSSLMODE=require PGCONNECT_TIMEOUT=30 \
      psql -X -w -h "$host" -p 5432 -U "$DB_USER" -d "$DATABASE" \
        -v ON_ERROR_STOP=1 "$@"
  )
}
show_target() {
  log "Profile:  $PROFILE"
  log "Project:  $PROJECT"
  log "Branch:   $SOURCE_BRANCH"
  log "Endpoint: $SOURCE_ENDPOINT"
  log "Database: $DATABASE"
}
verify() {
  sql "$SOURCE_ENDPOINT" "$SOURCE_HOST" -c '\dt public.*' -c "
    SELECT 'branches' AS table_name, count(*) AS rows FROM public.branches
    UNION ALL SELECT 'menu', count(*) FROM public.menu
    UNION ALL SELECT 'inventory', count(*) FROM public.inventory
    UNION ALL SELECT 'customers', count(*) FROM public.customers
    UNION ALL SELECT 'delivery_partners', count(*) FROM public.delivery_partners
    UNION ALL SELECT 'customer_addresses', count(*) FROM public.customer_addresses
    UNION ALL SELECT 'staff', count(*) FROM public.staff
    UNION ALL SELECT 'orders', count(*) FROM public.orders
    UNION ALL SELECT 'order_items', count(*) FROM public.order_items
    ORDER BY table_name;"
}
seed() {
  [[ -f "$SQL_DIR/schema.sql" && -f "$SQL_DIR/seed.sql" ]] ||
    die "Place this script beside schema.sql and seed.sql, or pass --sql-dir."
  show_target
  log 'DESTRUCTIVE RESET: all nine demo tables are dropped and recreated.'
  log 'Existing orders, customer edits, and stock changes will be erased.'
  log "SQL files: $SQL_DIR/schema.sql and $SQL_DIR/seed.sql"
  confirm "RESET $SOURCE_BRANCH/$DATABASE"
  sql "$SOURCE_ENDPOINT" "$SOURCE_HOST" --single-transaction \
    -f "$SQL_DIR/schema.sql" -f "$SQL_DIR/seed.sql"
  log 'Schema and seed committed successfully.'
  verify
}
inventory_count() {
  local value
  value=$(sql "$1" "$2" -Atq -c 'SELECT count(*) FROM public.inventory;')
  [[ "$value" =~ ^[0-9]+$ ]] || die 'Expected a numeric inventory count.'
  printf '%s' "$value"
}
branch_demo() {
  local help_text before copied remaining after branch_id test_branch payload test_endpoint test_host
  help_text=$(dbx postgres create-branch --help)
  [[ "$help_text" == *'--ttl'* ]] || die 'Update Databricks CLI: create-branch --ttl is required.'
  show_target
  before=$(inventory_count "$SOURCE_ENDPOINT" "$SOURCE_HOST")
  [[ "$before" -gt 0 ]] || die 'Source inventory is empty. Seed the demo first.'
  branch_id="cli-demo-$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
  test_branch="$PROJECT/branches/$branch_id"
  payload=$(jq -n --arg source "$SOURCE_BRANCH" '{spec:{source_branch:$source}}')
  log "Creating isolated test branch with one-hour expiry: $test_branch"
  # Never replace or reuse an existing branch. Mark ownership only on success.
  if ! dbx postgres create-branch "$PROJECT" "$branch_id" --ttl 1h --json "$payload" >/dev/null; then
    die "Branch creation failed or its status is uncertain. Check $test_branch; if created, it expires after one hour. No SQL delete was attempted."
  fi
  CREATED_BRANCH=$test_branch
  resolve_endpoint "$test_branch"
  test_endpoint=$DB_ENDPOINT
  test_host=$DB_HOST
  [[ "$test_branch" != "$SOURCE_BRANCH" && "$test_endpoint" != "$SOURCE_ENDPOINT" && "$test_host" != "$SOURCE_HOST" ]] ||
    die 'Isolation check failed: source and test targets are not distinct.'
  copied=$(inventory_count "$test_endpoint" "$test_host")
  [[ "$copied" == "$before" ]] || die 'Branch count differs from initial source count; no delete attempted.'
  log "Test branch inventory before delete: $copied"
  sql "$test_endpoint" "$test_host" -c 'DELETE FROM public.inventory;'
  remaining=$(inventory_count "$test_endpoint" "$test_host")
  after=$(inventory_count "$SOURCE_ENDPOINT" "$SOURCE_HOST")
  [[ "$remaining" == 0 && "$after" == "$before" ]] ||
    die 'Count checks failed; concurrent source writes can change the source count.'
  log "PASS: test branch has $remaining inventory rows; source still has $after."
  log 'This demonstrates row-count isolation, not a full data-integrity comparison.'
  # EXIT trap deletes only the branch successfully created above.
}
create_branch() {
  local name=$1 payload start elapsed
  [[ -n "$name" ]] || die 'Usage: create-branch NAME'
  valid_id "$name"
  payload=$(jq -n --arg source "$SOURCE_BRANCH" '{spec:{source_branch:$source}}')
  log "Creating branch $PROJECT/branches/$name from $SOURCE_BRANCH (expires in 1h)..."
  start=$SECONDS
  dbx postgres create-branch "$PROJECT" "$name" --ttl 1h --json "$payload" >/dev/null ||
    die "Branch creation failed. Check $PROJECT/branches/$name."
  elapsed=$((SECONDS - start))
  log "Branch ready in ${elapsed}s (the branch plus its read-write endpoint)."
  log "Connect to it with: bash lakebase-demo.sh connect --branch $name"
}
delete_branch() {
  local name=$1
  [[ -n "$name" ]] || die 'Usage: delete-branch NAME'
  valid_id "$name"
  dbx postgres delete-branch "$PROJECT/branches/$name" >/dev/null ||
    die "Delete failed for $PROJECT/branches/$name."
  log "Deleted branch $PROJECT/branches/$name."
}

ACTION=${1:-help}
[[ $# -eq 0 ]] || shift
case "$ACTION" in
  help|-h|--help) usage; exit 0 ;;
  login|projects|create-project|status|connect|seed|verify|branch-demo|create-branch|delete-branch) ;;
  *) usage >&2; die "Unknown action: $ACTION" ;;
esac
BRANCH_ARG=""
if [[ "$ACTION" == create-branch || "$ACTION" == delete-branch ]]; then
  if [[ $# -gt 0 && "$1" != --* ]]; then BRANCH_ARG=$1; shift; fi
fi
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
  case "$1" in
    --profile) PROFILE=$2 ;; --project) PROJECT_ID=$2 ;;
    --branch) BRANCH_ID=$2 ;; --database) DATABASE=$2 ;;
    --sql-dir) SQL_DIR=$2 ;; --host) WORKSPACE_URL=$2 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift 2
done
need databricks
if [[ "$ACTION" == login ]]; then
  [[ "$WORKSPACE_URL" == https://* && "$WORKSPACE_URL" != *'<'* ]] || die 'Set CONFIG_WORKSPACE_URL at the top of this file or pass --host with your real HTTPS workspace URL.'
  dbx auth login --host "$WORKSPACE_URL"
  exit 0
fi
need jq
if [[ "$ACTION" == projects ]]; then dbx postgres list-projects --output json; exit 0; fi
[[ -n "$PROJECT_ID" ]] || die 'Set CONFIG_PROJECT_ID at the top of this file, set LAKEBASE_PROJECT_ID, or pass --project ID.'
valid_id "$PROJECT_ID"
[[ -z "$BRANCH_ID" ]] || valid_id "$BRANCH_ID"
PROJECT="projects/$PROJECT_ID"
if [[ "$ACTION" == create-project ]]; then
  log "Profile: $PROFILE; new project: $PROJECT"
  log 'Free Edition permits one project: use projects first if you completed the UI walkthrough.'
  confirm "CREATE $PROJECT"
  payload=$(jq -n --arg name "$PROJECT_ID" '{spec:{display_name:$name}}')
  dbx postgres create-project "$PROJECT_ID" --json "$payload"
  exit 0
fi
if [[ "$ACTION" == delete-branch ]]; then delete_branch "$BRANCH_ARG"; exit 0; fi
resolve_source
if [[ "$ACTION" == create-branch ]]; then create_branch "$BRANCH_ARG"; exit 0; fi
resolve_endpoint "$SOURCE_BRANCH"
SOURCE_ENDPOINT=$DB_ENDPOINT
SOURCE_HOST=$DB_HOST
if [[ "$ACTION" == status ]]; then databricks --version; show_target; exit 0; fi
need psql
identify_user
case "$ACTION" in
  connect) show_target; sql "$SOURCE_ENDPOINT" "$SOURCE_HOST" ;;
  seed) seed ;;
  verify) show_target; verify ;;
  branch-demo) branch_demo ;;
esac
