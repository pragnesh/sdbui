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

- Profile list and URI connect; vendor name/version from `GetInfo`
- Schema browser via `AdbcConnectionGetObjects` with filter and system-schema toggle;
  clicking a table previews it and shows its columns
- SQL editor, Run / Cancel (`AdbcConnectionCancel`), row limit
- Results as a monospaced, selectable text grid with typed headers and
  paging (100 rows/page)
- Arrow types: ints, floats, bool, utf8/large/view, binary, decimal128/256,
  date/time/timestamp (with time zones), duration, interval, list, struct, map,
  union, dictionary
- Export results to CSV

## Build and run (Linux)

```sh
# 1. Swift toolchain (once)
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
. ~/.local/share/swiftly/env.sh

# 2. GTK 4 headers (once)
sudo apt install libgtk-4-dev clang

# 3. Build, test, run
swift build
swift test
swift run sdbui
```

Profiles that go through SSH tunnels need the tunnels running first
(e.g. `~/.config/adbc/profiles/tunnels.sh`).

## Limitations

- One statement per Run (drivers generally reject multi-statement strings).
- Results keep at most "Max rows" rows; cells are cut at 500 characters
  (also in the CSV export) and at 48 characters in the grid.
- The sidebar lists at most 50 tables; use the filter to find others.

## Performance notes

SwiftCrossUI re-lays-out a view and its children when observed state changes,
and size changes bubble up to the window. So the UI keeps the widget count
small (results are one text label per page, not one view per cell), keeps the
editor's text out of observation, and splits views so each reads only what it
shows.

To reproduce a session for profiling, launch with
`SDBUI_PROFILE=<profile> SDBUI_SQL="<query>" swift run sdbui`: it connects and
runs the query on startup.
