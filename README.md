# sdbui — SwiftCrossUI database query browser

A native desktop SQL browser built with [SwiftCrossUI](https://swiftcrossui.dev)
(GTK 4 on Linux, AppKit on macOS) that talks to databases through
[ADBC](https://arrow.apache.org/adbc/) drivers — the same approach as
[databow](https://github.com/columnar-tech/databow).

## How connections work (borrowed from databow)

- **Drivers** are installed with [dbc](https://docs.columnar.tech/dbc/)
  (`dbc install postgresql`, `dbc install mysql`, `dbc install duckdb`, …).
  dbc writes a TOML manifest per driver to `~/.config/adbc/drivers/` that
  points at the driver's shared library.
- **Profiles** in `~/.config/adbc/profiles/<name>.toml` are shared with databow:

  ```toml
  profile_version = 1
  driver = "postgresql"

  [Options]
  uri = "postgresql://me:{{ env_var(PGPASSWORD) }}@localhost:5432/app"
  ```

- Or connect ad hoc with a URI; the driver is inferred from the scheme.

databow uses the Rust `adbc_driver_manager`. Swift has no ADBC bindings, so
this project includes a tiny equivalent:

| Layer | Path | Role |
|---|---|---|
| `CADBC` | `Sources/CADBC` | `dlopen`s the driver, calls `AdbcDriverInit` (ADBC 1.1, falling back to 1.0), wraps database/connection/statement calls and error ownership. Vendors `adbc.h`. |
| `ADBCKit` | `Sources/ADBCKit` | Manifest + profile discovery (`ADBC_DRIVER_PATH`, `ADBC_PROFILE_PATH`, XDG dirs, venv/conda), `{{ env_var() }}` substitution, Arrow C Data Interface decoding, `ADBCConnection` (execute / cancel / GetObjects / GetTableSchema / GetInfo). |
| `SDBUI` | `Sources/SDBUI` | The SwiftCrossUI app. |

## Features

The connected window is laid out like [Sequel Ace](https://sequel-ace.com):

- **Toolbar:** database (MySQL) or schema (PostgreSQL) selector and the
  Query / Structure / Table Info tabs
- **Connection tabs:** open several databases at once with **+ New connection**.
  Each tab keeps its SQL, results, table selection and connection independently.
  Switching reuses each tab's editor and grid. Queries continue in background
  tabs; closing a tab disconnects that session.
  History and snippets are shared across connections.
- **Favorites:** single-click to edit settings; double-click (or press Enter)
  to connect to the saved profile in the current connection tab.
- **Sidebar:** the selected database's tables (via `AdbcConnectionGetObjects`)
  with a filter
- **Structure:** columns (type, nullability, key, default, extra) and indexes
- **Table Info:** engine, row estimate, sizes, collation, … and the
  `CREATE TABLE` statement (MySQL)
- **Query:** SQL editor with results below. Clicking a table puts
  ``SELECT * FROM `db`.`table` LIMIT 1000`` in the editor and runs it, with a
  column / operator / value filter bar and Previous/Next paging; filtering,
  paging and header sorting rewrite and re-run that SQL (`WHERE`, `OFFSET`,
  `ORDER BY`). Ctrl+Enter runs the selection or the statement at the cursor,
  Run All runs every statement; Cancel (`AdbcConnectionCancel`), row limit,
  CSV export

Results are shown in a virtualized grid (GTK `GtkColumnView`): only the
visible cells are formatted and drawn, so large results scroll smoothly.
Hover over a clipped cell for a bounded preview; cells that fit have no tooltip.
Double-click any cell to open its complete value in a read-only window with Copy.
JSON opens formatted, with a Raw toggle that preserves the original text and
number precision. NULL is distinguished from an empty string.
Numbers are right-aligned and headers show each column's type. Click a header
to sort; select rows with Shift/Ctrl-click and press Ctrl+C, or right-click a
cell to copy it, the rows, CSV or SQL `INSERT` statements.

Structure and Table Info use `information_schema` / `pg_catalog` for MySQL,
MariaDB and PostgreSQL; other databases show the columns ADBC reports.

Also:

- Connection form with name, driver, host, port, user, password, database and
  SSL mode for PostgreSQL/MySQL; URI mode supports other drivers and advanced
  profiles. Test opens a separate connection and runs `SELECT 1`; Connect uses
  the current settings without requiring a save. Save writes TOML favorites
  with owner-only permissions (passwords remain plain text). Editing a favorite
  preserves its extra driver options and URI parameters; saving under a new
  name creates a copy.
- Persistent **History** and **Snippets** panels beside the SQL editor. Search
  history by SQL or connection name; load entries into the editor, delete them,
  or clear history. The last 1,000,000 attempted manual statements are kept (including
  failed statements); table browsing, metadata and health checks are excluded.
  Snippets support named save, rename/update from the editor, load and delete.
  Loading history or a snippet does not execute SQL.
  History is paged 100 queries at a time, with cancellable background search.
  Both are stored in `~/.local/share/sdbui/query-library.sqlite3` on Linux
  (`XDG_DATA_HOME` is respected), or `~/Library/Application Support/sdbui/` on
  macOS, with owner-only file permissions. SQL is stored in plain text and may
  include sensitive literals; history can be cleared independently of snippets.
  Existing JSON libraries migrate automatically once; the original JSON file is
  preserved as a backup and can be removed manually after verifying migration.
- Lost-connection detection on database/SSH errors and idle health checks
  (every five seconds, skipped while queries are running). Reconnect reuses the
  original settings, restarts SSH when needed, and preserves the SQL editor.
  It opens a new database session: transactions and session settings must be
  re-established, and SQL is never replayed automatically.
- Searchable favorites grouped by profile subfolder, plus URI connect;
  vendor name/version from `GetInfo`. Nested profiles such as
  `profiles/Work/Production.toml` appear in the `Work` group; search matches
  profile names, groups, drivers and password-masked connection summaries.
  Earlier profile search directories take priority for equal relative names.
- Arrow types: ints, floats, bool, utf8/large/view, binary, decimal128/256,
  date/time/timestamp (with time zones), duration, interval, list, struct, map,
  union, dictionary

## Build and run (Linux)

```sh
# 1. Swift toolchain (once)
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
. ~/.local/share/swiftly/env.sh

# 2. GTK 4 headers (once)
sudo apt install libgtk-4-dev libsqlite3-dev clang

# 3. Build, test, run
swift build
swift test
bash scripts/test-cadbc.sh   # statement / result-stream lifetime regression
bash scripts/test-result-values.sh  # native value UI regression (GTK display required)
swift run sdbui
```

SwiftCrossUI is hosted at
[pragnesh/swift-cross-ui](https://github.com/pragnesh/swift-cross-ui).
Builds use its `sdbui-data-grid` branch by default, including the virtualized
grid and GTK performance fixes.

To explicitly build against a local checkout while developing the fork, set
`SDBUI_SCUI_PATH=/path/to/swift-cross-ui` for `swift build`, `swift test`, or
`swift run sdbui`.

## Release packages (Linux)

```sh
scripts/package-linux.sh            # version from the latest vX.Y.Z tag (else 0.1.0)
scripts/package-linux.sh --version 1.2.0 --no-deb
```

This builds a release binary with the Swift runtime linked statically and
writes to `dist/`:

- `sdbui-<version>-linux-<arch>.tar.gz`: unpack and run `./install.sh`
  (installs to `~/.local`; `sudo ./install.sh --prefix /usr/local` for all
  users). Uninstall with `<prefix>/share/sdbui/uninstall.sh`.
- `sdbui_<version>_<arch>.deb`: `sudo apt install ./sdbui_*.deb`.
- `SHA256SUMS`.

On GitHub, `.github/workflows/release.yml` does the same on Ubuntu 24.04:
push a tag (`git tag v0.2.0 && git push origin v0.2.0`) to publish a
GitHub Release with the packages, or run the workflow manually to get them
as a build artifact. The Swift version comes from `.swift-version`.

Target machines need GTK 4 (`libgtk-4-1`), SQLite (`libsqlite3-0`) and ADBC drivers installed with
dbc. The first release build compiles all dependencies with optimisation
and takes around 10 minutes; later ones are incremental.

For SSH connections, open the **SSH Tunnel** tab, enable **Connect through SSH**,
and enter the SSH host (or config alias), port, username and optional identity
file. The database host and port on the Connection tab are resolved from the
SSH server. Test creates a temporary tunnel; Connect keeps its tunnel until
Disconnect or normal application exit. Failed connections also release tunnels.
The app chooses a loopback-only local port automatically and saves SSH settings
in `[SDBUI.SSH]`, separate from ADBC driver options.

OpenSSH must be installed. Authentication uses your SSH agent, default keys or
the selected identity file; unlock encrypted keys in your agent first. Connect
to the SSH host once in a terminal to verify its host key before using the app.
SSH password/passphrase dialogs are not supported. PostgreSQL and MySQL network
URIs are supported; PostgreSQL retains the original hostname for SSL verification.
MySQL sees the loopback endpoint, so SSL hostname verification may need a
certificate valid for that endpoint; the app does not weaken the selected SSL mode.
Other clients reading the shared TOML profiles must manage their own SSH tunnel.

To run isolated OpenSSH/PostgreSQL integration checks (Python `paramiko` and
PostgreSQL server tools required): `python3 scripts/test-ssh-integration.py`.
This uses temporary keys, known-host files and a temporary database.

## Limitations

- One statement per Run (drivers generally reject multi-statement strings).
- The Query tab keeps at most "Max rows" rows. The grid shows up to 1000
  characters per cell; copy and CSV export use full values.
- The sidebar lists at most 100 tables per database; use the filter to find others.
- Results are read-only (no cell editing).

## Performance notes

SwiftCrossUI re-lays-out a view and its children when observed state changes,
and size changes bubble up to the window. So the UI keeps the widget count
small (results are one text label per page, not one view per cell), keeps the
editor's text out of observation, and splits views so each reads only what it
shows.

To reproduce a session for profiling, launch with
`SDBUI_PROFILE=<profile> SDBUI_SQL="<query>" swift run sdbui`: it connects and
runs the query on startup.
