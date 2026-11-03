# sdbui — SwiftCrossUI database query browser

A native desktop SQL browser built with [SwiftCrossUI](https://swiftcrossui.dev)
(GTK 4 on Linux, AppKit on macOS) that talks to databases through
[ADBC](https://arrow.apache.org/adbc/) drivers — the same approach as
[databow](https://github.com/columnar-tech/databow).

## Platform packages

The [release workflow](.github/workflows/release.yml) builds natively on Linux x86_64 and ARM64, and on macOS
Apple Silicon and Intel. Each architecture has its own cache, package names
and checksums. Tag releases publish only after every platform job succeeds;
pull requests and manual runs upload test artifacts without publishing.

On Linux, build the existing portable archive and Debian package plus AppImage:

```sh
scripts/package-linux.sh --appimage
```

AppImage tooling and its runtime are downloaded from official releases and
verified against pinned SHA-256 hashes. GTK 4, SQLite, GIO/GdkPixbuf modules,
icons, schemas and application resources are included. ADBC drivers and the
optional Python transfer environment stay external. The baseline is Ubuntu
24.04 (glibc 2.39) or a compatible newer distribution; an AppImage does not
remove this minimum libc requirement. Build ARM64 packages on an ARM64 host;
renaming an x86_64 executable does not produce an ARM64 build.

```sh
chmod +x sdbui-*.AppImage
./sdbui-<version>-linux-<architecture>.AppImage
# Optional CSV/import and Arrow/Parquet runtime:
./sdbui-<version>-linux-<architecture>.AppImage --setup-transfers
```

On systems without FUSE, use `--appimage-extract-and-run` or extract with
`--appimage-extract` and launch `squashfs-root/AppRun`. Drivers installed with
`dbc` must match the app's architecture. The AppImage launcher preserves normal
profile/driver discovery and SSH access.

On macOS 14 or later, the app uses an AppKit `NSTableView` grid with recycled
cells, sorting, resizing, multi-row copy, value tooltips/full-value windows,
cell/header menus and synchronized frozen columns. Workspace shortcuts accept
Command as well as Control; Command+Return runs the selected/current SQL.
GTK's SQL highlighting/completion hooks are not yet ported to AppKit.
Build an architecture-specific application bundle on the matching Mac:

```sh
scripts/package-macos.sh --version 0.0.0-local
```

This produces a ZIP containing `SDB Query Browser.app`, its Swift runtime and
transfer resources. Install by dragging the app into Applications. Bundles are
ad-hoc signed by default; `SDBUI_CODESIGN_IDENTITY` selects a local signing
identity. Notarization is not configured, so downloaded builds require approval
in macOS Privacy & Security before first launch. Install ADBC drivers separately.
For optional transfers, run Python 3.9–3.13 against
`/Applications/SDB Query Browser.app/Contents/Resources/setup-transfers.py`.

The AppKit implementation and ARM64 jobs require validation on their native
runners; they cannot be compiled or exercised on the Linux x86_64 development
host. CI includes macOS grid tests and packaged application launch checks.

## Import and export

Select a table, open the **Query** pane, then choose **Import / export**.
**Export table…** streams the entire table to CSV, JSON, SQL `INSERT`, Arrow
IPC (`.arrow`) or Parquet. Enable **Apply current filters** to export the
current browsing filter; browsing sort is preserved. Paging and **Max rows**
do not limit this export. **Export loaded CSV** still saves only the rows
already loaded in the result grid.

These transfers use an optional, private PyArrow runtime. With Python 3.9–3.13
and its shared library installed, run once from a source checkout:

```sh
python3 scripts/setup-transfers.py
```

For an installed Linux release, run
`python3 <prefix>/share/sdbui/setup-transfers.py` instead (`<prefix>` is
`~/.local`, `/usr/local`, or `/usr` for a Debian package). The installer downloads
the pinned PyArrow wheel, verifies its SHA-256 checksum against PyPI metadata,
and installs it into a dedicated environment under the user data directory.
It does not change system Python packages. Restart the app after setup.
Developers can use `--directory .build/transfer-python`; `SDBUI_PYTHON` can
select another Python executable containing PyArrow. Regular browsing and
loaded-result CSV export work without this runtime.

**Choose CSV…**, select delimiter/header/NULL options, then **Preview CSV**.
Map each source column to a destination column or skip it. Review the first
20 rows, then **Confirm append**. Imports use ADBC bulk loading into an
existing PostgreSQL or transactional MySQL table. Computed columns cannot be
mapped; identity columns are skipped by default. Unmapped columns use database
defaults. Duplicate mappings are rejected. Read-only favorites disable import,
and manual transactions must be finished first. Errors or cancellation roll
back all imported batches; a changed file or table schema requires a new preview.

CSV files use UTF-8, doubled quotes, and quoted multiline fields. By default,
an unquoted `\N` means NULL; quoted `"\N"` is literal text, and quoted `""`
is an empty string. Binary values use complete `\x`-prefixed hexadecimal text.
JSON keeps full numbers and encodes dates/times as strings and binary as hex.
Arrow and Parquet preserve the driver's Arrow types. CSV conversion validates
the destination types; unsupported nested types must be skipped or converted
before import. SQL exports omit computed columns, preserve explicit identity
values, and require an existing compatible table. They contain data only, not
DDL, and do not reset identity/serial sequences after restoration.

Exports write a private temporary file and replace the destination only after
successful completion. **Cancel** stops a transfer; progress shows rows processed.
Large transfers keep one Arrow batch in memory instead of accumulating the table.

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

For **Show rows** results, right-click a cell and choose **Filter by this value** → **=**, **!=**, or **IS NULL**. This uses that cell's full value, even with several rows selected, and updates the column/operator/value filter bar. It replaces the current filter, including grouped conditions, keeps sorting, and returns to the first page without changing editor SQL or the clipboard. On a NULL cell, `=` means `IS NULL` and `!=` means `IS NOT NULL`; an empty string and the text `NULL` remain ordinary values. The submenu is limited to browsed table rows, where the source table and column are known, and ignores stale actions after switching tables or replacing results.

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

**Advanced filters** combines conditions into groups. Choose **AND** or **OR**
within each group and between groups, then **Apply groups**. For example,
`(status = 'open' AND priority > 2) OR owner IS NULL`. Filters stay attached to
their query tab and apply to server-side sorting, paging and **Count exact**.
The simple Filter button and cell-value menu replace the current filter.

**Count exact** counts all rows matching the applied filter, not just the loaded
page. Exact counts are marked explicitly, cached with the query tab, and
invalidated by filter changes, refresh and committed row changes. Large counts
can be cancelled with **Cancel** or **Esc**. Estimates remain available for
unfiltered tables without requiring a full count.

For PostgreSQL and transactional MySQL base tables, **Insert row** opens a value
form. Right-click a browsed cell for **Edit row…** or **Delete row…**; these actions
require a primary key, including composite keys. Value, NULL and DEFAULT are
separate choices. Generated, binary and NUL-containing fields remain read-only. Arbitrary query
results, views and read-only favorites cannot be edited this way.

Choose **Review change** to inspect the generated SQL, then explicitly confirm
it. Updates and deletes lock and re-read the primary-key row, compare its
loaded values, and require exactly one affected row. Constraint failures and
stale rows abort the change; the transaction is rolled back on failure when
possible. The app requires confirmed autocommit and refuses to take over a
manual transaction. Finish that transaction first; reconnect after changing
autocommit settings or running transaction-controlling procedures. Editor SQL
is preserved, and successful changes refresh the browsed result.

**Table Info** includes incoming/outgoing foreign-key relations, user triggers
and view definitions. Catalog visibility depends on database privileges.
**Pin selected table** persists a star beside a table and sorts pinned matches
first within the selected namespace, while retaining fuzzy search. Pins are
scoped to the favorite or direct server/database endpoint.

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

Structure and Table Info use native catalogs for MySQL/MariaDB, PostgreSQL,
SQLite and DuckDB; other databases show the columns ADBC reports.

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

Read-only favorites allow conservative read queries and execute each in a database-enforced read-only transaction on PostgreSQL, MySQL and DuckDB. SQLite uses a transaction with verified `PRAGMA query_only`, restoring the previous setting afterward. Unsupported drivers block manual SQL in this mode. Transaction commands, writes, data-changing CTEs, and `SELECT INTO` are blocked before any statement in a batch runs. Use a database account with restricted permissions for access control; these safeguards do not prevent every side effect of database functions or external services. Changing a favorite's settings takes effect when opening a new connection.

Run All, Ctrl+Enter (selection/current statement), and launch-time SQL require confirmation for `DELETE`/`UPDATE` without a `WHERE` in the same scope, and for `DROP`/`TRUNCATE`. A review panel shows the submitted batch before **any** of it executes. Cancel leaves it unexecuted; editing SQL or changing the connection/schema invalidates approval. Confirmation applies to one run only. Detection ignores quoted strings, identifiers and ordinary comments, handles CTEs and nested queries, and conservatively flags executable MySQL comments. It is a lexical safeguard, so unusual SQL can produce extra warnings.

For SSH connections, open the **SSH Tunnel** tab, enable **Connect through SSH**,
and enter the SSH host (or config alias), port, username and optional identity
file. The database host and port on the Connection tab are resolved from the
SSH server. Test creates a temporary tunnel; Connect keeps its tunnel until
Disconnect or normal application exit. Failed connections also release tunnels.
The app chooses a loopback-only local port automatically and saves SSH settings
in `[SDBUI.SSH]`, separate from ADBC driver options.

OpenSSH must be installed. Authentication uses your SSH agent, default keys or
the selected identity file; unlock encrypted keys in your agent first. If the
SSH host's key is not yet in `known_hosts`, the app fetches it (`ssh-keyscan`),
shows its fingerprints and saves it only when you choose **Trust and connect**;
compare them with the fingerprints from the server's administrator. A changed
host key is never accepted: fix `known_hosts` yourself after checking why.
SSH password/passphrase dialogs are not supported. PostgreSQL and MySQL network
URIs are supported; PostgreSQL retains the original hostname for SSL verification.
MySQL sees the loopback endpoint, so SSL hostname verification may need a
certificate valid for that endpoint; the app does not weaken the selected SSL mode.
Other clients reading the shared TOML profiles must manage their own SSH tunnel.

To run isolated OpenSSH/PostgreSQL integration checks (Python `paramiko` and
PostgreSQL server tools required): `python3 scripts/test-ssh-integration.py`.
This uses temporary keys, known-host files and a temporary database.

## Preferences and embedded databases

Open **Preferences** beside **New connection**, or press Ctrl+, (Command+, on
macOS). Set the browsing page size (50–10,000), editor font (9–28), manual-query
row limit (100–1,000,000), and System/Light/Dark appearance. Defaults are 1,000
rows per page, 13-point text, a 10,000-row query limit and System appearance.
Apply updates open connections and future tabs; changing the page size reloads
browsing from the first page. Apply is disabled while a connection or query is
busy. Font shortcuts remain available, and restored tabs retain their saved font.

Preferences are stored atomically with owner-only file permissions in
`preferences.json` beside the query library. An unreadable file is preserved;
move it aside before saving replacement settings.

Install `sqlite` or `duckdb` with dbc. In URI mode, use
`sqlite:///absolute/path/database.sqlite` or `duckdb:///absolute/path/database.duckdb`;
DuckDB profiles may also provide the driver's `path` option. These dialects
support browsing, quoted identifiers, literal-value filters, native column/index/
foreign-key/view metadata and EXPLAIN. SQLite exposes triggers; DuckDB does not
support triggers. DuckDB relations retain catalog and schema qualification.
CSV, JSON, Arrow and Parquet table exports are available; row editing, CSV
import and SQL dump export currently require PostgreSQL/MySQL.

MySQL CSV import stages mapped columns in a private temporary table before
appending to the target in one transaction, preserving omitted defaults and
generated columns. The account needs `CREATE TEMPORARY TABLES` permission.
The Foundry MySQL driver receives its native `tls` option translated from the
connection form's SSL mode; existing explicit TLS options take priority.

## Quality checks

CI tests PostgreSQL 16 and MySQL 8.4 containers on both Linux architectures,
plus SQLite and DuckDB drivers. It exercises metadata, read-only execution,
row mutations, transactional CSV rollback and whole-table transfer formats.
Light/dark headless GTK checks run real SQLite queries, paging, preferences and
shortcuts, and retain screenshots and application logs as workflow artifacts.
macOS jobs run embedded-driver and AppKit tests before bundling the application.

To install the pinned public test drivers with dbc:

```sh
scripts/quality-drivers.sh
export ADBC_DRIVER_PATH="$PWD/.build/quality-drivers/config/adbc/drivers"
SDBUI_TEST_EMBEDDED=1 swift test
scripts/test-quality-ui.sh
```

The pinned versions are PostgreSQL/SQLite 1.13.0, MySQL 0.7.1 and DuckDB 2.0.0.
The UI script needs Xvfb, xauth, Python GI/Pillow, `gir1.2-atspi-2.0`,
`at-spi2-core` (the accessibility bus service), `dbus-daemon`, `dbus-bin` and
`libxtst6`, and
uses isolated profile/session/preferences directories. For network tests, set
`SDBUI_TEST_POSTGRES_URI` and `SDBUI_TEST_MYSQL_URI` to disposable test databases;
`SDBUI_REQUIRE_NETWORK_DRIVERS=1` makes missing network fixtures fail.
`python3 scripts/test-mysql-local.py` starts a private MySQL server when `mysqld`
is installed. Add `--all` to also start the PostgreSQL/SSH fixtures and run the
complete suite (PostgreSQL server tools and Python paramiko required).
The fixtures use temporary data directories and do not modify existing servers.

## Limitations

- Run All submits statements individually and stops at the first error.
- The Query tab keeps at most "Max rows" rows. The grid shows up to 1000
  characters per cell; copy and CSV export use full values.
- Cell editing, CSV import and SQL dump export require PostgreSQL or transactional MySQL tables. Other result grids are read-only.

## Performance notes

SwiftCrossUI re-lays-out a view and its children when observed state changes,
and size changes bubble up to the window. So the UI keeps the widget count
small (results are one text label per page, not one view per cell), keeps the
editor's text out of observation, and splits views so each reads only what it
shows.

To reproduce a session for profiling, launch with
`SDBUI_PROFILE=<profile> SDBUI_SQL="<query>" swift run sdbui`: it connects and
runs the query on startup.
