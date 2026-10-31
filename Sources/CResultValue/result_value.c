#include "result_value.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    void *context;
    SDBUIValuePreview preview;
    SDBUIValueActivate activate;
    SDBUIValueDestroy destroy;
} ValueSource;

typedef struct {
    GtkWidget *grid; /* weak: factories and cells belong to this grid */
    guint column;
} ColumnSource;

static void source_free(gpointer data) {
    ValueSource *source = data;
    if (source->destroy) source->destroy(source->context);
    g_free(source);
}

static gboolean show_tooltip(GtkWidget *cell, gint x, gint y, gboolean keyboard, GtkTooltip *tooltip, gpointer data) {
    (void)x; (void)y; (void)keyboard;
    ColumnSource *column = data;
    guint position = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(cell), "sdbui-value-row"));
    ValueSource *source = g_object_get_data(G_OBJECT(column->grid), "sdbui-values");
    if (!position || !source || !source->preview) return FALSE;
    const char *text = gtk_inscription_get_text(GTK_INSCRIPTION(cell));
    if (!text) return FALSE;
    PangoLayout *layout = gtk_widget_create_pango_layout(cell, text);
    int width;
    pango_layout_get_pixel_size(layout, &width, NULL);
    g_object_unref(layout);
    if (width <= gtk_widget_get_width(cell)) return FALSE;
    char *preview = source->preview(source->context, position - 1, column->column);
    if (!preview) return FALSE;
    GtkWidget *label = gtk_label_new(preview); /* plain text, never markup */
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 100);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_tooltip_set_custom(tooltip, label);
    free(preview);
    return TRUE;
}

static void double_clicked(GtkGestureClick *gesture, gint presses, gdouble x, gdouble y, gpointer data) {
    (void)x; (void)y;
    if (presses != 2) return;
    ColumnSource *column = data;
    GtkWidget *cell = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    guint position = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(cell), "sdbui-value-row"));
    ValueSource *source = g_object_get_data(G_OBJECT(column->grid), "sdbui-values");
    if (position && source && source->activate) {
        gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
        source->activate(source->context, column->grid, position - 1, column->column);
    }
}

static void setup_cell(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory;
    GtkWidget *cell = gtk_list_item_get_child(GTK_LIST_ITEM(object));
    if (!GTK_IS_INSCRIPTION(cell)) return;
    ColumnSource *owned = g_new(ColumnSource, 1);
    *owned = *(ColumnSource *)data;
    g_object_set_data_full(G_OBJECT(cell), "sdbui-value-cell", owned, g_free);
    data = owned;
    gtk_widget_set_has_tooltip(cell, TRUE);
    g_signal_connect(cell, "query-tooltip", G_CALLBACK(show_tooltip), data);
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), GDK_BUTTON_PRIMARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
    g_signal_connect(gesture, "pressed", G_CALLBACK(double_clicked), data);
    gtk_widget_add_controller(cell, GTK_EVENT_CONTROLLER(gesture));
}

static void bind_cell(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkListItem *item = GTK_LIST_ITEM(object);
    GtkWidget *cell = gtk_list_item_get_child(item);
    guint position = gtk_list_item_get_position(item);
    if (cell) g_object_set_data(G_OBJECT(cell), "sdbui-value-row",
                              position == GTK_INVALID_LIST_POSITION ? NULL : GUINT_TO_POINTER(position + 1));
}

static void unbind_cell(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *cell = gtk_list_item_get_child(GTK_LIST_ITEM(object));
    if (cell) g_object_set_data(G_OBJECT(cell), "sdbui-value-row", NULL);
}

static GtkWidget *find_column_view(GtkWidget *widget) {
    if (GTK_IS_COLUMN_VIEW(widget)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_column_view(child);
        if (found) return found;
    }
    return NULL;
}

static void install_columns(GtkWidget *grid) {
    GtkWidget *view = find_column_view(grid);
    if (!view) return;
    GListModel *columns = gtk_column_view_get_columns(GTK_COLUMN_VIEW(view));
    for (guint i = 0; i < g_list_model_get_n_items(columns); i++) {
        GtkColumnViewColumn *column = g_list_model_get_item(columns, i);
        GtkListItemFactory *factory = gtk_column_view_column_get_factory(column);
        if (GTK_IS_SIGNAL_LIST_ITEM_FACTORY(factory) && !g_object_get_data(G_OBJECT(factory), "sdbui-value-column")) {
            ColumnSource *source = g_new0(ColumnSource, 1);
            source->grid = grid;
            source->column = i;
            g_object_set_data_full(G_OBJECT(factory), "sdbui-value-column", source, g_free);
            g_signal_connect_after(factory, "setup", G_CALLBACK(setup_cell), source);
            g_signal_connect_after(factory, "bind", G_CALLBACK(bind_cell), source);
            g_signal_connect(factory, "unbind", G_CALLBACK(unbind_cell), source);
        }
        g_object_unref(column);
    }
}

static void columns_changed(GListModel *columns, guint position, guint removed, guint added, gpointer grid) {
    (void)columns; (void)position; (void)removed; (void)added;
    install_columns(GTK_WIDGET(grid));
}

void sdbui_value_install(void *widget, void *context, SDBUIValuePreview preview,
                         SDBUIValueActivate activate, SDBUIValueDestroy destroy) {
    GtkWidget *grid = widget;
    ValueSource *source = g_object_get_data(G_OBJECT(grid), "sdbui-values");
    if (!source) {
        source = g_new0(ValueSource, 1);
        source->context = context;
        source->preview = preview;
        source->activate = activate;
        source->destroy = destroy;
        g_object_set_data_full(G_OBJECT(grid), "sdbui-values", source, source_free);
    } else {
        if (source->destroy) source->destroy(source->context);
        source->context = context;
        source->preview = preview;
        source->activate = activate;
        source->destroy = destroy;
    }
    GtkWidget *view = find_column_view(grid);
    if (view && !g_object_get_data(G_OBJECT(grid), "sdbui-value-observing")) {
        GListModel *columns = gtk_column_view_get_columns(GTK_COLUMN_VIEW(view));
        g_signal_connect_object(columns, "items-changed", G_CALLBACK(columns_changed), grid, 0);
        g_object_set_data(G_OBJECT(grid), "sdbui-value-observing", GINT_TO_POINTER(1));
    }
    install_columns(grid);
}

typedef struct {
    GtkTextBuffer *buffer; /* owned by text view */
    char *raw;
    size_t raw_length;
    char *formatted;
    gboolean pretty;
} Viewer;

static void viewer_free(gpointer data) {
    Viewer *viewer = data;
    g_free(viewer->raw);
    g_free(viewer->formatted);
    g_free(viewer);
}
/* GtkTextBuffer cannot display NUL; expose its position without losing the
 * original bytes used by Copy. */
static void set_raw_text(Viewer *viewer) {
    GString *visible = g_string_new(NULL);
    for (size_t i = 0; i < viewer->raw_length; i++) {
        if (viewer->raw[i] == 0) g_string_append(visible, "␀");
        else g_string_append_c(visible, viewer->raw[i]);
    }
    gtk_text_buffer_set_text(viewer->buffer, visible->str, (int)visible->len);
    g_string_free(visible, TRUE);
}
static void toggle_json(GtkToggleButton *button, gpointer data) {
    Viewer *viewer = data;
    viewer->pretty = gtk_toggle_button_get_active(button);
    if (viewer->pretty) gtk_text_buffer_set_text(viewer->buffer, viewer->formatted, -1);
    else set_raw_text(viewer);
}
static void copy_value(GtkButton *button, gpointer data) {
    Viewer *viewer = data;
    const char *text = viewer->pretty ? viewer->formatted : viewer->raw;
    size_t length = viewer->pretty ? strlen(viewer->formatted) : viewer->raw_length;
    GBytes *bytes = g_bytes_new(text, length);
    GdkContentProvider *provider = gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", bytes);
    gdk_clipboard_set_content(gtk_widget_get_clipboard(GTK_WIDGET(button)), provider);
    g_object_unref(provider);
    g_bytes_unref(bytes);
}
static gboolean viewer_key(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)controller; (void)keycode; (void)state;
    if (keyval != GDK_KEY_Escape) return FALSE;
    gtk_window_destroy(GTK_WINDOW(data));
    return TRUE;
}
static void close_viewer(GtkButton *button, gpointer data) {
    (void)button;
    gtk_window_destroy(GTK_WINDOW(data));
}

void sdbui_value_show(void *widget, const char *title, const char *raw, size_t raw_length, const char *formatted, int is_null) {
    GtkWidget *grid = widget;
    GtkWidget *window = gtk_window_new();
    GtkRoot *root = gtk_widget_get_root(grid);
    if (GTK_IS_WINDOW(root)) gtk_window_set_transient_for(GTK_WINDOW(window), GTK_WINDOW(root));
    gtk_window_set_destroy_with_parent(GTK_WINDOW(window), TRUE);
    gtk_window_set_modal(GTK_WINDOW(window), TRUE);
    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_window_set_default_size(GTK_WINDOW(window), 800, 600);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(box, 12); gtk_widget_set_margin_bottom(box, 12);
    gtk_widget_set_margin_start(box, 12); gtk_widget_set_margin_end(box, 12);
    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *label = gtk_label_new(is_null ? "NULL · database null" : "Full value · read-only");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_box_append(GTK_BOX(toolbar), label);
    Viewer *viewer = g_new0(Viewer, 1);
    viewer->raw = g_memdup2(raw ? raw : "", raw ? raw_length + 1 : 1);
    viewer->raw_length = raw ? raw_length : 0;
    viewer->formatted = g_strdup(formatted);
    viewer->pretty = formatted != NULL;
    GtkWidget *text = gtk_text_view_new();
    viewer->buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(text));
    gtk_text_view_set_editable(GTK_TEXT_VIEW(text), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(text), TRUE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text), GTK_WRAP_NONE);
    if (formatted) gtk_text_buffer_set_text(viewer->buffer, formatted, -1);
    else set_raw_text(viewer);
    if (formatted) {
        GtkWidget *raw_button = gtk_toggle_button_new_with_label("Raw");
        gtk_box_append(GTK_BOX(toolbar), raw_button);
        GtkWidget *toggle = gtk_toggle_button_new_with_label("Formatted JSON");
        gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(toggle), GTK_TOGGLE_BUTTON(raw_button));
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), TRUE);
        g_signal_connect(toggle, "toggled", G_CALLBACK(toggle_json), viewer);
        gtk_box_append(GTK_BOX(toolbar), toggle);
    }
    GtkWidget *copy = gtk_button_new_with_label("Copy");
    gtk_widget_set_sensitive(copy, !is_null);
    g_signal_connect(copy, "clicked", G_CALLBACK(copy_value), viewer);
    gtk_box_append(GTK_BOX(toolbar), copy);
    GtkWidget *close = gtk_button_new_with_label("Close");
    g_signal_connect(close, "clicked", G_CALLBACK(close_viewer), window);
    gtk_box_append(GTK_BOX(toolbar), close);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), text);
    gtk_box_append(GTK_BOX(box), toolbar);
    gtk_box_append(GTK_BOX(box), scroll);
    gtk_window_set_child(GTK_WINDOW(window), box);
    g_object_set_data_full(G_OBJECT(window), "sdbui-value-viewer", viewer, viewer_free);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(viewer_key), window);
    gtk_widget_add_controller(window, keys);
    gtk_window_present(GTK_WINDOW(window));
}
