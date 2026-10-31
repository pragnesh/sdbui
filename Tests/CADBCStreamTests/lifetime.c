// Standalone regression test: compile with -I Sources/CADBC/include and -ldl.
// Include the implementation to inject a driver without a real database.
#include "../../Sources/CADBC/cadbc.c"
#include <assert.h>
#include <errno.h>

static int alive, stream_releases, statement_releases, fail_stage, read_error;
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
  (void)statement; (void)sql; (void)error;
  return fail_stage == 2 ? ADBC_STATUS_INVALID_ARGUMENT : ADBC_STATUS_OK;
}
static AdbcStatusCode execute(struct AdbcStatement* statement,
                              struct ArrowArrayStream* out, int64_t* rows,
                              struct AdbcError* error) {
  (void)statement; (void)rows; (void)error;
  if (out) {
    *out = (struct ArrowArrayStream){schema, next, last_error, release_stream, &alive};
  }
  return fail_stage == 3 ? ADBC_STATUS_IO : ADBC_STATUS_OK;
}
static AdbcStatusCode release_statement(struct AdbcStatement* statement,
                                        struct AdbcError* error) {
  (void)statement; (void)error;
  assert(alive);
  if (fail_stage != 2) assert(stream_releases == 1);
  alive = 0;
  statement_releases++;
  return ADBC_STATUS_OK;
}
int main(void) {
  CAdbcSession session = {0};
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
    AdbcStatusCode status = cadbc_execute(&session, "SELECT 1", &stream, NULL, &error);
    if (fail_stage) {
      assert(status != ADBC_STATUS_OK && error);
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
  puts("Statement/stream lifetime regression tests passed");
}
