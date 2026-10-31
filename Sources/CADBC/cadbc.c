#include "cadbc.h"

#include <ctype.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct CAdbcSession {
  void* library;
  struct AdbcDriver driver;
  struct AdbcDatabase database;
  struct AdbcConnection connection;
  int database_initialized;
  int connection_initialized;
};

// MARK: - Error helpers

static char* format_string(const char* format, ...) {
  va_list args;
  va_start(args, format);
  int length = vsnprintf(NULL, 0, format, args);
  va_end(args);
  if (length < 0) return NULL;

  char* buffer = malloc((size_t)length + 1);
  if (!buffer) return NULL;
  va_start(args, format);
  vsnprintf(buffer, (size_t)length + 1, format, args);
  va_end(args);
  return buffer;
}

static void set_error(char** error_out, char* message) {
  if (error_out) {
    *error_out = message;
  } else {
    free(message);
  }
}

static const char* status_name(AdbcStatusCode code) {
  switch (code) {
    case ADBC_STATUS_OK: return "OK";
    case ADBC_STATUS_UNKNOWN: return "UNKNOWN";
    case ADBC_STATUS_NOT_IMPLEMENTED: return "NOT_IMPLEMENTED";
    case ADBC_STATUS_NOT_FOUND: return "NOT_FOUND";
    case ADBC_STATUS_ALREADY_EXISTS: return "ALREADY_EXISTS";
    case ADBC_STATUS_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case ADBC_STATUS_INVALID_STATE: return "INVALID_STATE";
    case ADBC_STATUS_INVALID_DATA: return "INVALID_DATA";
    case ADBC_STATUS_INTEGRITY: return "INTEGRITY";
    case ADBC_STATUS_INTERNAL: return "INTERNAL";
    case ADBC_STATUS_IO: return "IO";
    case ADBC_STATUS_CANCELLED: return "CANCELLED";
    case ADBC_STATUS_TIMEOUT: return "TIMEOUT";
    case ADBC_STATUS_UNAUTHENTICATED: return "UNAUTHENTICATED";
    case ADBC_STATUS_UNAUTHORIZED: return "UNAUTHORIZED";
    default: return "UNRECOGNIZED";
  }
}

/// Convert an AdbcError into a malloc'd message and release it.
static void take_error(AdbcStatusCode code, struct AdbcError* error, const char* context,
                       char** error_out) {
  const char* message = error->message ? error->message : "(no message)";
  if (error->sqlstate[0]) {
    set_error(error_out, format_string("%s: [%s] [SQLSTATE %.5s] %s",
                                      context, status_name(code), error->sqlstate, message));
  } else {
    set_error(error_out, format_string("%s: [%s] %s", context, status_name(code), message));
  }
  if (error->release) error->release(error);
}

static struct AdbcError make_error(void) {
  struct AdbcError error;
  memset(&error, 0, sizeof(error));
  // Opt in to ADBC 1.1 extended errors so drivers may populate them.
  error.vendor_code = ADBC_ERROR_VENDOR_CODE_PRIVATE_DATA;
  return error;
}

// MARK: - Driver loading

/// Mirror the reference driver manager's default entrypoint derivation:
///   libadbc_driver_sqlite.so.2.0.0 -> AdbcDriverSqliteInit
///   proprietary_driver.so          -> AdbcProprietaryDriverInit
static char* default_entrypoint(const char* path) {
  const char* name = strrchr(path, '/');
  name = name ? name + 1 : path;
  if (strncmp(name, "lib", 3) == 0) name += 3;
  size_t length = strcspn(name, ".");

  // Worst case: "Adbc" + name + "Init" + NUL.
  char* result = malloc(length + 9);
  if (!result) return NULL;
  size_t out = 0;
  int upper_next = 1;
  for (size_t i = 0; i < length; i++) {
    char c = name[i];
    if (c == '_' || c == '-') {
      upper_next = 1;
      continue;
    }
    result[out++] = upper_next ? (char)toupper((unsigned char)c) : c;
    upper_next = 0;
  }
  result[out] = '\0';

  char* final = (strncmp(result, "Adbc", 4) == 0)
                    ? format_string("%sInit", result)
                    : format_string("Adbc%sInit", result);
  free(result);
  return final;
}

static AdbcDriverInitFunc find_init(void* library, const char* path,
                                    const char* entrypoint) {
  if (entrypoint && *entrypoint) {
    return (AdbcDriverInitFunc)dlsym(library, entrypoint);
  }
  AdbcDriverInitFunc init = (AdbcDriverInitFunc)dlsym(library, "AdbcDriverInit");
  if (init) return init;

  char* derived = default_entrypoint(path);
  if (derived) {
    init = (AdbcDriverInitFunc)dlsym(library, derived);
    free(derived);
  }
  return init;
}

CAdbcSession* cadbc_open(const char* driver_path, const char* entrypoint,
                         const char* const* option_keys,
                         const char* const* option_values, size_t option_count,
                         char** error_out) {
  CAdbcSession* session = calloc(1, sizeof(CAdbcSession));
  if (!session) {
    set_error(error_out, format_string("out of memory"));
    return NULL;
  }

  session->library = dlopen(driver_path, RTLD_NOW | RTLD_LOCAL);
  if (!session->library) {
    set_error(error_out,
              format_string("Failed to load driver '%s': %s", driver_path, dlerror()));
    free(session);
    return NULL;
  }

  AdbcDriverInitFunc init = find_init(session->library, driver_path, entrypoint);
  if (!init) {
    set_error(error_out, format_string("Driver '%s' has no ADBC entrypoint (%s)",
                                       driver_path, entrypoint ? entrypoint : "AdbcDriverInit"));
    dlclose(session->library);
    free(session);
    return NULL;
  }

  // Prefer ADBC 1.1 (needed for cancellation); fall back to 1.0 drivers.
  struct AdbcError error = make_error();
  AdbcStatusCode status = init(ADBC_VERSION_1_1_0, &session->driver, &error);
  if (status == ADBC_STATUS_NOT_IMPLEMENTED) {
    if (error.release) error.release(&error);
    error = make_error();
    memset(&session->driver, 0, sizeof(session->driver));
    status = init(ADBC_VERSION_1_0_0, &session->driver, &error);
  }
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "Driver initialization failed", error_out);
    dlclose(session->library);
    free(session);
    return NULL;
  }

  session->database.private_driver = &session->driver;
  error = make_error();
  status = session->driver.DatabaseNew(&session->database, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "DatabaseNew failed", error_out);
    cadbc_close(session);
    return NULL;
  }
  session->database_initialized = 1;

  for (size_t i = 0; i < option_count; i++) {
    error = make_error();
    status = session->driver.DatabaseSetOption(&session->database, option_keys[i],
                                               option_values[i], &error);
    if (status != ADBC_STATUS_OK) {
      char* context = format_string("Setting option '%s' failed", option_keys[i]);
      take_error(status, &error, context ? context : "Setting option failed", error_out);
      free(context);
      cadbc_close(session);
      return NULL;
    }
  }

  error = make_error();
  status = session->driver.DatabaseInit(&session->database, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "Failed to open database", error_out);
    cadbc_close(session);
    return NULL;
  }

  session->connection.private_driver = &session->driver;
  error = make_error();
  status = session->driver.ConnectionNew(&session->connection, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "ConnectionNew failed", error_out);
    cadbc_close(session);
    return NULL;
  }
  session->connection_initialized = 1;

  error = make_error();
  status = session->driver.ConnectionInit(&session->connection, &session->database, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "Failed to connect", error_out);
    cadbc_close(session);
    return NULL;
  }

  return session;
}

void cadbc_close(CAdbcSession* session) {
  if (!session) return;
  struct AdbcError error = make_error();
  if (session->connection_initialized) {
    session->driver.ConnectionRelease(&session->connection, &error);
    if (error.release) error.release(&error);
    error = make_error();
  }
  if (session->database_initialized) {
    session->driver.DatabaseRelease(&session->database, &error);
    if (error.release) error.release(&error);
    error = make_error();
  }
  if (session->driver.release) {
    session->driver.release(&session->driver, &error);
    if (error.release) error.release(&error);
  }
  // Deliberately not dlclose()-ing: Go-based drivers (e.g. the dbc MySQL
  // driver) cannot be safely unloaded once their runtime has started.
  free(session);
}

// MARK: - Queries

// A statement must outlive its result stream. Forward callbacks to the
// driver's original stream and release it before releasing the statement.
struct StatementStream {
  struct ArrowArrayStream stream;
  struct AdbcStatement statement;
  struct AdbcDriver* driver;
};

static int statement_stream_schema(struct ArrowArrayStream* stream,
                                   struct ArrowSchema* out) {
  struct StatementStream* owner = stream->private_data;
  return owner->stream.get_schema(&owner->stream, out);
}

static int statement_stream_next(struct ArrowArrayStream* stream,
                                 struct ArrowArray* out) {
  struct StatementStream* owner = stream->private_data;
  return owner->stream.get_next(&owner->stream, out);
}

static const char* statement_stream_error(struct ArrowArrayStream* stream) {
  struct StatementStream* owner = stream->private_data;
  return owner->stream.get_last_error
      ? owner->stream.get_last_error(&owner->stream) : NULL;
}

static void statement_stream_release(struct ArrowArrayStream* stream) {
  struct StatementStream* owner = stream->private_data;
  stream->release = NULL;
  stream->private_data = NULL;
  if (owner->stream.release) owner->stream.release(&owner->stream);
  struct AdbcError error = make_error();
  owner->driver->StatementRelease(&owner->statement, &error);
  if (error.release) error.release(&error);
  free(owner);
}

AdbcStatusCode cadbc_execute(CAdbcSession* session, const char* sql,
                             struct ArrowArrayStream* out, int64_t* rows_affected,
                             char** error_out) {
  struct StatementStream* owner = calloc(1, sizeof(*owner));
  if (!owner) {
    set_error(error_out, format_string("out of memory"));
    return ADBC_STATUS_INTERNAL;
  }
  owner->driver = &session->driver;
  owner->statement.private_driver = &session->driver;

  struct AdbcError error = make_error();
  AdbcStatusCode status = session->driver.StatementNew(
      &session->connection, &owner->statement, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "Failed to create statement", error_out);
    free(owner);
    return status;
  }

  error = make_error();
  status = session->driver.StatementSetSqlQuery(&owner->statement, sql, &error);
  if (status != ADBC_STATUS_OK) {
    take_error(status, &error, "Failed to set SQL query", error_out);
  } else {
    error = make_error();
    status = session->driver.StatementExecuteQuery(
        &owner->statement, out ? &owner->stream : NULL, rows_affected, &error);
    if (status != ADBC_STATUS_OK) {
      take_error(status, &error, "Query failed", error_out);
    }
  }

  struct ArrowArrayStream wrapped = {
      .get_schema = statement_stream_schema,
      .get_next = statement_stream_next,
      .get_last_error = statement_stream_error,
      .release = statement_stream_release,
      .private_data = owner,
  };
  if (status == ADBC_STATUS_OK && out && owner->stream.release) {
    *out = wrapped;
  } else {
    statement_stream_release(&wrapped);
  }
  return status;
}

AdbcStatusCode cadbc_cancel(CAdbcSession* session, char** error_out) {
  if (!session->driver.ConnectionCancel) {
    set_error(error_out, format_string("This driver does not support cancellation"));
    return ADBC_STATUS_NOT_IMPLEMENTED;
  }
  struct AdbcError error = make_error();
  AdbcStatusCode status = session->driver.ConnectionCancel(&session->connection, &error);
  if (status != ADBC_STATUS_OK) take_error(status, &error, "Cancel failed", error_out);
  return status;
}

AdbcStatusCode cadbc_get_objects(CAdbcSession* session, int depth,
                                 struct ArrowArrayStream* out, char** error_out) {
  struct AdbcError error = make_error();
  AdbcStatusCode status = session->driver.ConnectionGetObjects(
      &session->connection, depth, NULL, NULL, NULL, NULL, NULL, out, &error);
  if (status != ADBC_STATUS_OK) take_error(status, &error, "GetObjects failed", error_out);
  return status;
}

AdbcStatusCode cadbc_get_info(CAdbcSession* session, const uint32_t* codes,
                              size_t code_count, struct ArrowArrayStream* out,
                              char** error_out) {
  struct AdbcError error = make_error();
  AdbcStatusCode status = session->driver.ConnectionGetInfo(&session->connection, codes,
                                                            code_count, out, &error);
  if (status != ADBC_STATUS_OK) take_error(status, &error, "GetInfo failed", error_out);
  return status;
}

AdbcStatusCode cadbc_get_table_schema(CAdbcSession* session, const char* catalog,
                                      const char* db_schema, const char* table,
                                      struct ArrowSchema* out, char** error_out) {
  struct AdbcError error = make_error();
  AdbcStatusCode status = session->driver.ConnectionGetTableSchema(
      &session->connection, catalog, db_schema, table, out, &error);
  if (status != ADBC_STATUS_OK) take_error(status, &error, "GetTableSchema failed", error_out);
  return status;
}

// MARK: - Arrow C stream helpers

static void take_stream_error(struct ArrowArrayStream* stream, int code, char** error_out) {
  const char* message = stream->get_last_error ? stream->get_last_error(stream) : NULL;
  set_error(error_out, format_string("Reading results failed (%d): %s", code,
                                     message ? message : "(no message)"));
}

int cadbc_stream_get_schema(struct ArrowArrayStream* stream, struct ArrowSchema* out,
                            char** error_out) {
  int code = stream->get_schema(stream, out);
  if (code != 0) take_stream_error(stream, code, error_out);
  return code;
}

int cadbc_stream_get_next(struct ArrowArrayStream* stream, struct ArrowArray* out,
                          char** error_out) {
  int code = stream->get_next(stream, out);
  if (code != 0) take_stream_error(stream, code, error_out);
  return code;
}

void cadbc_stream_release(struct ArrowArrayStream* stream) {
  if (stream && stream->release) stream->release(stream);
}

void cadbc_schema_release(struct ArrowSchema* schema) {
  if (schema && schema->release) schema->release(schema);
}

void cadbc_array_release(struct ArrowArray* array) {
  if (array && array->release) array->release(array);
}

void cadbc_free_string(char* string) { free(string); }
