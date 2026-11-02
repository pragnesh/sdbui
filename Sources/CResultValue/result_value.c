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

static GtkWidget *find_text_view(GtkWidget *widget) {
    if (GTK_IS_TEXT_VIEW(widget)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_text_view(child);
        if (found) return found;
    }
    return NULL;
}

int sdbui_editor_reveal(void *editor, int offset) {
    GtkWidget *text = find_text_view(GTK_WIDGET(editor));
    if (!text) return 0;
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(text));
    if (offset < 0 || offset > gtk_text_buffer_get_char_count(buffer)) return 0;
    GtkTextIter iter;
    gtk_text_buffer_get_iter_at_offset(buffer, &iter, offset);
    gtk_text_buffer_place_cursor(buffer, &iter);
    gtk_text_view_scroll_to_iter(GTK_TEXT_VIEW(text), &iter, 0.15, FALSE, 0, 0);
    /* A background connection must not take focus from the visible tab. */
    if (gtk_widget_get_mapped(text)) gtk_widget_grab_focus(text);
    return 1;
}

/* Application shortcuts are captured before text widgets consume Ctrl+Tab,
 * Ctrl+L, etc. Unknown combinations continue to the focused widget. */
int32_t sdbui_shortcut_command(uint32_t keyval, uint32_t modifiers) {
    guint key = gdk_keyval_to_lower(keyval);
    guint mods = modifiers & (GDK_CONTROL_MASK | GDK_SHIFT_MASK | GDK_ALT_MASK | GDK_SUPER_MASK | GDK_META_MASK);
    if (!mods) {
        if (key == GDK_KEY_Escape) return 7;
        if (key == GDK_KEY_F5) return 8;
        return 0;
    }
    if (!(mods & GDK_CONTROL_MASK) || (mods & (GDK_ALT_MASK | GDK_SUPER_MASK | GDK_META_MASK))) return 0;
    if (key == GDK_KEY_Tab || key == GDK_KEY_ISO_Left_Tab) return (mods & GDK_SHIFT_MASK) || key == GDK_KEY_ISO_Left_Tab ? 4 : 3;
    if (key == GDK_KEY_plus || key == GDK_KEY_equal || key == GDK_KEY_KP_Add) return 11;
    if (key == GDK_KEY_minus || key == GDK_KEY_KP_Subtract) return 12;
    if (mods & GDK_SHIFT_MASK) return 0;
    if (key >= GDK_KEY_1 && key <= GDK_KEY_9) return 101 + (int32_t)(key - GDK_KEY_1);
    switch (key) {
    case GDK_KEY_t: return 1;
    case GDK_KEY_w: return 2;
    case GDK_KEY_p: case GDK_KEY_f: return 5;
    case GDK_KEY_l: return 6;
    case GDK_KEY_Page_Up: case GDK_KEY_KP_Page_Up: return 9;
    case GDK_KEY_Page_Down: case GDK_KEY_KP_Page_Down: return 10;
    default: return 0;
    }
}

void sdbui_shortcut_target(void *widget, const char *name) {
    g_object_set_data_full(G_OBJECT(widget), "sdbui-shortcut-target", g_strdup(name), g_free);
}

static GtkWidget *find_shortcut_target(GtkWidget *widget, const char *name) {
    if (!gtk_widget_get_mapped(widget)) return NULL;
    if (g_strcmp0(g_object_get_data(G_OBJECT(widget), "sdbui-shortcut-target"), name) == 0) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_shortcut_target(child, name);
        if (found) return found;
    }
    return NULL;
}

typedef struct { GWeakRef root; const char *target; int attempts; } ShortcutFocus;
static gboolean focus_shortcut_target(gpointer data) {
    ShortcutFocus *request = data;
    GtkWidget *root = g_weak_ref_get(&request->root);
    if (!root) return G_SOURCE_REMOVE;
    GtkWidget *target = find_shortcut_target(root, request->target);
    gboolean focused = FALSE;
    if (target) {
        GtkWidget *text = find_text_view(target);
        focused = gtk_widget_grab_focus(text ? text : target);
        if (focused && GTK_IS_EDITABLE(target)) gtk_editable_select_region(GTK_EDITABLE(target), 0, -1);
    }
    g_object_unref(root);
    return !focused && ++request->attempts < 10 ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}
static void free_shortcut_focus(gpointer data) {
    ShortcutFocus *request = data;
    g_weak_ref_clear(&request->root);
    g_free(request);
}

typedef struct { void *context; SDBUIShortcutAction action; SDBUIValueDestroy destroy; } Shortcuts;
static void free_shortcuts(gpointer data) {
    Shortcuts *shortcuts = data;
    if (shortcuts->destroy) shortcuts->destroy(shortcuts->context);
    g_free(shortcuts);
}
static gboolean shortcut_key(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType modifiers, gpointer data) {
    (void)code;
    Shortcuts *shortcuts = data;
    int32_t command = sdbui_shortcut_command(key, modifiers);
    if (!command || !shortcuts->action || !shortcuts->action(shortcuts->context, command)) return FALSE;
    if (command == 5 || command == 6) {
        ShortcutFocus *request = g_new0(ShortcutFocus, 1);
        g_weak_ref_init(&request->root, gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller)));
        request->target = command == 5 ? "table-filter" : "editor";
        /* Allow a Query tab selected by Ctrl+L to finish creating its editor. */
        g_timeout_add_full(G_PRIORITY_DEFAULT, 16, focus_shortcut_target, request, free_shortcut_focus);
    }
    return TRUE;
}
void sdbui_shortcuts_install(void *root, void *context, SDBUIShortcutAction action, SDBUIValueDestroy destroy) {
    if (g_object_get_data(G_OBJECT(root), "sdbui-shortcuts")) {
        if (destroy) destroy(context);
        return;
    }
    Shortcuts *shortcuts = g_new0(Shortcuts, 1);
    shortcuts->context = context; shortcuts->action = action; shortcuts->destroy = destroy;
    g_object_set_data_full(G_OBJECT(root), "sdbui-shortcuts", shortcuts, free_shortcuts);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(shortcut_key), shortcuts);
    gtk_widget_add_controller(GTK_WIDGET(root), keys);
}

/* Scope the provider to one grid and remove it with that grid. */
typedef struct { GdkDisplay *display; GtkCssProvider *provider; char *name; int size; } GridFont;
static void free_grid_font(gpointer data) {
    GridFont *font = data;
    gtk_style_context_remove_provider_for_display(font->display, GTK_STYLE_PROVIDER(font->provider));
    g_object_unref(font->display); g_object_unref(font->provider);
    g_free(font->name); g_free(font);
}
void sdbui_grid_font_size(void *grid, int size) {
    static guint next_id;
    GtkWidget *view = find_column_view(GTK_WIDGET(grid));
    if (!view || size < 9 || size > 28) return;
    GridFont *font = g_object_get_data(G_OBJECT(view), "sdbui-grid-font");
    if (font && font->size == size) return;
    if (!font) {
        font = g_new0(GridFont, 1);
        font->provider = gtk_css_provider_new();
        font->display = g_object_ref(gtk_widget_get_display(view));
        font->name = g_strdup_printf("sdbui-grid-font-%u", ++next_id);
        gtk_widget_add_css_class(view, font->name);
        gtk_style_context_add_provider_for_display(font->display, GTK_STYLE_PROVIDER(font->provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        g_object_set_data_full(G_OBJECT(view), "sdbui-grid-font", font, free_grid_font);
    }
    char *css = g_strdup_printf(".%s, .%s * { font-size: %dpx; }", font->name, font->name, size);
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(font->provider, css);
#else
    gtk_css_provider_load_from_data(font->provider, css, -1);
#endif
    g_free(css);
    font->size = size;
}

typedef struct { void *context; SDBUILayoutChange changed; SDBUIValueDestroy destroy; int width, height; } SessionLayout;
static void free_session_layout(gpointer data) {
    SessionLayout *layout = data;
    if (layout->destroy) layout->destroy(layout->context);
    g_free(layout);
}
static void capture_window_layout(GtkWidget *root, SessionLayout *layout, int final) {
    GtkRoot *window = gtk_widget_get_root(root);
    if (GTK_IS_WINDOW(window) && !gtk_window_is_maximized(GTK_WINDOW(window)) && !gtk_window_is_fullscreen(GTK_WINDOW(window))) {
        int width = gtk_widget_get_width(GTK_WIDGET(window)), height = gtk_widget_get_height(GTK_WIDGET(window));
        if (width >= 640 && height >= 400 && (final || width != layout->width || height != layout->height)) {
            layout->width = width; layout->height = height;
            layout->changed(layout->context, width, height, final);
            return;
        }
    }
    if (final) layout->changed(layout->context, layout->width, layout->height, 1);
}
static gboolean session_window_tick(GtkWidget *root, GdkFrameClock *clock, gpointer data) {
    (void)clock;
    capture_window_layout(root, data, 0);
    return G_SOURCE_CONTINUE;
}
static void session_window_unmap(GtkWidget *root, gpointer data) { capture_window_layout(root, data, 1); }
void sdbui_session_window(void *root, void *context, SDBUILayoutChange changed, SDBUIValueDestroy destroy) {
    if (g_object_get_data(G_OBJECT(root), "sdbui-session-window")) { if (destroy) destroy(context); return; }
    SessionLayout *layout = g_new0(SessionLayout, 1);
    layout->context = context; layout->changed = changed; layout->destroy = destroy;
    g_object_set_data_full(G_OBJECT(root), "sdbui-session-window", layout, free_session_layout);
    gtk_widget_add_tick_callback(GTK_WIDGET(root), session_window_tick, layout, NULL);
    g_signal_connect(root, "unmap", G_CALLBACK(session_window_unmap), layout);
}
static void sidebar_position(GtkPaned *paned, GParamSpec *property, gpointer data) {
    (void)property;
    SessionLayout *layout = data;
    if (gtk_widget_get_mapped(GTK_WIDGET(paned))) {
        int width = gtk_paned_get_position(paned);
        if (width >= 180 && width != layout->width) {
            layout->width = width;
            layout->changed(layout->context, width, 0, 0);
        }
    }
}
static void sidebar_map(GtkWidget *paned, gpointer data) {
    SessionLayout *layout = data;
    gtk_paned_set_position(GTK_PANED(paned), layout->width);
}
void sdbui_session_sidebar(void *paned, int width, void *context, SDBUILayoutChange changed, SDBUIValueDestroy destroy) {
    if (!GTK_IS_PANED(paned) || g_object_get_data(G_OBJECT(paned), "sdbui-session-sidebar")) { if (destroy) destroy(context); return; }
    SessionLayout *layout = g_new0(SessionLayout, 1);
    layout->context = context; layout->changed = changed; layout->destroy = destroy;
    layout->width = CLAMP(width, 180, 4000);
    g_object_set_data_full(G_OBJECT(paned), "sdbui-session-sidebar", layout, free_session_layout);
    gtk_paned_set_position(GTK_PANED(paned), layout->width);
    g_signal_connect(paned, "notify::position", G_CALLBACK(sidebar_position), layout);
    g_signal_connect(paned, "map", G_CALLBACK(sidebar_map), layout);
}
