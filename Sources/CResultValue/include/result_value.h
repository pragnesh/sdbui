#ifndef SDBUI_RESULT_VALUE_H
#define SDBUI_RESULT_VALUE_H
#include <stdint.h>
#include <stddef.h>
/* Provider returns a malloc-owned tooltip preview (or NULL). */
typedef char *(*SDBUIValuePreview)(void *context, uint32_t row, uint32_t column);
typedef void (*SDBUIValueActivate)(void *context, void *grid, uint32_t row, uint32_t column);
typedef void (*SDBUIValueDestroy)(void *context);
void sdbui_value_install(void *grid, void *context, SDBUIValuePreview preview,
                         SDBUIValueActivate activate, SDBUIValueDestroy destroy);
void sdbui_value_show(void *grid, const char *title, const char *raw, size_t raw_length, const char *formatted, int is_null);
/* Move the text editor cursor by Unicode character offset, without editing SQL. */
int sdbui_editor_reveal(void *editor, int offset);
#endif
