#include "cadbc.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

struct CAdbcTransfer { atomic_int cancelled; atomic_llong rows; };
CAdbcTransfer *cadbc_transfer_new(void) { return calloc(1, sizeof(CAdbcTransfer)); }
void cadbc_transfer_free(CAdbcTransfer *token) { free(token); }
void cadbc_transfer_cancel(CAdbcTransfer *token) { if (token) atomic_store(&token->cancelled, 1); }
int cadbc_transfer_cancelled(CAdbcTransfer *token) { return token ? atomic_load(&token->cancelled) : 0; }
int64_t cadbc_transfer_rows(CAdbcTransfer *token) { return token ? atomic_load(&token->rows) : 0; }
static void transfer_progress(CAdbcTransfer *token, int64_t count) { if (token && count > 0) atomic_fetch_add(&token->rows, count); }
uintptr_t cadbc_transfer_poll_address(void) { return (uintptr_t)cadbc_transfer_cancelled; }
uintptr_t cadbc_transfer_progress_address(void) { return (uintptr_t)transfer_progress; }

/* Resolve the stable CPython C API at runtime. The application and plain SQL
 * browsing do not acquire a link-time dependency on a particular Python ABI.
 * One interpreter stays alive for the process; scopes are independent and all
 * Python references are manipulated under the GIL. */
typedef void PyObject;
static void *python_library;
static char *python_library_path;
static pthread_mutex_t python_mutex = PTHREAD_MUTEX_INITIALIZER;
static void (*py_initialize)(void);
static int (*py_initialized)(void);
static void *(*py_save_thread)(void);
static int (*py_gil_ensure)(void);
static void (*py_gil_release)(int);
static void (*py_set_home)(const wchar_t *);
static wchar_t *(*py_decode_locale)(const char *, size_t *);
static PyObject *(*py_dict_new)(void);
static int (*py_dict_set)(PyObject *, const char *, PyObject *);
static PyObject *(*py_dict_get)(PyObject *, const char *);
static void (*py_dict_clear)(PyObject *);
static PyObject *(*py_unicode)(const char *);
static const char *(*py_utf8)(PyObject *);
static PyObject *(*py_run)(const char *, int, PyObject *, PyObject *, void *);
static void (*py_decref)(PyObject *);
static void (*py_error_fetch)(PyObject **, PyObject **, PyObject **);
static PyObject *(*py_string)(PyObject *);
static void (*py_error_clear)(void);
static char *python_error(void) {
    PyObject *type = NULL, *value = NULL, *trace = NULL;
    py_error_fetch(&type, &value, &trace);
    PyObject *description = value ? py_string(value) : NULL;
    const char *message = description ? py_utf8(description) : NULL;
    char *copy = strndup(message ? message : "Transfer runtime failed.", 4096);
    if (description) py_decref(description);
    if (type) py_decref(type);
    if (value) py_decref(value);
    if (trace) py_decref(trace);
    py_error_clear();
    return copy;
}
static int initialize_python(const char *library, const char *home, char **error) {
    pthread_mutex_lock(&python_mutex);
    if (python_library) {
        int same = strcmp(python_library_path, library) == 0;
        if (!same && error) *error = strdup("Restart the app after changing the transfer Python runtime.");
        pthread_mutex_unlock(&python_mutex);
        return same;
    }
    void *handle = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) { if (error) *error = strdup(dlerror()); pthread_mutex_unlock(&python_mutex); return 0; }
#define LOAD(variable, symbol) do { *(void **)(&variable) = dlsym(handle, symbol); if (!variable) goto missing; } while (0)
    LOAD(py_initialize, "Py_Initialize"); LOAD(py_initialized, "Py_IsInitialized");
    LOAD(py_save_thread, "PyEval_SaveThread"); LOAD(py_gil_ensure, "PyGILState_Ensure"); LOAD(py_gil_release, "PyGILState_Release");
    LOAD(py_set_home, "Py_SetPythonHome"); LOAD(py_decode_locale, "Py_DecodeLocale");
    LOAD(py_dict_new, "PyDict_New"); LOAD(py_dict_set, "PyDict_SetItemString"); LOAD(py_dict_get, "PyDict_GetItemString");
    LOAD(py_dict_clear, "PyDict_Clear"); LOAD(py_unicode, "PyUnicode_FromString"); LOAD(py_utf8, "PyUnicode_AsUTF8");
    LOAD(py_run, "PyRun_StringFlags"); LOAD(py_decref, "Py_DecRef");
    LOAD(py_error_fetch, "PyErr_Fetch"); LOAD(py_string, "PyObject_Str"); LOAD(py_error_clear, "PyErr_Clear");
#undef LOAD
    if (!py_initialized()) {
        int *isolated = dlsym(handle, "Py_IsolatedFlag");
        int *ignore_environment = dlsym(handle, "Py_IgnoreEnvironmentFlag");
        if (isolated) *isolated = 1;
        if (ignore_environment) *ignore_environment = 1;
        /* CPython retains this string for the interpreter's lifetime. */
        wchar_t *python_home = py_decode_locale(home, NULL);
        if (!python_home) goto missing;
        py_set_home(python_home);
        py_initialize();
        py_save_thread();
    }
    python_library = handle;
    python_library_path = strdup(library);
    pthread_mutex_unlock(&python_mutex);
    return 1;
missing:
    if (error) *error = strdup("The selected Python shared library does not provide the required CPython API.");
    dlclose(handle);
    pthread_mutex_unlock(&python_mutex);
    return 0;
}
void *cadbc_python_scope(const char *library, const char *home, const char *script,
                         const char *configuration, char **error) {
    if (!initialize_python(library, home, error)) return NULL;
    FILE *file = fopen(script, "rb");
    if (!file) { if (error) *error = strdup("The bundled transfer helper was not found."); return NULL; }
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
    long length = ftell(file);
    if (length < 0 || length > 1048576) { fclose(file); if (error) *error = strdup("Invalid transfer helper size."); return NULL; }
    rewind(file);
    char *source = malloc((size_t)length + 1);
    if (!source) { fclose(file); return NULL; }
    size_t read = fread(source, 1, (size_t)length, file); fclose(file);
    if (read != (size_t)length) { free(source); if (error) *error = strdup("Could not read transfer helper."); return NULL; }
    source[length] = 0;
    int gil = py_gil_ensure();
    PyObject *globals = py_dict_new();
    PyObject *config = py_unicode(configuration);
    if (!globals || !config || py_dict_set(globals, "_sdbui_config_json", config) != 0) {
        if (config) py_decref(config);
        if (globals) py_decref(globals);
        if (error) *error = python_error();
        free(source); py_gil_release(gil); return NULL;
    }
    py_decref(config);
    PyObject *result = py_run(source, 257 /* Py_file_input */, globals, globals, NULL);
    free(source);
    if (!result) {
        if (error) *error = python_error();
        py_dict_clear(globals); py_decref(globals); py_gil_release(gil); return NULL;
    }
    py_decref(result); py_gil_release(gil);
    return globals;
}
char *cadbc_python_result(void *scope) {
    if (!scope) return NULL;
    int gil = py_gil_ensure();
    PyObject *value = py_dict_get(scope, "_sdbui_result_json");
    const char *text = value ? py_utf8(value) : NULL;
    char *copy = text ? strdup(text) : NULL;
    if (!copy) py_error_clear();
    py_gil_release(gil);
    return copy;
}
void cadbc_python_scope_free(void *scope) {
    if (!scope) return;
    int gil = py_gil_ensure(); py_dict_clear(scope); py_decref(scope); py_gil_release(gil);
}
