"""All database connection logic for Data on Tap.

The Lakebase database is a **project** (the autoscaling `w.postgres` model), not a
legacy database instance. get_connection() resolves the project's read-write
endpoint, mints a short-lived OAuth token via the SDK (never a static password),
and returns a live psycopg2 connection. Nothing else in the codebase calls
psycopg2.connect() — this single point of isolation is what lets the app run both
as a deployed Databricks App and locally / in a notebook.
"""

import os
import contextlib

import psycopg2

# Lakebase project. project_id "data-on-tap" -> resource name "projects/data-on-tap".
PROJECT_ID = os.environ.get("LAKEBASE_INSTANCE_NAME", "data-on-tap")
PROJECT_NAME = os.environ.get("LAKEBASE_PROJECT", f"projects/{PROJECT_ID}")
DATABASE_NAME = os.environ.get("PGDATABASE", "databricks_postgres")


def _workspace():
    from databricks.sdk import WorkspaceClient

    return WorkspaceClient()


def _pick_endpoint(w):
    """Find the read-write Postgres endpoint for the project.

    Endpoints may hang off the project directly or off one of its branches.
    """
    try:
        candidates = list(w.postgres.list_endpoints(PROJECT_NAME))
    except Exception:
        candidates = []
    if not candidates:
        for branch in w.postgres.list_branches(PROJECT_NAME):
            candidates = list(w.postgres.list_endpoints(branch.name))
            if candidates:
                break
    if not candidates:
        raise RuntimeError(
            f"No Postgres endpoint found for {PROJECT_NAME}. "
            "Start or create an endpoint for the Lakebase project."
        )
    for e in candidates:
        kind = f"{getattr(e, 'endpoint_type', '')} {getattr(e, 'type', '')}".lower()
        if "read_write" in kind or "primary" in kind or "read-write" in kind:
            return e
    return candidates[0]


def _endpoint_host(ep):
    """Pull the connection hostname off an Endpoint object (field name varies)."""
    # Primary path: status.hosts.host (Lakebase Autoscaling endpoint).
    _hosts = getattr(getattr(getattr(ep, "status", None), "hosts", None), "host", None)
    if isinstance(_hosts, str) and "." in _hosts:
        return _hosts
    for attr in ("host", "read_write_dns", "dns", "hostname", "endpoint"):
        value = getattr(ep, attr, None)
        if isinstance(value, str) and "." in value:
            return value
    # Fallback: scan for any hostname-looking string attribute.
    for attr in dir(ep):
        if attr.startswith("_"):
            continue
        try:
            value = getattr(ep, attr)
        except Exception:
            continue
        if isinstance(value, str) and value.count(".") >= 2 and " " not in value and "/" not in value:
            return value
    raise RuntimeError(f"Could not determine a host from the endpoint: {ep!r}")


def _token(w, ep):
    cred = w.postgres.generate_database_credential(endpoint=ep.name)
    token = getattr(cred, "token", None)
    if not token:
        raise RuntimeError(f"No token returned on credential: {cred!r}")
    return token


def _connect_local():
    """Local / notebook: resolve host + token from the SDK and connect as the user."""
    w = _workspace()
    ep = _pick_endpoint(w)
    return psycopg2.connect(
        host=_endpoint_host(ep),
        dbname=DATABASE_NAME,
        user=w.current_user.me().user_name,
        password=_token(w, ep),
        sslmode="require",
    )


def _connect_app():
    """Databricks App: PG* connection details are injected as env vars.

    PGUSER is the app service principal's role. PGPASSWORD may be injected; if
    not, mint an OAuth token via the SDK. That role must be GRANTed privileges.
    """
    password = os.environ.get("PGPASSWORD")
    if not password:
        w = _workspace()
        password = _token(w, _pick_endpoint(w))
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", DATABASE_NAME),
        user=os.environ["PGUSER"],
        password=password,
        sslmode=os.environ.get("PGSSLMODE", "require"),
    )


def get_connection():
    """Return a live psycopg2 connection, detecting the runtime environment."""
    if os.environ.get("PGHOST"):
        return _connect_app()
    return _connect_local()


@contextlib.contextmanager
def connection():
    """Context manager that yields a connection and always closes it.

    Transaction control (commit / rollback) is left to the caller via
    `with conn:` so a failed order rolls back cleanly.
    """
    conn = get_connection()
    try:
        yield conn
    finally:
        conn.close()
