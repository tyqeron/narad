#include "notification_source.h"
#include <cstdio>
static void method(GDBusConnection *bus, const gchar *, const gchar *,
                   const gchar *, const gchar *name, GVariant *args,
                   GDBusMethodInvocation *call, gpointer data) {
  auto *app = GTK_APPLICATION(data);
  g_autoptr(GError) error = nullptr;
  if (g_strcmp0(name, "Enable") == 0) {
    gboolean enabled;
    g_variant_get(args, "(b)", &enabled);
    if (!narad_notification_source_enable(app, enabled, &error)) {
      g_dbus_method_invocation_return_gerror(call, error);
      return;
    }
    g_dbus_method_invocation_return_value(call, nullptr);
  } else if (g_strcmp0(name, "Status") == 0) {
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(@a{sv})", narad_notification_source_status(app)));
  } else if (g_strcmp0(name, "List") == 0)
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(@aa{sv})", narad_notification_source_items(app)));
  else if (g_strcmp0(name, "Dismiss") == 0) {
    const gchar *key;
    g_variant_get(args, "(&s)", &key);
    if (!narad_notification_source_dismiss(app, key, &error)) {
      g_dbus_method_invocation_return_gerror(call, error);
      return;
    }
    g_dbus_method_invocation_return_value(call, nullptr);
  } else if (g_strcmp0(name, "Own") == 0) {
    GVariantBuilder actions, hints;
    g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
    g_variant_builder_init(&hints, G_VARIANT_TYPE_VARDICT);
    g_dbus_connection_call(
        bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify",
        g_variant_new("(susss@as@a{sv}i)", "Narad", 0u, "", "Own fixture",
                      "No loop", g_variant_builder_end(&actions),
                      g_variant_builder_end(&hints), 0),
        nullptr, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, nullptr, nullptr);
    g_dbus_method_invocation_return_value(call, nullptr);
  } else if (g_strcmp0(name, "Quit") == 0) {
    narad_notification_source_enable(app, false, nullptr);
    g_dbus_method_invocation_return_value(call, nullptr);
    g_application_quit(G_APPLICATION(app));
  }
}
static void startup(GtkApplication *app, gpointer) {
  const char *xml =
      "<node><interface name='dev.narad.SourceTest'><method name='Status'><arg "
      "type='a{sv}' direction='out'/></method><method name='Enable'><arg "
      "type='b' direction='in'/></method><method name='List'><arg "
      "type='aa{sv}' direction='out'/></method><method name='Dismiss'><arg "
      "type='s' direction='in'/></method><method name='Own'/><method "
      "name='Quit'/></interface></node>";
  auto *info = g_dbus_node_info_new_for_xml(xml, nullptr);
  static const GDBusInterfaceVTable table = {
      method, nullptr, nullptr, {nullptr}};
  auto *bus = g_application_get_dbus_connection(G_APPLICATION(app));
  g_dbus_connection_register_object(bus, "/Source", info->interfaces[0], &table,
                                    app, nullptr, nullptr);
  g_dbus_node_info_unref(info);
  puts(g_dbus_connection_get_unique_name(bus));
  fflush(stdout);
}
int main(int argc, char **argv) {
  auto *app =
      gtk_application_new("dev.narad.SourceTest", G_APPLICATION_NON_UNIQUE);
  g_signal_connect(app, "startup", G_CALLBACK(startup), nullptr);
  g_signal_connect(
      app, "activate",
      G_CALLBACK(+[](GApplication *app, gpointer) { g_application_hold(app); }),
      nullptr);
  int result = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return result;
}
