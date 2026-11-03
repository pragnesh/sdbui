#include "result_value.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

static GtkWidget *find_text_view(GtkWidget *widget);
static GtkWidget *find_shortcut_target(GtkWidget *widget, const char *name);

typedef struct {
    void *context;
    SDBUIValuePreview preview;
    SDBUIValueActivate activate;
    SDBUIValueDestroy destroy;
    SDBUIFilterPrepare filter_prepare;
    SDBUIFilterApply filter_apply;
    SDBUIValueDestroy filter_destroy;
    gboolean editable;
    SDBUIHeaderPrepare header_prepare;
    SDBUIHeaderApply header_apply;
    SDBUIValueDestroy header_destroy;
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

typedef struct { void *snapshot; SDBUIFilterApply apply; SDBUIValueDestroy destroy; GtkWidget *popover; } FilterAction;
static void filter_action_free(gpointer data) {
    FilterAction *action = data;
    if (action->destroy) action->destroy(action->snapshot);
    g_free(action);
}
typedef struct { GSimpleAction *action; GtkRoot *root; int command; } DeferredRowAction;
static gboolean apply_row_action(gpointer data) {
    DeferredRowAction *request = data;
    FilterAction *filter = g_object_get_data(G_OBJECT(request->action), "sdbui-cell-filter");
    if (request->root) {
        GtkWidget *target = find_shortcut_target(GTK_WIDGET(request->root), "editor");
        GtkWidget *editor = target ? find_text_view(target) : NULL;
        if (editor) gtk_widget_grab_focus(editor);
        else gtk_root_set_focus(request->root, NULL);
    }
    if (filter && filter->apply) filter->apply(filter->snapshot, request->command);
    return G_SOURCE_REMOVE;
}
static void free_row_action(gpointer data) {
    DeferredRowAction *request = data;
    g_object_unref(request->action);
    if (request->root) g_object_unref(request->root);
    g_free(request);
}
static void filter_action_activated(GSimpleAction *action, GVariant *parameter, gpointer data) {
    FilterAction *filter = data;
    int command = g_variant_get_int32(parameter);
    if (command == 3 || command == 4) {
        /* Let the backend's closed-menu idle unparent the popup before Swift
         * replaces its cell/grid with the row editor. Retain the snapshot. */
        DeferredRowAction *request = g_new0(DeferredRowAction, 1);
        request->action = g_object_ref(action); request->command = command;
        GtkRoot *root = gtk_widget_get_root(filter->popover);
        if (root) { request->root = g_object_ref(root); gtk_root_set_focus(root, NULL); }
        gtk_popover_popdown(GTK_POPOVER(filter->popover));
        g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, apply_row_action, request, free_row_action);
    } else if (filter->apply) filter->apply(filter->snapshot, command);
}
static gboolean release_filter_menu(gpointer data) {
    GtkWidget *popover = data;
    /* GTK can cache a closed menu. Drop captured values and actions promptly,
     * but only on idle, after the selected action has finished dispatching. */
    gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(popover), NULL);
    gtk_widget_insert_action_group(popover, "cellfilter", NULL);
    return G_SOURCE_REMOVE;
}
static void filter_menu_closed(GtkPopover *popover, gpointer data) {
    (void)data;
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, release_filter_menu, g_object_ref(popover), g_object_unref);
}
/* Extend the public menu before it is mapped: GTK otherwise keeps the old
 * visible page when replacing the model of an already-open popover. */
static void append_cell_filters(GtkWidget *cell, GtkWidget *popover) {
    ColumnSource *column = g_object_get_data(G_OBJECT(cell), "sdbui-value-cell");
    if (!column) return;
    guint position = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(cell), "sdbui-value-row"));
    ValueSource *source = g_object_get_data(G_OBJECT(column->grid), "sdbui-values");
    if (!position || !source || !source->filter_prepare || !GTK_IS_POPOVER_MENU(popover) ||
        g_object_get_data(G_OBJECT(popover), "sdbui-cell-filter")) return;
    void *snapshot = source->filter_prepare(source->context, position - 1, column->column);
    if (!snapshot) return;
    FilterAction *filter = g_new0(FilterAction, 1);
    filter->snapshot = snapshot; filter->apply = source->filter_apply; filter->destroy = source->filter_destroy; filter->popover = popover;
    GSimpleActionGroup *group = g_simple_action_group_new();
    GSimpleAction *action = g_simple_action_new("apply", G_VARIANT_TYPE_INT32);
    g_signal_connect(action, "activate", G_CALLBACK(filter_action_activated), filter);
    g_object_set_data_full(G_OBJECT(action), "sdbui-cell-filter", filter, filter_action_free);
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
    g_object_unref(action);
    gtk_widget_insert_action_group(popover, "cellfilter", G_ACTION_GROUP(group));
    g_object_unref(group);
    GMenu *combined = g_menu_new(), *commands = g_menu_new();
    GMenuModel *original = gtk_popover_menu_get_menu_model(GTK_POPOVER_MENU(popover));
    if (original) g_menu_append_section(combined, NULL, original);
    g_menu_append(commands, "=", "cellfilter.apply(0)");
    g_menu_append(commands, "!=", "cellfilter.apply(1)");
    g_menu_append(commands, "IS NULL", "cellfilter.apply(2)");
    g_menu_append_submenu(combined, "Filter by this value", G_MENU_MODEL(commands));
    if (source->editable) {
        g_menu_append(combined, "Edit row…", "cellfilter.apply(3)");
        g_menu_append(combined, "Delete row…", "cellfilter.apply(4)");
    }
    g_signal_connect(popover, "closed", G_CALLBACK(filter_menu_closed), NULL);
    gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(popover), G_MENU_MODEL(combined));
    g_object_set_data(G_OBJECT(popover), "sdbui-cell-filter", GINT_TO_POINTER(1));
    g_object_unref(commands); g_object_unref(combined);
}

typedef struct { GtkWidget *cell; GListModel *children; gulong handler; } PopoverWatch;
static void cell_children_changed(GListModel *children, guint position, guint removed, guint added, gpointer data) {
    (void)removed;
    for (guint index = position; index < position + added; index++) {
        GObject *child = g_list_model_get_item(children, index);
        if (GTK_IS_POPOVER_MENU(child)) append_cell_filters(GTK_WIDGET(data), GTK_WIDGET(child));
        g_object_unref(child);
    }
}
static void release_popover_watch(gpointer data) {
    PopoverWatch *watch = data;
    g_signal_handler_disconnect(watch->children, watch->handler);
    g_object_unref(watch->children); g_object_unref(watch->cell); g_free(watch);
}
static void watch_cell_popover(GtkGestureClick *gesture, gint presses, gdouble x, gdouble y, gpointer data) {
    (void)presses; (void)x; (void)y; (void)data;
    /* Observe only during one right-click dispatch, not on every recycled cell.
     * The backend parents its copy popover before calling gtk_popover_popup(). */
    PopoverWatch *watch = g_new0(PopoverWatch, 1);
    watch->cell = g_object_ref(gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture)));
    watch->children = gtk_widget_observe_children(watch->cell);
    watch->handler = g_signal_connect(watch->children, "items-changed", G_CALLBACK(cell_children_changed), watch->cell);
    g_idle_add_once(release_popover_watch, watch);
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
    GtkGesture *right = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(right), GDK_BUTTON_SECONDARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(right), GTK_PHASE_CAPTURE);
    g_signal_connect(right, "pressed", G_CALLBACK(watch_cell_popover), NULL);
    gtk_widget_add_controller(cell, GTK_EVENT_CONTROLLER(right));
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

void sdbui_value_editing(void *grid, int enabled) {
    ValueSource *source = g_object_get_data(G_OBJECT(grid), "sdbui-values");
    if (source) source->editable = enabled != 0;
}

void sdbui_value_filters(void *grid, SDBUIFilterPrepare prepare, SDBUIFilterApply apply, SDBUIValueDestroy destroy) {
    ValueSource *source = g_object_get_data(G_OBJECT(grid), "sdbui-values");
    if (!source) return;
    source->filter_prepare = prepare; source->filter_apply = apply; source->filter_destroy = destroy;
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
    case GDK_KEY_comma: return 13;
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
static void widget_font_size(GtkWidget *view, int size) {
    static guint next_id;
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
void sdbui_grid_font_size(void *grid, int size) {
    widget_font_size(find_column_view(GTK_WIDGET(grid)), size);
}
void sdbui_table_list_font_size(void *root, int size) {
    widget_font_size(GTK_WIDGET(root), size);
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

typedef struct {
    GtkStringList *names;
    GtkSingleSelection *selection;
    GtkWidget *list, *scroll;
    void *context;
    SDBUITableSelect select;
    SDBUIValueDestroy destroy;
    gboolean updating;
} TableList;
static void table_row_setup(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_label_set_single_line_mode(GTK_LABEL(label), TRUE);
    gtk_widget_set_margin_start(label, 8); gtk_widget_set_margin_end(label, 8);
    gtk_widget_set_margin_top(label, 4); gtk_widget_set_margin_bottom(label, 4);
    gtk_list_item_set_child(item, label);
}
static void table_row_bind(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory; (void)data;
    const char *name = gtk_string_object_get_string(GTK_STRING_OBJECT(gtk_list_item_get_item(item)));
    GtkWidget *label = gtk_list_item_get_child(item);
    gtk_label_set_text(GTK_LABEL(label), name);
    gtk_widget_set_tooltip_text(label, name);
}
static void table_selection_changed(GObject *selection, GParamSpec *property, gpointer data) {
    (void)property;
    TableList *list = data;
    guint index = gtk_single_selection_get_selected(GTK_SINGLE_SELECTION(selection));
    if (!list->updating && index != GTK_INVALID_LIST_POSITION && list->select) list->select(list->context, index);
}
static void table_list_free(gpointer data) {
    TableList *list = data;
    g_signal_handlers_disconnect_by_data(list->selection, list);
    g_object_unref(list->selection); g_object_unref(list->names);
    if (list->destroy) list->destroy(list->context);
    g_free(list);
}
void sdbui_table_list_install(void *root, void *context, SDBUITableSelect select, SDBUIValueDestroy destroy) {
    if (!GTK_IS_FIXED(root) || g_object_get_data(G_OBJECT(root), "sdbui-table-list")) { if (destroy) destroy(context); return; }
    TableList *list = g_new0(TableList, 1);
    list->context = context; list->select = select; list->destroy = destroy;
    list->names = gtk_string_list_new(NULL);
    list->selection = gtk_single_selection_new(G_LIST_MODEL(g_object_ref(list->names)));
    gtk_single_selection_set_autoselect(list->selection, FALSE);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(table_row_setup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(table_row_bind), NULL);
    list->list = gtk_list_view_new(GTK_SELECTION_MODEL(g_object_ref(list->selection)), factory);
    gtk_widget_add_css_class(list->list, "navigation-sidebar");
    gtk_accessible_update_property(GTK_ACCESSIBLE(list->list), GTK_ACCESSIBLE_PROPERTY_LABEL, "Tables", -1);
    list->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(list->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list->scroll), list->list);
    gtk_fixed_put(GTK_FIXED(root), list->scroll, 0, 0);
    g_signal_connect(list->selection, "notify::selected", G_CALLBACK(table_selection_changed), list);
    g_object_set_data_full(G_OBJECT(root), "sdbui-table-list", list, table_list_free);
}
void *sdbui_table_list_context(void *root) {
    TableList *list = g_object_get_data(G_OBJECT(root), "sdbui-table-list");
    return list ? list->context : NULL;
}
void sdbui_table_list_update(void *root, const char *const *labels, int replace, uint32_t selected, int width, int height) {
    TableList *list = g_object_get_data(G_OBJECT(root), "sdbui-table-list");
    if (!list) return;
    guint old = gtk_single_selection_get_selected(list->selection);
    list->updating = TRUE;
    if (replace) gtk_string_list_splice(list->names, 0, g_list_model_get_n_items(G_LIST_MODEL(list->names)), labels);
    if (selected >= g_list_model_get_n_items(G_LIST_MODEL(list->names))) selected = GTK_INVALID_LIST_POSITION;
    gtk_single_selection_set_selected(list->selection, selected);
    list->updating = FALSE;
    gtk_widget_set_size_request(list->scroll, MAX(width, 0), MAX(height, 0));
    if (selected != GTK_INVALID_LIST_POSITION && (replace || selected != old)) {
#if GTK_CHECK_VERSION(4, 12, 0)
        gtk_list_view_scroll_to(GTK_LIST_VIEW(list->list), selected, GTK_LIST_SCROLL_NONE, NULL);
#else
        gtk_widget_activate_action(list->list, "list.scroll-to-item", "u", selected);
#endif
    }
}

/* Header actions use snapshots just like cell filters, so an open menu cannot
 * act on a newly loaded result or a different column projection. */
void sdbui_grid_header_filter_enabled(void *grid, int enabled) {
    g_object_set_data(G_OBJECT(grid), "sdbui-header-filter", GINT_TO_POINTER(enabled));
}
typedef struct { void *snapshot; SDBUIHeaderApply apply; SDBUIValueDestroy destroy; GtkWidget *grid; GtkWidget *popover; } HeaderAction;
static void header_action_free(gpointer data) {
    HeaderAction *action = data;
    if (action->destroy) action->destroy(action->snapshot);
    g_object_unref(action->grid);
    g_free(action);
}
static void header_activated(GSimpleAction *action, GVariant *parameter, gpointer data) {
    /* Changing the projection may destroy this view on the next model update.
     * Detach its popup before invoking Swift, while retaining the action's
     * snapshot until dispatch completes. */
    g_object_ref(action);
    HeaderAction *target = data;
    gtk_popover_popdown(GTK_POPOVER(target->popover));
    if (gtk_widget_get_parent(target->popover)) gtk_widget_unparent(target->popover);
    char *text = target->apply(target->snapshot, g_variant_get_int32(parameter));
    if (text) { gdk_clipboard_set_text(gtk_widget_get_clipboard(target->grid), text); free(text); }
    g_object_unref(action);
}
static gboolean unparent_header(gpointer data) {
    GtkWidget *popover = data;
    gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(popover), NULL);
    gtk_widget_insert_action_group(popover, "header", NULL);
    if (gtk_widget_get_parent(popover)) gtk_widget_unparent(popover);
    return G_SOURCE_REMOVE;
}
static void header_closed(GtkPopover *popover, gpointer data) {
    (void)data;
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, unparent_header, g_object_ref(popover), g_object_unref);
}
static void header_pressed(GtkGestureClick *gesture, gint presses, gdouble x, gdouble y, gpointer data) {
    (void)presses;
    GtkWidget *grid = data;
    GtkWidget *view = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GtkWidget *hit = gtk_widget_pick(view, x, y, GTK_PICK_DEFAULT);
    /* GTK's public widget tree exposes the header's title buttons in column order. */
    GtkWidget *title = hit;
    while (title && gtk_widget_get_parent(title) &&
           strcmp(gtk_widget_get_css_name(gtk_widget_get_parent(title)), "header") != 0) {
        title = gtk_widget_get_parent(title);
    }
    if (!title || !gtk_widget_get_parent(title)) return;
    guint column = 0;
    for (GtkWidget *sibling = gtk_widget_get_first_child(gtk_widget_get_parent(title)); sibling && sibling != title;
         sibling = gtk_widget_get_next_sibling(sibling)) column++;
    ValueSource *source = g_object_get_data(G_OBJECT(grid), "sdbui-values");
    if (!source || !source->header_prepare) return;
    void *snapshot = source->header_prepare(source->context, column);
    if (!snapshot) return;
    HeaderAction *target = g_new0(HeaderAction, 1);
    target->snapshot = snapshot; target->apply = source->header_apply;
    target->destroy = source->header_destroy; target->grid = g_object_ref(grid);
    GSimpleActionGroup *group = g_simple_action_group_new();
    GSimpleAction *action = g_simple_action_new("apply", G_VARIANT_TYPE_INT32);
    g_signal_connect(action, "activate", G_CALLBACK(header_activated), target);
    g_object_set_data_full(G_OBJECT(action), "sdbui-header-target", target, header_action_free);
    g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(action));
    g_object_unref(action);
    GMenu *menu = g_menu_new();
    const char *names[] = { "Sort ascending", "Sort descending", "Copy column name", "Copy column values (loaded rows)",
        "Hide column", "Auto-fit width (loaded rows)", "Freeze through this column", "Unfreeze columns", "Show all columns", "Filter column…" };
    for (guint index = 0; index < G_N_ELEMENTS(names); index++) {
        if (index == 9 && !g_object_get_data(G_OBJECT(grid), "sdbui-header-filter")) continue;
        GMenuItem *item = g_menu_item_new(names[index], NULL);
        g_menu_item_set_action_and_target(item, "header.apply", "i", (gint)index);
        g_menu_append_item(menu, item); g_object_unref(item);
    }
    GtkWidget *popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    target->popover = popover;
    g_object_unref(menu);
    gtk_widget_insert_action_group(popover, "header", G_ACTION_GROUP(group)); g_object_unref(group);
    gtk_widget_set_parent(popover, view);
    GdkRectangle rect = { (int)x, (int)y, 1, 1 };
    gtk_popover_set_pointing_to(GTK_POPOVER(popover), &rect);
    g_signal_connect(popover, "closed", G_CALLBACK(header_closed), NULL);
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    gtk_popover_popup(GTK_POPOVER(popover));
}
void sdbui_grid_headers(void *grid, SDBUIHeaderPrepare prepare, SDBUIHeaderApply apply, SDBUIValueDestroy destroy) {
    ValueSource *source = g_object_get_data(G_OBJECT(grid), "sdbui-values");
    if (!source) return;
    source->header_prepare = prepare; source->header_apply = apply; source->header_destroy = destroy;
    GtkWidget *view = find_column_view(grid);
    if (!view || g_object_get_data(G_OBJECT(view), "sdbui-header-gesture")) return;
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), GDK_BUTTON_SECONDARY);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
    g_signal_connect(gesture, "pressed", G_CALLBACK(header_pressed), grid);
    gtk_widget_add_controller(view, GTK_EVENT_CONTROLLER(gesture));
    g_object_set_data(G_OBJECT(view), "sdbui-header-gesture", GINT_TO_POINTER(1));
}

/* Two virtual grids keep their own lazy models and copy state, but mirror
 * selection and vertical adjustments. Horizontal scrolling stays independent. */
typedef struct { GtkAdjustment *left, *right; GtkSelectionModel *a, *b; gboolean updating; } GridPair;
static void pair_free(gpointer data) {
    GridPair *pair = data;
    g_signal_handlers_disconnect_by_data(pair->left, pair);
    g_signal_handlers_disconnect_by_data(pair->right, pair);
    g_signal_handlers_disconnect_by_data(pair->a, pair);
    g_signal_handlers_disconnect_by_data(pair->b, pair);
    g_object_unref(pair->left); g_object_unref(pair->right);
    g_object_unref(pair->a); g_object_unref(pair->b); g_free(pair);
}
static void pair_scroll(GtkAdjustment *source, gpointer data) {
    GridPair *pair = data;
    if (pair->updating) return;
    pair->updating = TRUE;
    gtk_adjustment_set_value(source == pair->left ? pair->right : pair->left, gtk_adjustment_get_value(source));
    pair->updating = FALSE;
}
static void pair_selection(GtkSelectionModel *source, guint position, guint count, gpointer data) {
    (void)position; (void)count;
    GridPair *pair = data;
    if (pair->updating) return;
    pair->updating = TRUE;
    GtkSelectionModel *target = source == pair->a ? pair->b : pair->a;
    GtkBitset *selected = gtk_selection_model_get_selection(source);
    GtkBitset *mask = gtk_bitset_new_range(0, g_list_model_get_n_items(G_LIST_MODEL(target)));
    gtk_selection_model_set_selection(target, selected, mask);
    gtk_bitset_unref(selected); gtk_bitset_unref(mask);
    pair->updating = FALSE;
}
static void find_grids(GtkWidget *root, GtkWidget **left, GtkWidget **right) {
    if (g_object_get_data(G_OBJECT(root), "sdbui-values")) {
        if (!*left) *left = root; else if (!*right) *right = root;
        return;
    }
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) find_grids(child, left, right);
}
static GtkWidget *grid_header(GtkWidget *root) {
    if (strcmp(gtk_widget_get_css_name(root), "header") == 0) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = grid_header(child);
        if (found) return found;
    }
    return NULL;
}
void sdbui_grid_pair(void *root) {
    GtkWidget *left = NULL, *right = NULL;
    find_grids(root, &left, &right);
    if (!left || !right || !GTK_IS_SCROLLED_WINDOW(left) || !GTK_IS_SCROLLED_WINDOW(right)) return;
    GtkWidget *a = find_column_view(left), *b = find_column_view(right);
    if (!a || !b) return;
    GtkWidget *ha = grid_header(a), *hb = grid_header(b);
    if (ha && hb) {
        int minimum, height_a, height_b;
        gtk_widget_set_size_request(ha, -1, -1);
        gtk_widget_set_size_request(hb, -1, -1);
        gtk_widget_measure(ha, GTK_ORIENTATION_VERTICAL, -1, &minimum, &height_a, NULL, NULL);
        gtk_widget_measure(hb, GTK_ORIENTATION_VERTICAL, -1, &minimum, &height_b, NULL, NULL);
        gtk_widget_set_size_request(ha, -1, MAX(height_a, height_b));
        gtk_widget_set_size_request(hb, -1, MAX(height_a, height_b));
    }
    GridPair *previous = g_object_get_data(G_OBJECT(root), "sdbui-grid-pair");
    GtkSelectionModel *ma = gtk_column_view_get_model(GTK_COLUMN_VIEW(a)), *mb = gtk_column_view_get_model(GTK_COLUMN_VIEW(b));
    if (previous && previous->a == ma && previous->b == mb) return;
    GridPair *pair = g_new0(GridPair, 1);
    pair->left = g_object_ref(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(left)));
    pair->right = g_object_ref(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(right)));
    pair->a = g_object_ref(ma); pair->b = g_object_ref(mb);
    g_object_set_data_full(G_OBJECT(root), "sdbui-grid-pair", pair, pair_free);
    g_signal_connect(pair->left, "value-changed", G_CALLBACK(pair_scroll), pair);
    g_signal_connect(pair->right, "value-changed", G_CALLBACK(pair_scroll), pair);
    g_signal_connect(pair->a, "selection-changed", G_CALLBACK(pair_selection), pair);
    g_signal_connect(pair->b, "selection-changed", G_CALLBACK(pair_selection), pair);
    /* Reserve matching scrollbar space, even when only one side is wide. */
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(left), GTK_POLICY_ALWAYS, GTK_POLICY_EXTERNAL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(right), GTK_POLICY_ALWAYS, GTK_POLICY_ALWAYS);
    pair_scroll(pair->right, pair);
    pair_selection(pair->b, 0, 0, pair);
}

/* Keep menu state alive through dismissal and dispatch outside the popover's
 * action group, so a Swift redraw cannot destroy an executing menu action. */
typedef struct {
    int refs;
    char **labels;
    int *enabled;
    guint count;
    void *context;
    SDBUIFilterApply apply;
    SDBUIValueDestroy destroy;
} CommandMenuSource;
typedef struct { CommandMenuSource *source; GtkWidget *popover; guint index; } CommandMenuAction;
static void command_source_unref(gpointer data) {
    CommandMenuSource *source = data;
    if (--source->refs) return;
    if (source->destroy) source->destroy(source->context);
    g_strfreev(source->labels); g_free(source->enabled); g_free(source);
}
static void command_action_free(gpointer data) {
    CommandMenuAction *action = data;
    command_source_unref(action->source); g_free(action);
}
static gboolean command_dispatch(gpointer data) {
    CommandMenuAction *action = data;
    action->source->apply(action->source->context, (int32_t)action->index);
    return G_SOURCE_REMOVE;
}
static gboolean command_unparent(gpointer data) {
    GtkWidget *popover = data;
    gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(popover), NULL);
    gtk_widget_insert_action_group(popover, "commands", NULL);
    if (gtk_widget_get_parent(popover)) gtk_widget_unparent(popover);
    return G_SOURCE_REMOVE;
}
static void command_closed(GtkPopover *popover, gpointer data) {
    (void)data;
    GtkWidget *button = gtk_widget_get_parent(GTK_WIDGET(popover));
    if (button && g_object_get_data(G_OBJECT(button), "sdbui-command-popover") == popover)
        g_object_set_data(G_OBJECT(button), "sdbui-command-popover", NULL);
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, command_unparent, g_object_ref(popover), g_object_unref);
}
static void command_activated(GSimpleAction *simple, GVariant *parameter, gpointer data) {
    (void)simple; (void)parameter;
    CommandMenuAction *action = data;
    CommandMenuAction *pending = g_new0(CommandMenuAction, 1);
    pending->source = action->source; pending->source->refs++;
    pending->index = action->index;
    gtk_popover_popdown(GTK_POPOVER(action->popover));
    /* Queue cleanup first, then run Swift on the next main-loop turn. */
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, command_dispatch, pending, command_action_free);
}
static void command_menu_clicked(GtkButton *button, gpointer data) {
    (void)data;
    CommandMenuSource *source = g_object_get_data(G_OBJECT(button), "sdbui-commands");
    if (!source) return;
    GtkWidget *existing = g_object_get_data(G_OBJECT(button), "sdbui-command-popover");
    if (existing) { gtk_popover_popdown(GTK_POPOVER(existing)); return; }
    GMenu *menu = g_menu_new();
    GSimpleActionGroup *group = g_simple_action_group_new();
    GtkWidget *popover = gtk_popover_menu_new_from_model(NULL);
    for (guint i = 0; i < source->count; i++) {
        char *name = g_strdup_printf("item%u", i);
        char *detailed = g_strdup_printf("commands.%s", name);
        GSimpleAction *simple = g_simple_action_new(name, NULL);
        CommandMenuAction *action = g_new0(CommandMenuAction, 1);
        action->source = source; source->refs++; action->popover = popover; action->index = i;
        g_signal_connect(simple, "activate", G_CALLBACK(command_activated), action);
        g_object_set_data_full(G_OBJECT(simple), "sdbui-command", action, command_action_free);
        g_simple_action_set_enabled(simple, source->enabled[i]);
        g_action_map_add_action(G_ACTION_MAP(group), G_ACTION(simple));
        g_menu_append(menu, source->labels[i], detailed);
        g_object_unref(simple); g_free(name); g_free(detailed);
    }
    gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(popover), G_MENU_MODEL(menu));
    gtk_widget_insert_action_group(popover, "commands", G_ACTION_GROUP(group));
    g_object_unref(menu); g_object_unref(group);
    gtk_widget_set_parent(popover, GTK_WIDGET(button));
    g_object_set_data(G_OBJECT(button), "sdbui-command-popover", popover);
    gtk_popover_set_position(GTK_POPOVER(popover), GTK_POS_BOTTOM);
    g_signal_connect(popover, "closed", G_CALLBACK(command_closed), NULL);
    gtk_popover_popup(GTK_POPOVER(popover));
}
static GtkWidget *command_find_button(GtkWidget *root) {
    if (GTK_IS_BUTTON(root)) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *button = command_find_button(child);
        if (button) return button;
    }
    return NULL;
}
void sdbui_command_menu(void *root, const char *const *labels, const int32_t *enabled, uint32_t count,
                        void *context, SDBUIFilterApply apply, SDBUIValueDestroy destroy) {
    GtkWidget *button = command_find_button(GTK_WIDGET(root));
    if (!button) { if (destroy) destroy(context); return; }
    if (!g_object_get_data(G_OBJECT(button), "sdbui-commands"))
        g_signal_connect(button, "clicked", G_CALLBACK(command_menu_clicked), NULL);
    CommandMenuSource *source = g_new0(CommandMenuSource, 1);
    source->refs = 1; source->count = count; source->context = context; source->apply = apply; source->destroy = destroy;
    source->labels = g_new0(char *, count + 1); source->enabled = g_new(int, count);
    for (guint i = 0; i < count; i++) { source->labels[i] = g_strdup(labels[i]); source->enabled[i] = enabled[i]; }
    g_object_set_data_full(G_OBJECT(button), "sdbui-commands", source, command_source_unref);
}
