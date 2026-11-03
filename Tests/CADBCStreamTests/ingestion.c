#include "../../Sources/CADBC/cadbc.c"
#include <assert.h>

static int fail_at, options, statements, releases;
static struct ArrowArrayStream owned;
static void release_input(struct ArrowArrayStream *stream) { releases++; stream->release = NULL; }
static AdbcStatusCode new_statement(struct AdbcConnection *connection, struct AdbcStatement *statement, struct AdbcError *error) {
  (void)connection; (void)error;
  if (fail_at == 1) return ADBC_STATUS_INTERNAL;
  statements++; statement->private_data = &statements; return ADBC_STATUS_OK;
}
static AdbcStatusCode option(struct AdbcStatement *statement, const char *key, const char *value, struct AdbcError *error) {
  (void)statement; (void)error;
  const char *keys[] = {ADBC_INGEST_OPTION_TARGET_TABLE, ADBC_INGEST_OPTION_MODE, ADBC_INGEST_OPTION_TARGET_CATALOG, ADBC_INGEST_OPTION_TARGET_DB_SCHEMA};
  const char *values[] = {"target", ADBC_INGEST_OPTION_MODE_APPEND, "catalog", "schema"};
  assert(options < 4 && strcmp(key, keys[options]) == 0 && strcmp(value, values[options]) == 0);
  options++; return fail_at == 2 ? ADBC_STATUS_NOT_IMPLEMENTED : ADBC_STATUS_OK;
}
static AdbcStatusCode bind_stream(struct AdbcStatement *statement, struct ArrowArrayStream *stream, struct AdbcError *error) {
  (void)statement; (void)error;
  if (fail_at == 3) return ADBC_STATUS_INTERNAL;
  assert(stream->release); owned = *stream; memset(stream, 0, sizeof(*stream)); return ADBC_STATUS_OK;
}
static AdbcStatusCode execute_import(struct AdbcStatement *statement, struct ArrowArrayStream *out, int64_t *rows, struct AdbcError *error) {
  (void)statement; (void)error;
  assert(!out && owned.release && options == 4);
  *rows = 42; return fail_at == 4 ? ADBC_STATUS_INTERNAL : ADBC_STATUS_OK;
}
static AdbcStatusCode finish(struct AdbcStatement *statement, struct AdbcError *error) {
  (void)error; assert(statement->private_data); statements--;
  if (owned.release) owned.release(&owned);
  return fail_at == 5 ? ADBC_STATUS_INTERNAL : ADBC_STATUS_OK;
}
int main(void) {
  CAdbcSession session = {0};
  struct ArrowArrayStream stream = {.release = release_input};
  char *error = NULL; int64_t rows = -1;
  assert(cadbc_ingest_append(&session, "target", "catalog", "schema", &stream, &rows, &error) == ADBC_STATUS_NOT_IMPLEMENTED);
  assert(error && stream.release); free(error);
  session.driver.StatementNew = new_statement;
  session.driver.StatementSetOption = option;
  session.driver.StatementBindStream = bind_stream;
  session.driver.StatementExecuteQuery = execute_import;
  session.driver.StatementRelease = finish;
  for (fail_at = 0; fail_at <= 5; fail_at++) {
    options = releases = statements = 0; error = NULL; owned = (struct ArrowArrayStream){0};
    stream = (struct ArrowArrayStream){.release = release_input};
    AdbcStatusCode status = cadbc_ingest_append(&session, "target", "catalog", "schema", &stream, &rows, &error);
    assert((status == ADBC_STATUS_OK) == (fail_at == 0));
    assert((error != NULL) == (fail_at != 0)); free(error);
    assert(statements == 0);
    if (stream.release) stream.release(&stream);
    assert(releases == 1);
  }
  puts("Bulk ingestion ownership/error regression tests passed");
}
