#include "result_value.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

static GMainLoop *loop;
static GtkWidget *grid;
static int previews, activations;
static const char *raw = "{\"n\":123456789012345678901234567890}";
static const char *pretty = "{\n  \"n\": 123456789012345678901234567890\n}";

static GtkWidget *find(GtkWidget *widget, GType type) {
    if (G_TYPE_CHECK_INSTANCE_TYPE(widget, type)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find(child, type);
        if (found) return found;
    }
    return NULL;
}
static GtkWidget *button(GtkWidget *widget, const char *label) {
    if (GTK_IS_BUTTON(widget) && g_strcmp0(gtk_button_get_label(GTK_BUTTON(widget)), label) == 0) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = button(child, label);
        if (found) return found;
    }
    return NULL;
}
static char *preview(void *context, uint32_t row, uint32_t column) {
    (void)context;
    g_assert_cmpuint(row, ==, 0); g_assert_cmpuint(column, ==, 0);
    previews++;
    return strdup("Long value preview");
}
static void activate(void *context, void *widget, uint32_t row, uint32_t column) {
    (void)context;
    g_assert_cmpuint(row, ==, 0); g_assert_cmpuint(column, ==, 0);
    activations++;
    sdbui_value_show(widget, "Value regression test", raw, strlen(raw), pretty, 0);
}
static void setup(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    gtk_list_item_set_child(GTK_LIST_ITEM(object), gtk_inscription_new(NULL));
}
static void bind(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *cell = gtk_list_item_get_child(GTK_LIST_ITEM(object));
    gtk_inscription_set_text(GTK_INSCRIPTION(cell), "This value is much too long to fit in the narrow test column and must have a tooltip");
}
static void clipboard_read(GObject *object, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(object), result, &error);
    g_assert_no_error(error);
    g_assert_cmpstr(text, ==, raw);
    g_free(text);
    g_main_loop_quit(loop);
}
static gboolean verify(gpointer data) {
    (void)data;
    GtkWidget *cell = find(grid, GTK_TYPE_INSCRIPTION);
    g_assert_nonnull(cell);
    GtkTooltip *tooltip = g_object_new(GTK_TYPE_TOOLTIP, NULL);
    gboolean handled = FALSE;
    g_signal_emit_by_name(cell, "query-tooltip", 0, 0, FALSE, tooltip, &handled);
    g_assert_true(handled); g_assert_cmpint(previews, ==, 1);
    gtk_inscription_set_text(GTK_INSCRIPTION(cell), "fits");
    handled = TRUE;
    g_signal_emit_by_name(cell, "query-tooltip", 0, 0, FALSE, tooltip, &handled);
    g_assert_false(handled); g_assert_cmpint(previews, ==, 1);
    g_object_unref(tooltip);
    GListModel *controllers = gtk_widget_observe_controllers(cell);
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GObject *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_GESTURE_CLICK(controller)) g_signal_emit_by_name(controller, "pressed", 2, 1.0, 1.0);
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    g_assert_cmpint(activations, ==, 1);
    GListModel *windows = gtk_window_get_toplevels();
    GtkWindow *viewer = NULL;
    for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
        GtkWindow *candidate = g_list_model_get_item(windows, i);
        if (g_strcmp0(gtk_window_get_title(candidate), "Value regression test") == 0) { viewer = candidate; break; }
        g_object_unref(candidate);
    }
    g_assert_nonnull(viewer);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(find(GTK_WIDGET(viewer), GTK_TYPE_TEXT_VIEW)));
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    g_assert_cmpstr(text, ==, pretty); g_free(text);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button(GTK_WIDGET(viewer), "Raw")), TRUE);
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
    g_assert_cmpstr(text, ==, raw); g_free(text);
    g_signal_emit_by_name(button(GTK_WIDGET(viewer), "Copy"), "clicked");
    gdk_clipboard_read_text_async(gtk_widget_get_clipboard(GTK_WIDGET(viewer)), NULL, clipboard_read, NULL);
    g_object_unref(viewer);
    return G_SOURCE_REMOVE;
}
int main(void) {
    gtk_init();
    GtkWidget *editor = gtk_text_view_new();
    g_object_ref_sink(editor);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(editor));
    gtk_text_buffer_set_text(buffer, "A🙂é\nSELECT", -1);
    g_assert_true(sdbui_editor_reveal(editor, 3));
    GtkTextIter cursor;
    gtk_text_buffer_get_iter_at_mark(buffer, &cursor, gtk_text_buffer_get_insert(buffer));
    g_assert_cmpint(gtk_text_iter_get_offset(&cursor), ==, 3);
    g_assert_false(sdbui_editor_reveal(editor, -1));
    g_assert_false(sdbui_editor_reveal(editor, 500));
    GtkTextIter begin, finish;
    gtk_text_buffer_get_bounds(buffer, &begin, &finish);
    char *unchanged = gtk_text_buffer_get_text(buffer, &begin, &finish, FALSE);
    g_assert_cmpstr(unchanged, ==, "A🙂é\nSELECT");
    g_free(unchanged);
    g_object_unref(editor);
    GListStore *rows = g_list_store_new(G_TYPE_OBJECT);
    GObject *row = g_object_new(G_TYPE_OBJECT, NULL);
    g_list_store_append(rows, row); g_object_unref(row);
    GtkSelectionModel *selection = GTK_SELECTION_MODEL(gtk_no_selection_new(G_LIST_MODEL(rows)));
    GtkWidget *view = gtk_column_view_new(selection);
    grid = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(grid), view);
    sdbui_value_install(grid, NULL, preview, activate, NULL);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(setup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(bind), NULL);
    GtkColumnViewColumn *column = gtk_column_view_column_new("Value", factory);
    gtk_column_view_column_set_fixed_width(column, 100);
    gtk_column_view_append_column(GTK_COLUMN_VIEW(view), column);
    g_object_unref(column);
    GtkWidget *window = gtk_window_new();
    gtk_window_set_default_size(GTK_WINDOW(window), 200, 200);
    gtk_window_set_child(GTK_WINDOW(window), grid);
    gtk_window_present(GTK_WINDOW(window));
    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(300, verify, NULL);
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window));
    g_main_loop_unref(loop);
    g_print("Value interactions passed: hover, activation, JSON toggle, exact clipboard copy, Unicode cursor navigation\n");
    return 0;
}
