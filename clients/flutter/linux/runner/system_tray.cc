#include "system_tray.h"
#include "desktop_integration.h"
#include <cstring>
#include <vector>

struct NaradSystemTray {
  GtkApplication *app;
  GDBusConnection *bus = nullptr;
  GDBusNodeInfo *info = nullptr;
  guint item = 0, menu = 0, watcher = 0;
  GtkStatusIcon *legacy = nullptr;
  gchar *icon;
};
namespace {
constexpr char kItem[] = "/StatusNotifierItem";
constexpr char kMenu[] = "/MenuBar";
constexpr char kXml[] = R"XML(<node>
<interface name="org.kde.StatusNotifierItem">
 <method name="ProvideXdgActivationToken"><arg type="s" direction="in"/></method>
 <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
 <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
 <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
 <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
 <property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
 <property name="IconPixmap" type="a(iiay)" access="read"/>
 <property name="IconThemePath" type="s" access="read"/>
 <property name="OverlayIconName" type="s" access="read"/><property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
 <property name="AttentionIconName" type="s" access="read"/><property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
 <property name="AttentionMovieName" type="s" access="read"/>
 <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
 <property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
</interface>
<interface name="com.canonical.dbusmenu">
 <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
 <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
 <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
 <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
 <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
 <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
 <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
 <property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
 <property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
</interface></node>)XML";
void open(NaradSystemTray *t) { g_application_activate(G_APPLICATION(t->app)); }
void menu_open(GtkMenuItem *, gpointer data) {
  open(static_cast<NaradSystemTray *>(data));
}
void menu_quit(GtkMenuItem *, gpointer data) {
  narad_request_quit(static_cast<NaradSystemTray *>(data)->app);
}
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
void popup(NaradSystemTray *t, guint button, guint time) {
  GtkWidget *menu = gtk_menu_new();
  for (int id = 1; id <= 2; ++id) {
    GtkWidget *item =
        gtk_menu_item_new_with_label(id == 1 ? "Open Narad" : "Quit Narad");
    g_signal_connect(item, "activate",
                     id == 1 ? G_CALLBACK(menu_open) : G_CALLBACK(menu_quit),
                     t);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
  }
  g_signal_connect_swapped(menu, "selection-done",
                           G_CALLBACK(gtk_widget_destroy), menu);
  gtk_widget_show_all(menu);
  gtk_menu_popup(GTK_MENU(menu), nullptr, nullptr, nullptr, nullptr, button,
                 time);
}
void legacy_open(GtkStatusIcon *, gpointer data) {
  open(static_cast<NaradSystemTray *>(data));
}
void legacy_menu(GtkStatusIcon *, guint button, guint time, gpointer data) {
  popup(static_cast<NaradSystemTray *>(data), button, time);
}
void legacy_visible(NaradSystemTray *t, bool visible) {
  gtk_status_icon_set_visible(t->legacy, visible);
}
#pragma GCC diagnostic pop
GVariant *properties(int id) {
  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
  if (id == 0)
    g_variant_builder_add(&props, "{sv}", "children-display",
                          g_variant_new_string("submenu"));
  else {
    g_variant_builder_add(
        &props, "{sv}", "label",
        g_variant_new_string(id == 1 ? "Open Narad" : "Quit Narad"));
    g_variant_builder_add(&props, "{sv}", "enabled",
                          g_variant_new_boolean(TRUE));
    g_variant_builder_add(&props, "{sv}", "visible",
                          g_variant_new_boolean(TRUE));
  }
  return g_variant_builder_end(&props);
}
GVariant *layout(int id, int depth) {
  GVariantBuilder children;
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  if (id == 0 && depth != 0)
    for (int child = 1; child <= 2; ++child)
      g_variant_builder_add(&children, "v", layout(child, 0));
  return g_variant_new("(i@a{sv}@av)", id, properties(id),
                       g_variant_builder_end(&children));
}
void event(NaradSystemTray *t, int id, const char *name) {
  if (g_strcmp0(name, "clicked") != 0)
    return;
  if (id == 1)
    open(t);
  if (id == 2)
    narad_request_quit(t->app);
}
GVariant *pixmap(NaradSystemTray *t) {
  GVariantBuilder array;
  g_variant_builder_init(&array, G_VARIANT_TYPE("a(iiay)"));
  g_autoptr(GdkPixbuf) image =
      gdk_pixbuf_new_from_file_at_scale(t->icon, 32, 32, TRUE, nullptr);
  if (image) {
    const int w = gdk_pixbuf_get_width(image), h = gdk_pixbuf_get_height(image);
    const int stride = gdk_pixbuf_get_rowstride(image),
              channels = gdk_pixbuf_get_n_channels(image);
    const auto *pixels = gdk_pixbuf_get_pixels(image);
    std::vector<guint8> argb;
    for (int y = 0; y < h; ++y)
      for (int x = 0; x < w; ++x) {
        const auto *p = pixels + y * stride + x * channels;
        argb.insert(argb.end(),
                    {channels == 4 ? p[3] : static_cast<guint8>(255), p[0],
                     p[1], p[2]});
      }
    g_variant_builder_add(&array, "(ii@ay)", w, h,
                          g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,
                                                    argb.data(), argb.size(),
                                                    1));
  }
  return g_variant_builder_end(&array);
}
GVariant *get_property(GDBusConnection *, const gchar *, const gchar *,
                       const gchar *interface, const gchar *name, GError **,
                       gpointer data) {
  auto *t = static_cast<NaradSystemTray *>(data);
  if (g_strcmp0(interface, "com.canonical.dbusmenu") == 0) {
    if (!strcmp(name, "Version"))
      return g_variant_new_uint32(3);
    if (!strcmp(name, "TextDirection"))
      return g_variant_new_string("ltr");
    if (!strcmp(name, "Status"))
      return g_variant_new_string("normal");
    if (!strcmp(name, "IconThemePath"))
      return g_variant_new_strv(nullptr, 0);
  } else {
    if (!strcmp(name, "Category"))
      return g_variant_new_string("ApplicationStatus");
    if (!strcmp(name, "Id"))
      return g_variant_new_string("dev.narad.narad_client");
    if (!strcmp(name, "Title"))
      return g_variant_new_string("Narad");
    if (!strcmp(name, "Status"))
      return g_variant_new_string("Active");
    if (!strcmp(name, "WindowId"))
      return g_variant_new_int32(0);
    if (!strcmp(name, "IconThemePath") || !strcmp(name, "OverlayIconName") ||
        !strcmp(name, "AttentionIconName") ||
        !strcmp(name, "AttentionMovieName"))
      return g_variant_new_string("");
    if (!strcmp(name, "OverlayIconPixmap") ||
        !strcmp(name, "AttentionIconPixmap"))
      return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0);
    if (!strcmp(name, "IconName"))
      return g_variant_new_string(t->icon);
    if (!strcmp(name, "IconPixmap"))
      return pixmap(t);
    if (!strcmp(name, "ToolTip"))
      return g_variant_new("(s@a(iiay)ss)", "", pixmap(t), "Narad",
                           "Running in the background");
    if (!strcmp(name, "ItemIsMenu"))
      return g_variant_new_boolean(FALSE);
    if (!strcmp(name, "Menu"))
      return g_variant_new_object_path(kMenu);
  }
  return nullptr;
}
void method(GDBusConnection *, const gchar *, const gchar *,
            const gchar *interface, const gchar *name, GVariant *args,
            GDBusMethodInvocation *call, gpointer data) {
  auto *t = static_cast<NaradSystemTray *>(data);
  if (g_strcmp0(interface, "org.kde.StatusNotifierItem") == 0) {
    if (!strcmp(name, "ProvideXdgActivationToken")) {
      const gchar *token;
      g_variant_get(args, "(&s)", &token);
      GList *windows = gtk_application_get_windows(t->app);
      if (windows)
        gtk_window_set_startup_id(GTK_WINDOW(windows->data), token);
    }
    if (!strcmp(name, "Activate") || !strcmp(name, "SecondaryActivate"))
      open(t);
    if (!strcmp(name, "ContextMenu"))
      popup(t, 0, gtk_get_current_event_time());
    g_dbus_method_invocation_return_value(call, nullptr);
    return;
  }
  if (!strcmp(name, "GetLayout")) {
    gint32 id, depth;
    g_autoptr(GVariant) names = nullptr;
    g_variant_get(args, "(ii@as)", &id, &depth, &names);
    if (id < 0 || id > 2) {
      g_dbus_method_invocation_return_dbus_error(
          call, "com.canonical.dbusmenu.Error.InvalidMenuItem",
          "Unknown menu item");
      return;
    }
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(u@(ia{sv}av))", 1u, layout(id, depth)));
  } else if (!strcmp(name, "GetGroupProperties")) {
    g_autoptr(GVariant) ids = g_variant_get_child_value(args, 0);
    GVariantBuilder result;
    g_variant_builder_init(&result, G_VARIANT_TYPE("a(ia{sv})"));
    GVariantIter iter;
    gint32 id;
    g_variant_iter_init(&iter, ids);
    while (g_variant_iter_next(&iter, "i", &id))
      if (id >= 0 && id <= 2)
        g_variant_builder_add(&result, "(i@a{sv})", id, properties(id));
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&result)));
  } else if (!strcmp(name, "GetProperty")) {
    gint32 id;
    const gchar *prop;
    g_variant_get(args, "(i&s)", &id, &prop);
    g_autoptr(GVariant) props = properties(id);
    g_autoptr(GVariant) value = g_variant_lookup_value(props, prop, nullptr);
    if (id < 0 || id > 2 || !value)
      g_dbus_method_invocation_return_dbus_error(
          call, "com.canonical.dbusmenu.Error.InvalidProperty",
          "Unknown menu property");
    else
      g_dbus_method_invocation_return_value(call, g_variant_new("(v)", value));
  } else if (!strcmp(name, "Event")) {
    gint32 id;
    const gchar *type;
    g_autoptr(GVariant) value = nullptr;
    guint32 time;
    g_variant_get(args, "(i&s@vu)", &id, &type, &value, &time);
    event(t, id, type);
    g_dbus_method_invocation_return_value(call, nullptr);
  } else if (!strcmp(name, "EventGroup")) {
    g_autoptr(GVariant) events = g_variant_get_child_value(args, 0);
    for (gsize i = 0; i < g_variant_n_children(events); ++i) {
      g_autoptr(GVariant) entry = g_variant_get_child_value(events, i);
      gint32 id;
      const gchar *type;
      g_autoptr(GVariant) value = nullptr;
      guint32 time;
      g_variant_get(entry, "(i&s@vu)", &id, &type, &value, &time);
      event(t, id, type);
    }
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32,
                                                         nullptr, 0)));
  } else if (!strcmp(name, "AboutToShow"))
    g_dbus_method_invocation_return_value(call, g_variant_new("(b)", FALSE));
  else if (!strcmp(name, "AboutToShowGroup"))
    g_dbus_method_invocation_return_value(
        call,
        g_variant_new("(@ai@ai)",
                      g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0),
                      g_variant_new_array(G_VARIANT_TYPE_INT32, nullptr, 0)));
  else
    g_dbus_method_invocation_return_error(
        call, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown menu method");
}
void appeared(GDBusConnection *bus, const gchar *, const gchar *,
              gpointer data) {
  auto *t = static_cast<NaradSystemTray *>(data);
  g_dbus_connection_call(
      bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
      g_variant_new("(s)", kItem), nullptr, G_DBUS_CALL_FLAGS_NONE, 5000,
      nullptr,
      [](GObject *source, GAsyncResult *result, gpointer data) {
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
            G_DBUS_CONNECTION(source), result, &error);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        gtk_status_icon_set_visible(GTK_STATUS_ICON(data), reply == nullptr);
#pragma GCC diagnostic pop
        if (error)
          g_warning("System tray registration failed: %s", error->message);
        g_object_unref(data);
      },
      g_object_ref(t->legacy));
}
void vanished(GDBusConnection *, const gchar *, gpointer data) {
  legacy_visible(static_cast<NaradSystemTray *>(data), true);
}
} // namespace
NaradSystemTray *narad_system_tray_new(GtkApplication *app, const gchar *icon) {
  auto *t = new NaradSystemTray{};
  t->app = app;
  t->icon = g_strdup(icon);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  t->legacy = gtk_status_icon_new_from_file(icon);
  gtk_status_icon_set_tooltip_text(t->legacy,
                                   "Narad · running in the background");
  g_signal_connect(t->legacy, "activate", G_CALLBACK(legacy_open), t);
  g_signal_connect(t->legacy, "popup-menu", G_CALLBACK(legacy_menu), t);
#pragma GCC diagnostic pop
  g_autoptr(GError) error = nullptr;
  t->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (!t->bus)
    return t;
  t->info = g_dbus_node_info_new_for_xml(kXml, nullptr);
  static const GDBusInterfaceVTable table = {
      method, get_property, nullptr, {nullptr}};
  t->item = g_dbus_connection_register_object(
      t->bus, kItem, t->info->interfaces[0], &table, t, nullptr, nullptr);
  t->menu = g_dbus_connection_register_object(
      t->bus, kMenu, t->info->interfaces[1], &table, t, nullptr, nullptr);
  if (t->item && t->menu)
    t->watcher = g_bus_watch_name_on_connection(
        t->bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_WATCHER_FLAGS_NONE,
        appeared, vanished, t, nullptr);
  return t;
}
void narad_system_tray_free(NaradSystemTray *t) {
  if (!t)
    return;
  if (t->watcher)
    g_bus_unwatch_name(t->watcher);
  if (t->item)
    g_dbus_connection_unregister_object(t->bus, t->item);
  if (t->menu)
    g_dbus_connection_unregister_object(t->bus, t->menu);
  g_clear_pointer(&t->info, g_dbus_node_info_unref);
  g_clear_object(&t->bus);
  g_clear_object(&t->legacy);
  g_free(t->icon);
  delete t;
}
