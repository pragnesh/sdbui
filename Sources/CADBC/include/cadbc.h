// A minimal ADBC "driver manager" for Swift.
//
// Like databow (which uses the Rust adbc_driver_manager), we load an ADBC
// driver shared library at runtime and talk to it through the ADBC C API.
// Driver discovery (dbc manifests, connection profiles) lives in Swift; this
// shim only owns the C-level lifecycle so Swift never touches raw function
// pointers or AdbcError ownership rules.

#ifndef CADBC_H
#define CADBC_H

#include <stddef.h>
#include <stdint.h>

#include "adbc.h"

#ifdef __cplusplus
extern "C" {
#endif

/// An open driver + database + connection triple.
typedef struct CAdbcSession CAdbcSession;

/// Load the driver at `driver_path`, create a database with the given options
/// and open a connection.
///
/// `entrypoint` may be NULL, in which case `AdbcDriverInit` and the name
/// derived from the library file name (e.g. `AdbcDriverPostgresqlInit`) are
/// tried. On failure returns NULL and stores a malloc'd message in `*error_out`
/// (free it with `cadbc_free_string`).
CAdbcSession* cadbc_open(const char* driver_path, const char* entrypoint,
                         const char* const* option_keys,
                         const char* const* option_values, size_t option_count,
                         char** error_out);

/// Close the connection and database and unload the driver.
void cadbc_close(CAdbcSession* session);
/// 1 enabled, 0 disabled, -1 unavailable. Used before taking ownership of a transaction.
int cadbc_autocommit_enabled(CAdbcSession* session);

/// Execute `sql`. On success the result stream is written to `out` (the caller
/// owns it and must release it with `cadbc_stream_release`) and
/// `*rows_affected` is set (-1 when unknown). The stream retains its statement;
/// the session must remain open until the stream is released.
/// `error_position` receives a driver-reported 1-based character position, or 0.
AdbcStatusCode cadbc_execute(CAdbcSession* session, const char* sql,
                             struct ArrowArrayStream* out, int64_t* rows_affected,
                             int64_t* error_position, char** error_out);

/// PostgreSQL utility result sets such as EXPLAIN cannot use COPY (query).
/// The flag applies only to this statement; other queries retain driver defaults.
AdbcStatusCode cadbc_execute_options(CAdbcSession* session, const char* sql,
                             int disable_postgres_copy,
                             struct ArrowArrayStream* out, int64_t* rows_affected,
                             int64_t* error_position, char** error_out);

/// Cancel the query currently running on this session (ADBC 1.1 drivers only).
/// Safe to call from another thread.
AdbcStatusCode cadbc_cancel(CAdbcSession* session, char** error_out);

/// AdbcConnectionGetObjects. `depth` is one of ADBC_OBJECT_DEPTH_*.
AdbcStatusCode cadbc_get_objects(CAdbcSession* session, int depth,
                                 struct ArrowArrayStream* out, char** error_out);

/// AdbcConnectionGetInfo for the given info codes.
AdbcStatusCode cadbc_get_info(CAdbcSession* session, const uint32_t* codes,
                              size_t code_count, struct ArrowArrayStream* out,
                              char** error_out);

/// AdbcConnectionGetTableSchema.
AdbcStatusCode cadbc_get_table_schema(CAdbcSession* session, const char* catalog,
                                      const char* db_schema, const char* table,
                                      struct ArrowSchema* out, char** error_out);

// Arrow C stream helpers (these just call through the structs' callbacks).

/// Returns 0 on success, an errno-style code otherwise. On failure, a message
/// (if any) is written to `*error_out`.
int cadbc_stream_get_schema(struct ArrowArrayStream* stream, struct ArrowSchema* out,
                            char** error_out);
/// Returns 0 on success. End of stream is signalled by `out->release == NULL`.
int cadbc_stream_get_next(struct ArrowArrayStream* stream, struct ArrowArray* out,
                          char** error_out);
void cadbc_stream_release(struct ArrowArrayStream* stream);
void cadbc_schema_release(struct ArrowSchema* schema);
void cadbc_array_release(struct ArrowArray* array);

void cadbc_free_string(char* string);

#ifdef __cplusplus
}
#endif

#endif  // CADBC_H
