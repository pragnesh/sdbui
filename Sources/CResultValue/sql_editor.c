#include "result_value.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    GtkWidget *view, *popup, *list;
    void *context;
    SDBUIEditorComplete complete;
    SDBUIEditorPosition position;
    SDBUIValueDestroy destroy;
    guint timer;
    int dialect, start, cursor;
    gboolean editing;
} SQLEditor;
static GtkWidget *text_view(GtkWidget *root) {
    if (GTK_IS_TEXT_VIEW(root)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = text_view(child); if (found) return found;
    }
    return NULL;
}
static void dismiss(SQLEditor *editor) {
    if (editor->popup) {
        gtk_popover_popdown(GTK_POPOVER(editor->popup));
        if (gtk_widget_get_parent(editor->popup)) gtk_widget_unparent(editor->popup);
    }
}
static void editor_free(gpointer data) {
    SQLEditor *editor = data;
    if (editor->timer) g_source_remove(editor->timer);
    if (editor->destroy) editor->destroy(editor->context);
    if (editor->popup) g_object_unref(editor->popup);
    g_free(editor);
}
static gboolean word(gunichar c) { return g_unichar_isalnum(c) || c == '_' || c == '$'; }
static gboolean keyword(const char *start, size_t length) {
    static const char *words[] = {"SELECT","FROM","WHERE","JOIN","LEFT","RIGHT","INNER","OUTER","ON","AS","AND","OR","NOT","NULL","IS","IN","EXISTS","GROUP","BY","ORDER","HAVING","LIMIT","OFFSET","DISTINCT","UNION","ALL","WITH","INSERT","INTO","VALUES","UPDATE","SET","DELETE","RETURNING","CASE","WHEN","THEN","ELSE","END","ASC","DESC","COUNT","SUM","AVG","MIN","MAX","COALESCE","EXPLAIN","ANALYZE","CREATE","TABLE","DROP","ALTER","TRUE","FALSE","LIKE","BETWEEN","BEGIN","COMMIT","ROLLBACK"};
    for (guint i = 0; i < G_N_ELEMENTS(words); i++) if (strlen(words[i]) == length && g_ascii_strncasecmp(start, words[i], length) == 0) return TRUE;
    return FALSE;
}
static void apply_tag(GtkTextBuffer *buffer, const char *name, int start, int end) {
    GtkTextIter a, b;
    gtk_text_buffer_get_iter_at_offset(buffer, &a, start); gtk_text_buffer_get_iter_at_offset(buffer, &b, end);
    gtk_text_buffer_apply_tag_by_name(buffer, name, &a, &b);
}
static void highlight(SQLEditor *editor) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor->view));
    GtkTextIter begin, finish;
    gtk_text_buffer_get_bounds(buffer, &begin, &finish);
    const char *tags[] = {"sdbui-keyword","sdbui-string","sdbui-comment","sdbui-number","sdbui-identifier"};
    GdkRGBA color;
#if GTK_CHECK_VERSION(4, 10, 0)
    gtk_widget_get_color(editor->view, &color);
#else
    gtk_style_context_get_color(gtk_widget_get_style_context(editor->view), &color);
#endif
    gboolean dark = color.red + color.green + color.blue > 1.5;
    const char *light[] = {"#003c99","#20682f","#626c70","#953800","#7050a0"};
    const char *night[] = {"#82aaff","#addb67","#a0a0a0","#f78c6c","#c792ea"};
    GtkTextTagTable *table = gtk_text_buffer_get_tag_table(buffer);
    for (int i = 0; i < 5; i++) {
        GtkTextTag *tag = gtk_text_tag_table_lookup(table, tags[i]);
        if (!tag) tag = gtk_text_buffer_create_tag(buffer, tags[i], NULL);
        g_object_set(tag, "foreground", dark ? night[i] : light[i], NULL);
        if (i == 0) g_object_set(tag, "weight", PANGO_WEIGHT_BOLD, NULL);
        gtk_text_buffer_remove_tag(buffer, tag, &begin, &finish);
    }
    char *text = gtk_text_buffer_get_text(buffer, &begin, &finish, FALSE);
    const char *p = text;
    int offset = 0;
    while (*p) {
        const char *start = p, *tag = NULL;
        if ((p[0] == '-' && p[1] == '-' && (editor->dialect != 1 || !p[2] || g_ascii_isspace(p[2]))) || (editor->dialect == 1 && *p == '#')) {
            while (*p && *p != '\n') p = g_utf8_next_char(p);
            tag = tags[2];
        } else if (p[0] == '/' && p[1] == '*') {
            int depth = 1; p += 2;
            while (*p && depth) {
                if (p[0] == '/' && p[1] == '*' && editor->dialect != 1) { depth++; p += 2; }
                else if (p[0] == '*' && p[1] == '/') { depth--; p += 2; }
                else p = g_utf8_next_char(p);
            }
            tag = tags[2];
        } else if (*p == '\'' || *p == '"' || *p == '`') {
            char quote = *p++;
            while (*p) {
                if (*p == quote) { p++; if (*p != quote) break; p++; }
                else if (*p == '\\' && p[1] && (editor->dialect == 1 || (quote == '\'' && start > text && (start[-1] == 'E' || start[-1] == 'e') && (start - 1 == text || (!g_ascii_isalnum(start[-2]) && start[-2] != '_'))))) p = g_utf8_next_char(p + 1);
                else p = g_utf8_next_char(p);
            }
            tag = quote == '\'' || (quote == '"' && editor->dialect == 1) ? tags[1] : tags[4];
        } else if (*p == '$' && editor->dialect != 1) {
            const char *end = p + 1;
            while (g_ascii_isalnum(*end) || *end == '_') end++;
            if (*end == '$') {
                char *delimiter = g_strndup(p, end - p + 1);
                const char *close = strstr(end + 1, delimiter);
                p = close ? close + strlen(delimiter) : end + 1 + strlen(end + 1);
                g_free(delimiter); tag = tags[1];
            } else p++;
        } else if (g_ascii_isdigit(*p)) {
            p++;
            while (g_ascii_isalnum(*p) || *p == '.' || *p == '_') p++;
            tag = tags[3];
        } else if (word(g_utf8_get_char(p))) {
            do { p = g_utf8_next_char(p); } while (*p && word(g_utf8_get_char(p)));
            if (keyword(start, p - start)) tag = tags[0];
        } else p = g_utf8_next_char(p);
        int length = (int)g_utf8_strlen(start, p - start);
        if (tag) apply_tag(buffer, tag, offset, offset + length);
        offset += length;
    }
    g_free(text);
}
static void notify_position(SQLEditor *editor) {
    if (!editor->position) return;
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor->view));
    GtkTextIter cursor, a, b;
    gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer));
    gboolean selected = gtk_text_buffer_get_selection_bounds(buffer, &a, &b);
    editor->position(editor->context, gtk_text_iter_get_offset(&cursor), selected ? gtk_text_iter_get_offset(&a) : -1, selected ? gtk_text_iter_get_offset(&b) : -1);
}
static void accept_completion(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list;
    SQLEditor *editor = data;
    const char *value = g_object_get_data(G_OBJECT(row), "sdbui-completion");
    if (!value) return;
    char *copy = g_strdup(value);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor->view));
    GtkTextIter a, b;
    gtk_text_buffer_get_iter_at_offset(buffer, &a, editor->start);
    gtk_text_buffer_get_iter_at_offset(buffer, &b, editor->cursor);
    editor->editing = TRUE;
    dismiss(editor);
    gtk_text_buffer_begin_user_action(buffer);
    gtk_text_buffer_delete(buffer, &a, &b);
    gtk_text_buffer_insert(buffer, &a, copy, -1);
    gtk_text_buffer_place_cursor(buffer, &a);
    gtk_text_buffer_end_user_action(buffer);
    editor->editing = FALSE;
    gtk_widget_grab_focus(editor->view);
    notify_position(editor);
    g_free(copy);
}
static void complete(SQLEditor *editor, gboolean explicit) {
    GtkRoot *root = gtk_widget_get_root(editor->view);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    gboolean focused = focus == editor->view || (focus && gtk_widget_is_ancestor(focus, editor->view));
    /* has-focus is false in an inactive window even when its focused editor
     * receives a key event. Trust explicit requests, and the root focus chain
     * for automatic suggestions. */
    if (!editor->complete || editor->editing || (!explicit && !focused)) return;
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor->view));
    GtkTextIter cursor, a, b;
    if (gtk_text_buffer_get_selection_bounds(buffer, &a, &b)) { dismiss(editor); return; }
    gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer));
    a = cursor;
    int length = 0; gunichar previous = 0;
    if (gtk_text_iter_backward_char(&a)) {
        previous = gtk_text_iter_get_char(&a);
        if (word(previous)) {
            length = 1;
            while (gtk_text_iter_backward_char(&a) && word(gtk_text_iter_get_char(&a))) length++;
        }
    }
    if (!explicit && previous != '.' && length < 2) { dismiss(editor); return; }
    gtk_text_buffer_get_bounds(buffer, &a, &b);
    char *text = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    editor->cursor = gtk_text_iter_get_offset(&cursor);
    char *values = editor->complete(editor->context, text, editor->cursor, &editor->start);
    g_free(text);
    if (!values || !*values || editor->start < 0 || editor->start > editor->cursor) { free(values); dismiss(editor); return; }
    if (!editor->popup) {
        editor->popup = g_object_ref_sink(gtk_popover_new());
        gtk_popover_set_autohide(GTK_POPOVER(editor->popup), FALSE);
        gtk_widget_set_focusable(editor->popup, FALSE);
        gtk_popover_set_position(GTK_POPOVER(editor->popup), GTK_POS_BOTTOM);
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_scrolled_window_set_min_content_width(GTK_SCROLLED_WINDOW(scroll), 220);
        gtk_widget_set_size_request(scroll, 240, -1);
        gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 240);
        gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
        editor->list = gtk_list_box_new();
        gtk_widget_set_focusable(editor->list, FALSE);
        gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(editor->list), TRUE);
        g_signal_connect(editor->list, "row-activated", G_CALLBACK(accept_completion), editor);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor->list);
        gtk_popover_set_child(GTK_POPOVER(editor->popup), scroll);
    }
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(editor->list))) gtk_list_box_remove(GTK_LIST_BOX(editor->list), child);
    char **lines = g_strsplit(values, "\n", 81); free(values);
    for (int i = 0; lines[i] && i < 80; i++) {
        GtkWidget *label = gtk_label_new(lines[i]);
        gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
        gtk_label_set_max_width_chars(GTK_LABEL(label), 60);
        gtk_widget_set_margin_start(label, 8); gtk_widget_set_margin_end(label, 8);
        gtk_widget_set_margin_top(label, 3); gtk_widget_set_margin_bottom(label, 3);
        gtk_list_box_append(GTK_LIST_BOX(editor->list), label);
        GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(editor->list), i);
        gtk_widget_set_focusable(GTK_WIDGET(row), FALSE);
        g_object_set_data_full(G_OBJECT(row), "sdbui-completion", g_strdup(lines[i]), g_free);
    }
    g_strfreev(lines);
    gtk_list_box_select_row(GTK_LIST_BOX(editor->list), gtk_list_box_get_row_at_index(GTK_LIST_BOX(editor->list), 0));
    if (!gtk_widget_get_parent(editor->popup)) gtk_widget_set_parent(editor->popup, editor->view);
    GdkRectangle rect;
    gtk_text_view_get_iter_location(GTK_TEXT_VIEW(editor->view), &cursor, &rect);
    gtk_text_view_buffer_to_window_coords(GTK_TEXT_VIEW(editor->view), GTK_TEXT_WINDOW_WIDGET, rect.x, rect.y, &rect.x, &rect.y);
    gtk_popover_set_pointing_to(GTK_POPOVER(editor->popup), &rect);
    gtk_popover_popup(GTK_POPOVER(editor->popup));
    gtk_popover_present(GTK_POPOVER(editor->popup));
}
static gboolean refresh(gpointer data) {
    SQLEditor *editor = data;
    editor->timer = 0;
    highlight(editor);
    complete(editor, FALSE);
    return G_SOURCE_REMOVE;
}
static void changed(GtkTextBuffer *buffer, gpointer data) {
    (void)buffer;
    SQLEditor *editor = g_object_get_data(G_OBJECT(data), "sdbui-sql-editor");
    if (!editor) return;
    if (editor->timer) g_source_remove(editor->timer);
    editor->timer = g_timeout_add(120, refresh, editor);
}
static void mark_set(GtkTextBuffer *buffer, GtkTextIter *iter, GtkTextMark *mark, gpointer data) {
    (void)iter;
    if (mark != gtk_text_buffer_get_insert(buffer) && mark != gtk_text_buffer_get_selection_bound(buffer)) return;
    SQLEditor *editor = g_object_get_data(G_OBJECT(data), "sdbui-sql-editor");
    if (editor && !editor->editing) { dismiss(editor); notify_position(editor); }
}
static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)code;
    SQLEditor *editor = data;
    if (key == GDK_KEY_space && (modifiers & GDK_CONTROL_MASK) && !(modifiers & (GDK_ALT_MASK | GDK_SUPER_MASK))) {
        complete(editor, TRUE); return TRUE;
    }
    if (!editor->popup || !gtk_widget_get_visible(editor->popup)) return FALSE;
    if (key == GDK_KEY_Escape) { dismiss(editor); return TRUE; }
    if (modifiers & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;
    GtkListBox *list = GTK_LIST_BOX(editor->list);
    GtkListBoxRow *row = gtk_list_box_get_selected_row(list);
    if ((key == GDK_KEY_Return || key == GDK_KEY_Tab || key == GDK_KEY_KP_Enter) && row) {
        accept_completion(list, row, editor); return TRUE;
    }
    if (key == GDK_KEY_Up || key == GDK_KEY_Down) {
        int index = row ? gtk_list_box_row_get_index(row) : 0;
        GtkListBoxRow *next = gtk_list_box_get_row_at_index(list, MAX(0, index + (key == GDK_KEY_Down ? 1 : -1)));
        if (next) gtk_list_box_select_row(list, next);
        return TRUE;
    }
    return FALSE;
}
static void unmap(GtkWidget *widget, gpointer data) { (void)widget; dismiss(data); }
static void focus_left(GtkEventControllerFocus *controller, gpointer data) { (void)controller; dismiss(data); }
void sdbui_sql_editor_install(void *root, void *context, SDBUIEditorComplete completion, SDBUIEditorPosition position, SDBUIValueDestroy destroy, int dialect) {
    GtkWidget *view = text_view(root);
    if (!view) { if (destroy) destroy(context); return; }
    SQLEditor *editor = g_object_get_data(G_OBJECT(view), "sdbui-sql-editor");
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    if (!editor) {
        editor = g_new0(SQLEditor, 1); editor->view = view;
        g_object_set_data_full(G_OBJECT(view), "sdbui-sql-editor", editor, editor_free);
        gtk_text_buffer_set_enable_undo(buffer, TRUE);
        g_signal_connect_object(buffer, "changed", G_CALLBACK(changed), view, 0);
        g_signal_connect_object(buffer, "mark-set", G_CALLBACK(mark_set), view, 0);
        g_signal_connect(view, "unmap", G_CALLBACK(unmap), editor);
        GtkEventController *keys = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
        g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), editor);
        gtk_widget_add_controller(view, keys);
        GtkEventController *focus = gtk_event_controller_focus_new();
        g_signal_connect(focus, "leave", G_CALLBACK(focus_left), editor);
        gtk_widget_add_controller(view, focus);
    } else if (editor->destroy) editor->destroy(editor->context);
    editor->context = context; editor->complete = completion; editor->position = position; editor->destroy = destroy; editor->dialect = dialect;
    changed(buffer, view);
}
void sdbui_sql_editor_select(void *root, int cursor, int start, int end, int reset_undo) {
    GtkWidget *view = text_view(root);
    if (!view) return;
    SQLEditor *editor = g_object_get_data(G_OBJECT(view), "sdbui-sql-editor");
    if (editor) dismiss(editor);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(view));
    if (reset_undo) { gtk_text_buffer_set_enable_undo(buffer, FALSE); gtk_text_buffer_set_enable_undo(buffer, TRUE); }
    int count = gtk_text_buffer_get_char_count(buffer);
    GtkTextIter a, b;
    gtk_text_buffer_get_iter_at_offset(buffer, &a, CLAMP(cursor, 0, count));
    if (start >= 0 && end >= start && end <= count) {
        gtk_text_buffer_get_iter_at_offset(buffer, &b, cursor == start ? end : start);
        gtk_text_buffer_select_range(buffer, &a, &b);
    } else gtk_text_buffer_place_cursor(buffer, &a);
    gtk_text_view_scroll_to_iter(GTK_TEXT_VIEW(view), &a, 0.1, FALSE, 0, 0);
}
