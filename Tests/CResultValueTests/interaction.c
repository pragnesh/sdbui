#include "result_value.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>

static GMainLoop *loop;
static GtkWidget *grid;
static int previews, activations;
static void settle_layout(void);
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
static guint filter_prepared, filter_applied, filter_destroyed;
static gboolean filter_enabled = TRUE;
static void *prepare_cell_filter(void *context, uint32_t row, uint32_t column) {
    (void)context;
    g_assert_cmpuint(row, ==, 0); g_assert_cmpuint(column, ==, 0);
    if (!filter_enabled) return NULL;
    filter_prepared++;
    int *snapshot = g_new(int, 1); *snapshot = 42;
    return snapshot;
}
static void apply_cell_filter(void *snapshot, int32_t command) {
    g_assert_cmpint(*(int *)snapshot, ==, 42);
    g_assert_cmpint(command, ==, 1);
    filter_applied++;
}
static void destroy_cell_filter(void *snapshot) { filter_destroyed++; g_free(snapshot); }
static void copy_popup(GtkGestureClick *gesture, gint count, gdouble x, gdouble y, gpointer data) {
    (void)count; (void)x; (void)y; (void)data;
    GtkWidget *cell = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(gesture));
    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Copy Cell", "copy.cell");
    GtkWidget *popover = gtk_popover_menu_new_from_model(G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_widget_set_parent(popover, cell);
    gtk_popover_popup(GTK_POPOVER(popover));
}

static guint header_prepared, header_applied, header_destroyed;
static void *prepare_header(void *context, uint32_t column) {
    (void)context;
    g_assert_cmpuint(column, ==, 0);
    header_prepared++;
    return g_strdup("header snapshot");
}
static char *apply_header(void *snapshot, int32_t command) {
    g_assert_cmpstr(snapshot, ==, "header snapshot");
    g_assert_cmpint(command, ==, 2);
    header_applied++;
    return strdup("Value");
}
static void destroy_header(void *snapshot) { header_destroyed++; g_free(snapshot); }
static GtkWidget *find_css(GtkWidget *root, const char *name) {
    if (strcmp(gtk_widget_get_css_name(root), name) == 0) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = find_css(child, name);
        if (found) return found;
    }
    return NULL;
}
static void test_header_menu(void) {
    GtkWidget *view = find(grid, GTK_TYPE_COLUMN_VIEW);
    GtkWidget *header = find_css(view, "header");
    g_assert_nonnull(header);
    GtkWidget *title = gtk_widget_get_first_child(header);
    g_assert_nonnull(title);
    graphene_rect_t bounds;
    g_assert_true(gtk_widget_compute_bounds(title, view, &bounds));
    GListModel *controllers = gtk_widget_observe_controllers(view);
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GObject *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_GESTURE_CLICK(controller) && gtk_gesture_single_get_button(GTK_GESTURE_SINGLE(controller)) == GDK_BUTTON_SECONDARY) {
            g_signal_emit_by_name(controller, "pressed", 1, bounds.origin.x + 10.0, bounds.origin.y + 10.0);
        }
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    GtkWidget *popover = find(view, GTK_TYPE_POPOVER_MENU);
    g_assert_nonnull(popover);
    GMenuModel *menu = gtk_popover_menu_get_menu_model(GTK_POPOVER_MENU(popover));
    g_assert_cmpint(g_menu_model_get_n_items(menu), ==, 9);
    g_assert_cmpuint(header_prepared, ==, 1);
    g_assert_true(gtk_widget_activate_action(popover, "header.apply", "i", 2));
    g_assert_cmpuint(header_applied, ==, 1);
    gtk_popover_popdown(GTK_POPOVER(popover));
    settle_layout();
    g_assert_cmpuint(header_destroyed, ==, 1);
}

static void test_frozen_grids(void) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    g_object_ref_sink(box);
    GtkWidget *grids[2];
    GtkSelectionModel *models[2];
    for (int i = 0; i < 2; i++) {
        GtkStringList *rows = gtk_string_list_new(NULL);
        for (int j = 0; j < 100; j++) gtk_string_list_append(rows, "row");
        models[i] = GTK_SELECTION_MODEL(gtk_multi_selection_new(G_LIST_MODEL(rows)));
        GtkWidget *view = gtk_column_view_new(models[i]);
        grids[i] = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(grids[i]), view);
        sdbui_value_install(grids[i], NULL, NULL, NULL, NULL);
        gtk_box_append(GTK_BOX(box), grids[i]);
    }
    sdbui_grid_pair(box);
    sdbui_grid_pair(box); // Repeated updates must not duplicate signal handlers.
    gtk_selection_model_select_item(models[0], 17, TRUE);
    g_assert_true(gtk_selection_model_is_selected(models[1], 17));
    gtk_selection_model_select_range(models[1], 20, 5, FALSE);
    for (guint row = 20; row < 25; row++) g_assert_true(gtk_selection_model_is_selected(models[0], row));
    GtkAdjustment *a = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(grids[0]));
    GtkAdjustment *b = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(grids[1]));
    gtk_adjustment_configure(a, 0, 0, 1000, 10, 100, 100);
    gtk_adjustment_configure(b, 0, 0, 1000, 10, 100, 100);
    gtk_adjustment_set_value(a, 250);
    g_assert_cmpfloat(gtk_adjustment_get_value(b), ==, 250);
    gtk_adjustment_set_value(b, 500);
    g_assert_cmpfloat(gtk_adjustment_get_value(a), ==, 500);
    GtkAdjustment *h1 = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(grids[0]));
    GtkAdjustment *h2 = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(grids[1]));
    gtk_adjustment_configure(h1, 0, 0, 1000, 10, 100, 100);
    gtk_adjustment_configure(h2, 0, 0, 1000, 10, 100, 100);
    gtk_adjustment_set_value(h2, 300);
    g_assert_cmpfloat(gtk_adjustment_get_value(h1), ==, 0);
    g_object_unref(box);
}

static void setup(GtkSignalListItemFactory *factory, GObject *object, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *cell = gtk_inscription_new(NULL);
    gtk_list_item_set_child(GTK_LIST_ITEM(object), cell);
    GtkGesture *right = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(right), GDK_BUTTON_SECONDARY);
    g_signal_connect(right, "pressed", G_CALLBACK(copy_popup), NULL);
    gtk_widget_add_controller(cell, GTK_EVENT_CONTROLLER(right));
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
    GtkWidget *font_view = find(grid, GTK_TYPE_COLUMN_VIEW);
    GtkWidget *font_cell = find(grid, GTK_TYPE_INSCRIPTION);
    g_assert_nonnull(font_view);
    g_assert_nonnull(font_cell);
    const PangoFontDescription *font = pango_context_get_font_description(gtk_widget_get_pango_context(font_cell));
    /* The local CSS font must reach actual recycled cell widgets. */
    g_assert_cmpint(pango_font_description_get_size(font), ==, 20 * PANGO_SCALE);
    (void)data;
    test_header_menu();
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
    GListModel *right_controllers = gtk_widget_observe_controllers(cell);
    for (int phase = 0; phase < 2; phase++) {
        for (guint i = 0; i < g_list_model_get_n_items(right_controllers); i++) {
            GObject *controller = g_list_model_get_item(right_controllers, i);
            gboolean capture = gtk_event_controller_get_propagation_phase(GTK_EVENT_CONTROLLER(controller)) == GTK_PHASE_CAPTURE;
            if (GTK_IS_GESTURE_CLICK(controller) && capture == (phase == 0) &&
                gtk_gesture_single_get_button(GTK_GESTURE_SINGLE(controller)) == GDK_BUTTON_SECONDARY) {
                g_signal_emit_by_name(controller, "pressed", 1, 1.0, 1.0);
            }
            g_object_unref(controller);
        }
    }
    g_object_unref(right_controllers);
    GtkWidget *popover = find(cell, GTK_TYPE_POPOVER_MENU);
    g_assert_nonnull(popover);
    GMenuModel *menu = gtk_popover_menu_get_menu_model(GTK_POPOVER_MENU(popover));
    g_assert_cmpint(g_menu_model_get_n_items(menu), ==, 2);
    GMenuModel *copy = g_menu_model_get_item_link(menu, 0, G_MENU_LINK_SECTION);
    char *title = NULL;
    g_assert_true(g_menu_model_get_item_attribute(copy, 0, G_MENU_ATTRIBUTE_LABEL, "s", &title));
    g_assert_cmpstr(title, ==, "Copy Cell"); g_free(title); g_object_unref(copy);
    GMenuModel *filters = g_menu_model_get_item_link(menu, 1, G_MENU_LINK_SUBMENU);
    g_assert_cmpint(g_menu_model_get_n_items(filters), ==, 3);
    g_object_unref(filters);
    g_assert_cmpuint(filter_prepared, ==, 1);
    g_assert_true(gtk_widget_activate_action(popover, "cellfilter.apply", "i", 1));
    g_assert_cmpuint(filter_applied, ==, 1);
    gtk_popover_popdown(GTK_POPOVER(popover));
    settle_layout();
    gtk_widget_unparent(popover);
    GListModel *controllers = gtk_widget_observe_controllers(cell);
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GObject *controller = g_list_model_get_item(controllers, i);
        if (GTK_IS_GESTURE_CLICK(controller) && gtk_gesture_single_get_button(GTK_GESTURE_SINGLE(controller)) == GDK_BUTTON_PRIMARY) g_signal_emit_by_name(controller, "pressed", 2, 1.0, 1.0);
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
static int shortcut_calls;
static int shortcut_action(void *context, int32_t command) {
    g_assert_true(context == &shortcut_calls);
    shortcut_calls++;
    return command != 7;
}
static void test_shortcuts(void) {
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_t, GDK_CONTROL_MASK), ==, 1);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_T, GDK_CONTROL_MASK | GDK_LOCK_MASK), ==, 1);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_w, GDK_CONTROL_MASK), ==, 2);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_Tab, GDK_CONTROL_MASK), ==, 3);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_ISO_Left_Tab, GDK_CONTROL_MASK | GDK_SHIFT_MASK), ==, 4);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_9, GDK_CONTROL_MASK), ==, 109);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_1, GDK_CONTROL_MASK), ==, 101);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_p, GDK_CONTROL_MASK), ==, 5);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_f, GDK_CONTROL_MASK), ==, 5);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_l, GDK_CONTROL_MASK), ==, 6);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_Escape, 0), ==, 7);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_F5, 0), ==, 8);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_Page_Up, GDK_CONTROL_MASK), ==, 9);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_Page_Down, GDK_CONTROL_MASK), ==, 10);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_equal, GDK_CONTROL_MASK), ==, 11);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_plus, GDK_CONTROL_MASK | GDK_SHIFT_MASK), ==, 11);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_minus, GDK_CONTROL_MASK), ==, 12);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_Return, GDK_CONTROL_MASK), ==, 0);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_t, GDK_CONTROL_MASK | GDK_ALT_MASK), ==, 0);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_t, GDK_CONTROL_MASK | GDK_SHIFT_MASK), ==, 0);
    g_assert_cmpint(sdbui_shortcut_command(GDK_KEY_t, 0), ==, 0);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    g_object_ref_sink(root);
    sdbui_shortcuts_install(root, &shortcut_calls, shortcut_action, NULL);
    sdbui_shortcuts_install(root, &shortcut_calls, shortcut_action, NULL);
    GListModel *controllers = gtk_widget_observe_controllers(root);
    g_assert_cmpuint(g_list_model_get_n_items(controllers), ==, 1);
    GObject *controller = g_list_model_get_item(controllers, 0);
    gboolean handled = FALSE;
    g_signal_emit_by_name(controller, "key-pressed", GDK_KEY_t, 0, GDK_CONTROL_MASK, &handled);
    g_assert_true(handled);
    g_assert_cmpint(shortcut_calls, ==, 1);
    g_signal_emit_by_name(controller, "key-pressed", GDK_KEY_Escape, 0, 0, &handled);
    g_assert_false(handled);
    g_assert_cmpint(shortcut_calls, ==, 2);
    g_object_unref(controller); g_object_unref(controllers); g_object_unref(root);
}

typedef struct { int width, height, final, destroyed; } LayoutTest;
static void layout_changed(void *context, int width, int height, int final) {
    LayoutTest *state = context;
    state->width = width; state->height = height;
    state->final += final;
}
static void layout_destroy(void *context) { ((LayoutTest *)context)->destroyed++; }
static gboolean finish_layout_wait(gpointer data) { g_main_loop_quit(data); return G_SOURCE_REMOVE; }
static void settle_layout(void) {
    GMainLoop *wait = g_main_loop_new(NULL, FALSE);
    g_timeout_add(500, finish_layout_wait, wait);
    g_main_loop_run(wait); g_main_loop_unref(wait);
}
static void test_session_layout(void) {
    LayoutTest window_state = {0}, sidebar_state = {0};
    GtkWidget *window = gtk_window_new();
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_start_child(GTK_PANED(paned), gtk_label_new("Sidebar"));
    gtk_paned_set_end_child(GTK_PANED(paned), gtk_label_new("Editor"));
    gtk_window_set_child(GTK_WINDOW(window), paned);
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 650);
    sdbui_session_window(paned, &window_state, layout_changed, layout_destroy);
    sdbui_session_sidebar(paned, 360, &sidebar_state, layout_changed, layout_destroy);
    gtk_window_present(GTK_WINDOW(window));
    settle_layout();
    g_assert_cmpint(gtk_paned_get_position(GTK_PANED(paned)), ==, 360);
    g_assert_cmpint(window_state.width, ==, 900);
    g_assert_cmpint(window_state.height, ==, 650);
    gtk_window_set_default_size(GTK_WINDOW(window), 1050, 700);
    gtk_paned_set_position(GTK_PANED(paned), 420);
    settle_layout();
    g_assert_cmpint(sidebar_state.width, ==, 420);
    g_assert_cmpint(window_state.width, ==, 1050);
    g_assert_cmpint(window_state.height, ==, 700);
    gtk_widget_set_visible(window, FALSE);
    g_assert_cmpint(window_state.final, ==, 1);
    gtk_window_destroy(GTK_WINDOW(window));
    g_assert_cmpint(window_state.destroyed, ==, 1);
    g_assert_cmpint(sidebar_state.destroyed, ==, 1);
}

typedef struct { guint selected, calls, destroyed; } TableListTest;
static void selected_table(void *context, uint32_t index) {
    TableListTest *test = context;
    test->selected = index; test->calls++;
}
static void destroy_table_test(void *context) { ((TableListTest *)context)->destroyed++; }
static guint count_widgets(GtkWidget *widget, GType type) {
    guint count = G_TYPE_CHECK_INSTANCE_TYPE(widget, type) ? 1 : 0;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) count += count_widgets(child, type);
    return count;
}
static void test_virtual_table_list(void) {
    TableListTest test = {0};
    GtkWidget *window = gtk_window_new(), *root = gtk_fixed_new();
    gtk_window_set_default_size(GTK_WINDOW(window), 320, 300);
    gtk_window_set_child(GTK_WINDOW(window), root);
    sdbui_table_list_install(root, &test, selected_table, destroy_table_test);
    g_assert_true(sdbui_table_list_context(root) == &test);
    char **names = g_new0(char *, 10001);
    for (guint index = 0; index < 10000; index++) names[index] = g_strdup_printf("table_%05u", index);
    sdbui_table_list_update(root, (const char *const *)names, 1, 9999, 320, 300);
    g_strfreev(names);
    gtk_window_present(GTK_WINDOW(window));
    settle_layout();
    GtkWidget *view = find(root, GTK_TYPE_LIST_VIEW);
    g_assert_nonnull(view);
    GtkSingleSelection *selection = GTK_SINGLE_SELECTION(gtk_list_view_get_model(GTK_LIST_VIEW(view)));
    g_assert_cmpuint(g_list_model_get_n_items(G_LIST_MODEL(selection)), ==, 10000);
    g_assert_cmpuint(gtk_single_selection_get_selected(selection), ==, 9999);
    g_assert_cmpuint(test.calls, ==, 0);
    guint labels = count_widgets(root, GTK_TYPE_LABEL);
    g_assert_cmpuint(labels, >, 0);
    g_assert_cmpuint(labels, <, 1000); /* Actual widgets must stay bounded. */
    gtk_single_selection_set_selected(selection, 123);
    g_assert_cmpuint(test.calls, ==, 1);
    g_assert_cmpuint(test.selected, ==, 123);
    const char *filtered[] = {"users", "orders", NULL};
    sdbui_table_list_update(root, filtered, 1, GTK_INVALID_LIST_POSITION, 320, 300);
    g_assert_cmpuint(g_list_model_get_n_items(G_LIST_MODEL(selection)), ==, 2);
    g_assert_cmpuint(gtk_single_selection_get_selected(selection), ==, GTK_INVALID_LIST_POSITION);
    g_assert_cmpuint(test.calls, ==, 1); /* Filtering must never pick a different table. */
    sdbui_table_list_update(root, NULL, 0, 1, 320, 300);
    g_assert_cmpuint(test.calls, ==, 1);
    gtk_single_selection_set_selected(selection, 0);
    g_assert_cmpuint(test.calls, ==, 2);
    g_assert_cmpuint(test.selected, ==, 0);
    gtk_window_destroy(GTK_WINDOW(window));
    g_assert_cmpuint(test.destroyed, ==, 1);
}

int main(void) {
    gtk_init();
    test_shortcuts();
    test_frozen_grids();
    test_session_layout();
    test_virtual_table_list();
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
    sdbui_value_filters(grid, prepare_cell_filter, apply_cell_filter, destroy_cell_filter);
    sdbui_grid_headers(grid, prepare_header, apply_header, destroy_header);
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
    sdbui_grid_font_size(grid, 20);
    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(300, verify, NULL);
    g_main_loop_run(loop);
    gtk_window_destroy(GTK_WINDOW(window));
    g_main_loop_unref(loop);
    settle_layout();
    g_assert_cmpuint(filter_destroyed, ==, 1);
    g_print("Value interactions passed: hover, activation, JSON toggle, exact clipboard copy, Unicode cursor navigation, keyboard command routing, session window/sidebar persistence, virtualized table selection, cell filter submenu, header context menu, frozen grid scrolling and selection\n");
    return 0;
}
