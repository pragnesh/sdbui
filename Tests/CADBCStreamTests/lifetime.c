// Standalone regression test: compile with -I Sources/CADBC/include and -ldl.
// Include the implementation to inject a driver without a real database.
#include "../../Sources/CADBC/cadbc.c"
#include <assert.h>
#include <errno.h>

static const uint8_t position_bytes[] = {'1', '7'}; // deliberately not NUL-terminated
static struct AdbcErrorDetail position_detail = {"PG_DIAG_STATEMENT_POSITION", position_bytes, 2};
static int detail_count(const struct AdbcError* error) { (void)error; return 1; }
static struct AdbcErrorDetail detail_get(const struct AdbcError* error, int index) {
  (void)error; assert(index == 0); return position_detail;
}

static int alive, stream_releases, statement_releases, fail_stage, read_error, option_calls, no_stream;
static int schema(struct ArrowArrayStream* stream, struct ArrowSchema* out) {
  assert(alive && stream->private_data == &alive);
  memset(out, 0, sizeof(*out));
  return 0;
}
static int next(struct ArrowArrayStream* stream, struct ArrowArray* out) {
  assert(alive && stream->private_data == &alive);
  memset(out, 0, sizeof(*out));
  return read_error ? EINVAL : 0;
}
static const char* last_error(struct ArrowArrayStream* stream) {
  assert(alive && stream->private_data == &alive);
  return "read failure";
}
static void release_stream(struct ArrowArrayStream* stream) {
  assert(alive);
  stream_releases++;
  stream->release = NULL;
}
static AdbcStatusCode statement_new(struct AdbcConnection* connection,
                                    struct AdbcStatement* statement,
                                    struct AdbcError* error) {
  (void)connection; (void)error;
  if (fail_stage == 1) return ADBC_STATUS_INTERNAL;
  alive = 1;
  statement->private_data = &alive;
  return ADBC_STATUS_OK;
}
static AdbcStatusCode set_sql(struct AdbcStatement* statement, const char* sql,
                              struct AdbcError* error) {
  (void)statement; (void)sql;
  if (fail_stage == 2) {
    memcpy(error->sqlstate, "42601", 5);
    error->private_data = &alive;
  }
  return fail_stage == 2 ? ADBC_STATUS_INVALID_ARGUMENT : ADBC_STATUS_OK;
}
static AdbcStatusCode set_option(struct AdbcStatement* statement, const char* key,
                                 const char* value, struct AdbcError* error) {
  (void)statement; (void)error;
  assert(strcmp(key, "adbc.postgresql.use_copy") == 0);
  assert(strcmp(value, ADBC_OPTION_VALUE_DISABLED) == 0);
  option_calls++;
  return fail_stage == 4 ? ADBC_STATUS_NOT_IMPLEMENTED : ADBC_STATUS_OK;
}
static AdbcStatusCode execute(struct AdbcStatement* statement,
                              struct ArrowArrayStream* out, int64_t* rows,
                              struct AdbcError* error) {
  (void)statement; (void)error;
  if (rows) *rows = 1;
  if (out) {
    *out = (struct ArrowArrayStream){schema, next, last_error, release_stream, &alive};
  }
  return fail_stage == 3 ? ADBC_STATUS_IO : ADBC_STATUS_OK;
}
static AdbcStatusCode release_statement(struct AdbcStatement* statement,
                                        struct AdbcError* error) {
  (void)statement; (void)error;
  assert(alive);
  if (!no_stream && fail_stage != 2 && fail_stage != 4) assert(stream_releases == 1);
  alive = 0;
  statement_releases++;
  return ADBC_STATUS_OK;
}
static const char *autocommit_value = "true";
static AdbcStatusCode autocommit_status = ADBC_STATUS_OK;
static AdbcStatusCode get_autocommit(struct AdbcConnection *connection, const char *key,
                                     char *value, size_t *length, struct AdbcError *error) {
  (void)connection; (void)error;
  assert(strcmp(key, ADBC_CONNECTION_OPTION_AUTOCOMMIT) == 0);
  assert(*length >= strlen(autocommit_value) + 1);
  strcpy(value, autocommit_value); *length = strlen(autocommit_value) + 1;
  return autocommit_status;
}
int main(void) {
  CAdbcSession session = {0};
  assert(cadbc_autocommit_enabled(&session) == -1);
  session.driver.ConnectionGetOption = get_autocommit;
  assert(cadbc_autocommit_enabled(&session) == 1);
  autocommit_value = "false";
  assert(cadbc_autocommit_enabled(&session) == 0);
  autocommit_value = "unknown";
  assert(cadbc_autocommit_enabled(&session) == -1);
  autocommit_status = ADBC_STATUS_NOT_IMPLEMENTED;
  assert(cadbc_autocommit_enabled(&session) == -1);

  session.driver.ErrorGetDetailCount = detail_count;
  session.driver.ErrorGetDetail = detail_get;
  struct AdbcError details = make_error();
  details.private_data = &alive;
  assert(statement_error_position(&session.driver, &details) == 17);
  position_detail.key = "PG_DIAG_INTERNAL_POSITION";
  assert(statement_error_position(&session.driver, &details) == 0);
  position_detail.key = "PG_DIAG_STATEMENT_POSITION";
  position_detail.value = (const uint8_t*)"9223372036854775808";
  position_detail.value_length = 19;
  assert(statement_error_position(&session.driver, &details) == 0);
  position_detail.value = (const uint8_t*)"-2";
  position_detail.value_length = 2;
  assert(statement_error_position(&session.driver, &details) == 0);
  position_detail.value = position_bytes;
  position_detail.value_length = 2;
  details.vendor_code = 0; // legacy driver errors do not expose private data
  assert(statement_error_position(&session.driver, &details) == 0);
  session.driver.StatementNew = statement_new;
  session.driver.StatementSetSqlQuery = set_sql;
  session.driver.StatementExecuteQuery = execute;
  session.driver.StatementRelease = release_statement;
  for (int scenario = 0; scenario < 6; scenario++) {
    alive = stream_releases = statement_releases = 0;
    fail_stage = scenario < 4 ? scenario : 0;
    read_error = scenario == 4;
    struct ArrowArrayStream stream = {0};
    char* error = NULL;
    int64_t position = -1;
    AdbcStatusCode status = cadbc_execute(&session, "SELECT 1", &stream, NULL, &position, &error);
    assert(position == (fail_stage == 2 ? 17 : 0));
    if (fail_stage) {
      assert(status != ADBC_STATUS_OK && error);
      if (fail_stage == 2) assert(strstr(error, "[SQLSTATE 42601]"));
      assert(!alive && statement_releases == (fail_stage != 1));
      assert(stream_releases == (fail_stage == 3));
      free(error);
      continue;
    }
    assert(status == ADBC_STATUS_OK && alive && statement_releases == 0);
    if (scenario != 5) { // scenario 5 releases an unread stream (row limit/cancel).
      struct ArrowSchema result_schema = {0};
      struct ArrowArray array = {0};
      assert(cadbc_stream_get_schema(&stream, &result_schema, &error) == 0);
      assert(cadbc_stream_get_next(&stream, &array, &error) == (read_error ? EINVAL : 0));
      if (read_error) {
        assert(error && strstr(error, "read failure"));
        free(error);
      }
    }
    cadbc_stream_release(&stream);
    cadbc_stream_release(&stream); // Release helper must be idempotent.
    assert(!alive && statement_releases == 1 && stream_releases == 1);
  }
  for (int fail = 0; fail < 2; fail++) {
    alive = stream_releases = statement_releases = option_calls = 0;
    fail_stage = fail ? 4 : 0;
    session.driver.StatementSetOption = set_option;
    struct ArrowArrayStream stream = {0};
    char *error = NULL;
    AdbcStatusCode status = cadbc_execute_options(&session, "EXPLAIN SELECT 1", 1, &stream, NULL, NULL, &error);
    assert(option_calls == 1);
    if (fail) {
      assert(status == ADBC_STATUS_NOT_IMPLEMENTED && error);
      assert(!alive && statement_releases == 1 && stream_releases == 0);
      free(error);
    } else {
      assert(status == ADBC_STATUS_OK && alive);
      cadbc_stream_release(&stream);
      assert(!alive && stream_releases == 1 && statement_releases == 1);
    }
  }
  no_stream = 1;
  for (int scenario = 0; scenario < 4; scenario++) {
    alive = stream_releases = statement_releases = 0;
    fail_stage = scenario;
    char *error = NULL; int64_t affected = -1;
    AdbcStatusCode status = cadbc_execute(&session, "UPDATE rows SET value=1", NULL, &affected, NULL, &error);
    assert((status == ADBC_STATUS_OK) == (scenario == 0));
    if (!scenario) assert(affected == 1);
    assert(!alive && stream_releases == 0 && statement_releases == (scenario == 1 ? 0 : 1));
    free(error);
  }
  puts("Statement/stream lifetime regression tests passed");
}
