#include "desktop_integration.h"
#include <glib/gstdio.h>
#include <string>

namespace {
gchar *autostart_path() {
  return g_build_filename(g_get_user_config_dir(), "autostart",
                          "dev.narad.narad_client.desktop", nullptr);
}
gchar *disabled_path() {
  return g_build_filename(g_get_user_config_dir(), "narad",
                          "autostart-disabled", nullptr);
}
std::string quote_exec(const std::string &value) {
  std::string result = "\"";
  for (char c : value) {
    if (c == '%')
      result += '%';
    if (c == '\\' || c == '"' || c == '$' || c == '`')
      result += '\\';
    result += c;
  }
  return result + "\"";
}
bool set_autostart(bool enabled, GError **error) {
  g_autofree gchar *path = autostart_path();
  g_autofree gchar *disabled = disabled_path();
  g_autofree gchar *pref_dir = g_path_get_dirname(disabled);
  if (g_mkdir_with_parents(pref_dir, 0700) != 0) {
    g_set_error_literal(error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                        "Cannot create Narad preferences");
    return false;
  }
  if (!enabled) {
    if (!g_file_set_contents(disabled, "disabled\n", -1, error))
      return false;
    if (g_file_test(path, G_FILE_TEST_EXISTS) && g_unlink(path) != 0) {
      g_set_error_literal(error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                          "Cannot remove startup entry");
      return false;
    }
    return true;
  }
  g_autofree gchar *executable = g_file_read_link("/proc/self/exe", error);
  if (!executable)
    return false;
  g_autofree gchar *app_dir = g_path_get_dirname(executable);
  g_autofree gchar *bundle_dir = g_path_get_dirname(app_dir);
  g_autofree gchar *launcher =
      g_build_filename(bundle_dir, "narad-linux", nullptr);
  if (!g_file_test(launcher, G_FILE_TEST_IS_EXECUTABLE)) {
    g_set_error_literal(error, G_FILE_ERROR, G_FILE_ERROR_NOENT,
                        "Install the Linux package before enabling startup");
    return false;
  }
  g_autofree gchar *directory = g_path_get_dirname(path);
  if (g_mkdir_with_parents(directory, 0700) != 0) {
    g_set_error_literal(error, G_FILE_ERROR, G_FILE_ERROR_FAILED,
                        "Cannot create startup directory");
    return false;
  }
  g_autoptr(GKeyFile) entry = g_key_file_new();
  g_key_file_set_string(entry, "Desktop Entry", "Type", "Application");
  g_key_file_set_string(entry, "Desktop Entry", "Name", "Narad");
  const auto command = quote_exec(launcher) + " --background";
  g_key_file_set_string(entry, "Desktop Entry", "Exec", command.c_str());
  g_key_file_set_boolean(entry, "Desktop Entry", "X-GNOME-Autostart-enabled",
                         true);
  if (!g_key_file_save_to_file(entry, path, error))
    return false;
  g_unlink(disabled);
  return true;
}
void show_phone(GSimpleAction*,GVariant*,gpointer app){g_application_activate(G_APPLICATION(app));}
void handle(FlMethodChannel *, FlMethodCall *call, gpointer user_data) {
  const gchar *method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "desktopStatus") == 0) {
    g_autofree gchar *path = autostart_path();
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(
        result, "autostart",
        fl_value_new_bool(g_file_test(path, G_FILE_TEST_EXISTS)));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "setAutostart") == 0) {
    FlValue *args = fl_method_call_get_args(call);
    FlValue *enabled = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                           ? fl_value_lookup_string(args, "enabled")
                           : nullptr;
    g_autoptr(GError) error = nullptr;
    if (!enabled || fl_value_get_type(enabled) != FL_VALUE_TYPE_BOOL)
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "arguments", "Expected enabled boolean", nullptr));
    else if (!set_autostart(fl_value_get_bool(enabled), &error))
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("autostart", error->message, nullptr));
    else
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "phoneNotification") == 0) {
    FlValue* args=fl_method_call_get_args(call);
    FlValue* title=args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,"title"):nullptr;
    FlValue* text=args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,"text"):nullptr;
    if(!title || !text || fl_value_get_type(title)!=FL_VALUE_TYPE_STRING || fl_value_get_type(text)!=FL_VALUE_TYPE_STRING) {
      response=FL_METHOD_RESPONSE(fl_method_error_response_new("arguments","Expected notification text",nullptr));
    } else {
      g_autoptr(GNotification) notification=g_notification_new(fl_value_get_string(title));
      g_notification_set_body(notification,fl_value_get_string(text));
      g_notification_set_default_action(notification,"app.show");
      g_application_send_notification(G_APPLICATION(user_data),"narad-phone",notification);
      response=FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "quit") == 0) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    g_application_quit(G_APPLICATION(user_data));
    return;
  } else
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}
} // namespace
void narad_register_desktop(FlView *view, GtkApplication *application) {
  if(!g_action_map_lookup_action(G_ACTION_MAP(application),"show")){
    GSimpleAction* action=g_simple_action_new("show",nullptr);
    g_signal_connect(action,"activate",G_CALLBACK(show_phone),application);
    g_action_map_add_action(G_ACTION_MAP(application),G_ACTION(action));
    g_object_unref(action);
  }
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "dev.narad/desktop", FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(application), "narad-desktop-channel",
                         g_object_ref(channel), g_object_unref);
  fl_method_channel_set_method_call_handler(channel, handle, application,
                                            nullptr);
}

void narad_request_quit(GtkApplication *application) {
  if (g_object_get_data(G_OBJECT(application), "narad-quitting")) return;
  g_object_set_data(G_OBJECT(application), "narad-quitting", GINT_TO_POINTER(1));
  auto *channel = static_cast<FlMethodChannel *>(
      g_object_get_data(G_OBJECT(application), "narad-desktop-channel"));
  if (channel) {
    fl_method_channel_invoke_method(channel, "prepareQuit", nullptr, nullptr, nullptr, nullptr);
    g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, 30, [](gpointer app) -> gboolean {
      g_application_quit(G_APPLICATION(app));
      return G_SOURCE_REMOVE;
    }, g_object_ref(application), g_object_unref);
  } else {
    g_application_quit(G_APPLICATION(application));
  }
}
