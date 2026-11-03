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
/* Root capture-phase keyboard dispatcher. Command IDs match WorkspaceShortcut. */
typedef int (*SDBUIShortcutAction)(void *context, int32_t command);
int32_t sdbui_shortcut_command(uint32_t keyval, uint32_t modifiers);
void sdbui_shortcuts_install(void *root, void *context, SDBUIShortcutAction action, SDBUIValueDestroy destroy);
void sdbui_grid_font_size(void *grid, int size);
void sdbui_shortcut_target(void *widget, const char *name);
typedef void (*SDBUILayoutChange)(void *context, int width, int height, int final);
void sdbui_session_window(void *root, void *context, SDBUILayoutChange changed, SDBUIValueDestroy destroy);
void sdbui_session_sidebar(void *paned, int width, void *context, SDBUILayoutChange changed, SDBUIValueDestroy destroy);
typedef void (*SDBUITableSelect)(void *context, uint32_t index);
void sdbui_table_list_install(void *root, void *context, SDBUITableSelect select, SDBUIValueDestroy destroy);
void *sdbui_table_list_context(void *root);
void sdbui_table_list_update(void *root, const char *const *labels, int replace, uint32_t selected, int width, int height);
typedef void *(*SDBUIFilterPrepare)(void *context, uint32_t row, uint32_t column);
typedef void (*SDBUIFilterApply)(void *snapshot, int32_t command);
void sdbui_value_filters(void *grid, SDBUIFilterPrepare prepare, SDBUIFilterApply apply, SDBUIValueDestroy destroy);
typedef void *(*SDBUIHeaderPrepare)(void *context, uint32_t column);
typedef char *(*SDBUIHeaderApply)(void *snapshot, int32_t command);
void sdbui_grid_headers(void *grid, SDBUIHeaderPrepare prepare, SDBUIHeaderApply apply, SDBUIValueDestroy destroy);
void sdbui_grid_pair(void *root);
#endif
