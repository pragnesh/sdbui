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

- **Toolbar:** the Query / Structure / Table Info tabs
- **Connection tabs:** open several databases at once with **+ New connection**.
  Each tab keeps its SQL, results, table selection and connection independently.
  Switching reuses each tab's editor and grid. Queries continue in background
  tabs; closing a tab disconnects that session.
  History and snippets are shared across connections.
- **Favorites:** single-click to edit settings; double-click (or press Enter)
  to connect to the saved profile in the current connection tab.
- **Sidebar:** a list of databases (MySQL) or schemas (PostgreSQL), and
  below it the selected database's tables (via `AdbcConnectionGetObjects`)
  with a virtualized, fuzzy-filtered list of all table names. For example,
  `usrord` matches `user_orders`; exact/prefix/substring matches rank first.
  Matching ignores case and accents, and multiple search terms must all match.
  Only visible rows are rendered, keeping large schemas responsive.
  The selected database is the session's default (`USE`, or
  `search_path` on PostgreSQL), so unqualified table names resolve in it;
  it starts at the connection's default and is kept across reconnects
- **Structure:** columns (type, nullability, key, default, extra) and indexes
- **Table Info:** engine, row estimate, sizes, collation, … and the
  `CREATE TABLE` statement (MySQL)
- **Query:** SQL editor with results below. Clicking a table only selects
  it; **Show rows** runs ``SELECT * FROM `db`.`table` LIMIT 1000`` and shows
  that SQL above the rows, never in the editor, with a column / operator /
  value filter bar and Previous/Next paging; filtering, paging and header
  sorting rewrite and re-run that SQL (`WHERE`, `OFFSET`, `ORDER BY`).
  Ctrl+Enter runs the selection or the statement at the cursor,
  Run All runs every statement; Cancel (`AdbcConnectionCancel`), row limit,
  CSV export. The editor's text is saved as a draft per connection (by
  favorite name) as you type and restored the next time you connect to it

The app restores open connection tabs, the selected tab, each editor's SQL and font size, database/table selection, active pane, window size, and each sidebar width on launch. Saved favorites reconnect using their current saved settings. Restoring never executes editor SQL or restores query results, transactions, or SSH processes; connections start fresh. Missing favorites or failed connections leave the restored SQL available for reconnecting. Unsaved/modified connection settings reopen as disconnected tabs, since session state does not store connection credentials. `SDBUI_PROFILE` or `SDBUI_SQL` launch overrides take precedence over tab restoration.

Session state is autosaved to `session.json` beside the query library, with owner-only permissions, and flushed when the window closes. It contains editor SQL in plain text and references favorites by name; it does not duplicate connection URIs, passwords, or SSH settings. Corrupt or newer session files are preserved and reported rather than overwritten. Remove the session file to start with a blank workspace if needed.

Closing a tab (× or Ctrl+W) asks for confirmation if a query is running or SQL has changed since opening/restoring, a successful run, or an explicit snippet save. Draft/session autosaving keeps those edits recoverable but does not suppress this confirmation. **Keep tab open** (or Esc) leaves the tab and its query intact; **Close tab** requests cancellation and removes the tab from the next restored session. Statements already completed are not rolled back. Closing the application window keeps its open tabs in the saved session.

Keyboard shortcuts on Linux/GTK:

| Shortcut | Action |
|---|---|
| Ctrl+T / Ctrl+W | Open / close the current connection tab |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous connection tab, wrapping around |
| Ctrl+1…8 / Ctrl+9 | Select a numbered tab / the last tab |
| Ctrl+P or Ctrl+F | Focus and select the table filter |
| Ctrl+L | Open the Query pane and focus the editor, preserving its selection |
| Esc | Cancel the active query or dismiss pending SQL confirmation |
| F5 | Refresh tables and the current table view; reload favorites when disconnected |
| Ctrl+PgUp / Ctrl+PgDn | Previous / next browsed page, within page bounds |
| Enter in a filter | Apply the table-name or row-value filter |
| Ctrl+= (or Ctrl++) / Ctrl+− | Increase / decrease editor and result-grid font size (9–28 px, per tab) |

Shortcuts target the active connection. Existing editor and grid shortcuts such as Ctrl+Enter, Ctrl+C, and Ctrl+Z continue to work. F5 leaves manual query SQL and results intact; it does not rerun editor SQL. Font sizes are retained per tab and restored on launch.

The query status line keeps the last manual run's row count, duration and
Max rows truncation warning, independently of table loading and exports.
Failures include **Copy error** for the complete message. When the driver
provides a statement position (supported by the PostgreSQL driver), the editor
moves to that position, including within selections and multi-statement scripts.
It leaves the cursor alone if you changed the SQL while the query was running.

Results are shown in a virtualized grid (GTK `GtkColumnView`): only the
visible cells are formatted and drawn, so large results scroll smoothly.
Hover over a clipped cell for a bounded preview; cells that fit have no tooltip.
Double-click any cell to open its complete value in a read-only window with Copy.
JSON opens formatted, with a Raw toggle that preserves the original text and
number precision. NULL is distinguished from an empty string.
Numbers are right-aligned and headers show each column's type. Click a header
to sort; select rows with Shift/Ctrl-click and press Ctrl+C, or right-click a
cell to copy it, the rows, CSV or SQL `INSERT` statements.

For **Show rows** results, right-click a cell and choose **Filter by this value** → **=**, **!=**, or **IS NULL**. This uses that cell's full value, even with several rows selected, and updates the column/operator/value filter bar. It replaces the current single-column filter, keeps sorting, and returns to the first page without changing editor SQL or the clipboard. On a NULL cell, `=` means `IS NULL` and `!=` means `IS NOT NULL`; an empty string and the text `NULL` remain ordinary values. The submenu is limited to browsed table rows, where the source table and column are known, and ignores stale actions after switching tables or replacing results.

The SQL editor highlights keywords, strings, quoted identifiers, numbers and
comments in light and dark themes. Highlighting preserves the SQL text,
selection and undo history; no additional editor package is required on Linux.

Use **Ctrl+Space** for table, column and keyword suggestions. Suggestions also
appear after typing a name prefix or a dot. Choose with **↑/↓**, accept with
**Tab** or **Enter**, and dismiss with **Esc**. Table and column identifiers are
quoted for the current database. Column suggestions recognize ordinary
`FROM`/`JOIN` aliases, including aliases written after the cursor, and fetch
metadata for referenced tables in the background. Completion is a lightweight
SQL aid; it does not infer columns of CTEs or derived subqueries.

**+ Query** opens another SQL draft inside the current connection. Each query tab
keeps its own editor text, cursor, results, filters, status and statement log.
An asterisk marks unsaved SQL, and closing an edited query requires confirmation.
All query drafts and the selected query tab are restored on launch; results are
kept only in memory and restored SQL is never automatically executed. Query tabs
share one connection, so switching or closing them is disabled during execution.
Use another connection tab for concurrent work.

**Explain** requests the execution plan for the statement at the cursor or a
single selected read-only statement, without replacing editor SQL. It supports
PostgreSQL and MySQL and never adds `ANALYZE`; explaining SQL does not mark the
draft as successfully executed. PostgreSQL plan queries use the driver's
non-COPY result path. Manually running an `EXPLAIN` statement also uses that path.

Right-click a **column header** to sort ascending or descending, copy its name
or all loaded values, hide it, or auto-fit its width from a sample of loaded
rows. **Freeze through this column** keeps the leading visible columns in a
separate pane while the remaining columns scroll horizontally. Both panes
share vertical scrolling and row selection. At least one column stays in the
scrolling pane. **Unfreeze columns** and **Show all columns** restore the layout;
layout choices survive paging and reset when the result schema changes.
Column values, cell previews and filters always refer to their original columns.
Copy Rows and CSV/SQL copy continue to include all result columns.

The table pager shows the current page and supports **Go to page**. When available,
it includes the database's row estimate, explicitly marked with `~` and
`(estimate)`. Estimates can be stale and are omitted for filtered results;
page navigation uses the actual fetched rows. No full-table count is required.

**Run All** includes a collapsible statement log with success/failure, row counts,
duration and truncation warnings for completed statements. Execution stops at
the first error, labels unexecuted statements, and retains the last successful
result. Completed statements are not automatically rolled back.

History records duration, returned/affected rows and success or failure, with a
**This connection only** filter. Double-click an entry (or press Enter on it)
to load its SQL into the editor. Older history is preserved during migration;
entries without recorded outcomes show **Outcome unavailable**.

Connection tabs show **Running** for active queries and a red **Lost** marker
when disconnected unexpectedly. Disconnecting while a query runs requires
confirmation and requests cancellation while preserving editor SQL. The initial
connection screen provides driver installation commands and **Re-scan drivers**;
an empty Query view lists the main keyboard shortcuts.

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
  Both, and editor drafts, are stored in `~/.local/share/sdbui/query-library.sqlite3` on Linux
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

Favorite settings include an environment **label**, **color**, and **Read-only connection** switch. The label/color and read-only badge appear in the second toolbar; connection tabs show only the connection name. Settings are saved separately from driver options:

```toml
[SDBUI]
label = "Production"
color = "Red" # None, Red, Orange, Yellow, Green, Blue, Purple
read_only = true
```

Read-only favorites allow conservative read queries and execute each in a database-enforced read-only transaction on PostgreSQL and MySQL. Unsupported drivers block manual SQL in this mode. Transaction commands, writes, data-changing CTEs, and `SELECT INTO` are blocked before any statement in a batch runs. Use a database account with restricted permissions for access control; these safeguards do not prevent every side effect of database functions or external services. Changing a favorite's settings takes effect when opening a new connection.

Run All, Ctrl+Enter (selection/current statement), and launch-time SQL require confirmation for `DELETE`/`UPDATE` without a `WHERE` in the same scope, and for `DROP`/`TRUNCATE`. A review panel shows the submitted batch before **any** of it executes. Cancel leaves it unexecuted; editing SQL or changing the connection/schema invalidates approval. Confirmation applies to one run only. Detection ignores quoted strings, identifiers and ordinary comments, handles CTEs and nested queries, and conservatively flags executable MySQL comments. It is a lexical safeguard, so unusual SQL can produce extra warnings.

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
