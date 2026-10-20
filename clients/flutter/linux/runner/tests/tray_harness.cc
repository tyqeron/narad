// Isolated native harness for scripts/test-linux-tray.py.
#include "system_tray.h"
#include <cstdio>
static GtkWidget *window;
static NaradSystemTray *tray;
static bool initial = true;
void narad_request_quit(GtkApplication *app) {
  g_application_quit(G_APPLICATION(app));
}
static void activate(GtkApplication *app, gpointer) {
  if (!window)
    window = gtk_application_window_new(app);
  if (!initial)
    gtk_widget_show(window);
  initial = false;
}
static void control(GDBusConnection *, const gchar *, const gchar *,
                    const gchar *, const gchar *method, GVariant *,
                    GDBusMethodInvocation *call, gpointer) {
  if (g_strcmp0(method, "Hide") == 0) {
    gtk_widget_hide(window);
    g_dbus_method_invocation_return_value(call, nullptr);
  } else
    g_dbus_method_invocation_return_value(
        call, g_variant_new("(b)", gtk_widget_get_visible(window)));
}
static void startup(GtkApplication *app, gpointer data) {
  tray = narad_system_tray_new(app, static_cast<const char *>(data));
  auto *bus = g_application_get_dbus_connection(G_APPLICATION(app));
  const char *xml = "<node><interface name='dev.narad.TrayTest'><method "
                    "name='Hide'/><method name='Visible'><arg type='b' "
                    "direction='out'/></method></interface></node>";
  auto *info = g_dbus_node_info_new_for_xml(xml, nullptr);
  static const GDBusInterfaceVTable table = {
      control, nullptr, nullptr, {nullptr}};
  g_dbus_connection_register_object(bus, "/Test", info->interfaces[0], &table,
                                    nullptr, nullptr, nullptr);
  g_dbus_node_info_unref(info);
  puts(g_dbus_connection_get_unique_name(bus));
  fflush(stdout);
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  auto *app =
      gtk_application_new("dev.narad.TrayTest", G_APPLICATION_NON_UNIQUE);
  g_signal_connect(app, "startup", G_CALLBACK(startup), argv[1]);
  g_signal_connect(app, "activate", G_CALLBACK(activate), nullptr);
  char *args[] = {argv[0], nullptr};
  int result = g_application_run(G_APPLICATION(app), 1, args);
  narad_system_tray_free(tray);
  g_object_unref(app);
  return result;
}
