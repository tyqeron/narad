#include "desktop_integration.h"
#include "notification_source.h"
#include <glib/gstdio.h>
#include <string>
#include <cstring>
#include <map>

namespace {
void send_shared_files(GtkApplication *application, GPtrArray *files) {
  auto *channel = static_cast<FlMethodChannel *>(
      g_object_get_data(G_OBJECT(application), "narad-desktop-channel"));
  if (!channel || !files || files->len == 0) return;
  g_autoptr(FlValue) values = fl_value_new_list();
  for (guint i = 0; i < files->len; ++i)
    fl_value_append_take(values, fl_value_new_string(static_cast<const gchar *>(g_ptr_array_index(files, i))));
  fl_method_channel_invoke_method(channel, "sharedContent", values, nullptr, nullptr, nullptr);
}
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
void notification_action(GSimpleAction*, GVariant* parameter, gpointer app) {
  const gchar* target=g_variant_get_string(parameter,nullptr);
  const gchar* separator=strchr(target, ':');
  if(!separator)return;
  auto* channel=static_cast<FlMethodChannel*>(g_object_get_data(G_OBJECT(app),"narad-desktop-channel"));
  if(!channel)return;
  g_autoptr(FlValue) args=fl_value_new_map();
  fl_value_set_string_take(args,"id",fl_value_new_int(g_ascii_strtoll(target,nullptr,10)));
  fl_value_set_string_take(args,"action",fl_value_new_string(separator+1));
  fl_method_channel_invoke_method(channel,"notificationAction",args,nullptr,nullptr,nullptr);
}
// The freedesktop API carries source image data alongside the notification.
// Keep stable IDs and route actions back through the authenticated phone bridge.
std::map<gint64, guint32> mirrored_notifications;
GDBusConnection* notification_bus(GApplication* app, GError** error) {
  static GDBusConnection* bus=nullptr;
  if(bus)return bus;
  bus=g_bus_get_sync(G_BUS_TYPE_SESSION,nullptr,error);
  if(!bus)return nullptr;
  g_dbus_connection_signal_subscribe(bus,"org.freedesktop.Notifications",
      "org.freedesktop.Notifications",nullptr,"/org/freedesktop/Notifications",
      nullptr,G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection*,const gchar*,const gchar*,const gchar*,const gchar* signal,GVariant* params,gpointer data) {
        guint32 server_id=0;
        if(g_strcmp0(signal,"ActionInvoked")==0) {
          const gchar* action=nullptr;g_variant_get(params,"(u&s)",&server_id,&action);
          for(const auto& entry:mirrored_notifications)if(entry.second==server_id) {
            if(g_strcmp0(action,"default")==0)show_phone(nullptr,nullptr,data);
            else {
              auto target=std::to_string(entry.first)+":"+action;
              g_autoptr(GVariant) value=g_variant_ref_sink(g_variant_new_string(target.c_str()));
              notification_action(nullptr,value,data);
            }
            break;
          }
        } else if(g_strcmp0(signal,"NotificationClosed")==0) {
          guint32 reason=0;g_variant_get(params,"(uu)",&server_id,&reason);
          for(auto it=mirrored_notifications.begin();it!=mirrored_notifications.end();)
            if(it->second==server_id)it=mirrored_notifications.erase(it);else ++it;
        }
      },app,nullptr);
  return bus;
}
// Decode only the fixed-size PNG format emitted by the phone bridge.
void notification_image_hint(FlValue* args, GVariantBuilder* hints) {
  auto* icon=fl_value_lookup_string(args,"icon");
  if(!icon || fl_value_get_type(icon)!=FL_VALUE_TYPE_UINT8_LIST)return;
  const auto size=fl_value_get_length(icon);
  const auto* bytes=fl_value_get_uint8_list(icon);
  const guint8 signature[]={137,80,78,71,13,10,26,10};
  if(size<33 || size>6144 || memcmp(bytes,signature,8)!=0 || memcmp(bytes+12,"IHDR",4)!=0)return;
  guint32 width,height;
  memcpy(&width,bytes+16,4);memcpy(&height,bytes+20,4);
  if(GUINT32_FROM_BE(width)!=32 || GUINT32_FROM_BE(height)!=32)return;
  g_autoptr(GInputStream) stream=g_memory_input_stream_new_from_data(bytes,size,nullptr);
  g_autoptr(GdkPixbuf) image=gdk_pixbuf_new_from_stream(stream,nullptr,nullptr);
  if(!image || gdk_pixbuf_get_width(image)!=32 || gdk_pixbuf_get_height(image)!=32)return;
  const auto length=gdk_pixbuf_get_byte_length(image);
  auto* data=g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE,gdk_pixbuf_get_pixels(image),length,1);
  g_variant_builder_add(hints,"{sv}","image-data",g_variant_new("(iiibii@ay)",32,32,
      gdk_pixbuf_get_rowstride(image),gdk_pixbuf_get_has_alpha(image),8,gdk_pixbuf_get_n_channels(image),data));
}
const char* notification_app_icon() {
  // Portable/per-user bundles do not add their icons to the system theme path.
  static const std::string icon=[] {
    g_autofree gchar* executable=g_file_read_link("/proc/self/exe",nullptr);
    if(!executable)return std::string("dev.narad.narad_client");
    g_autofree gchar* directory=g_path_get_dirname(executable);
    g_autofree gchar* path=g_build_filename(directory,"data","narad.png",nullptr);
    return g_file_test(path,G_FILE_TEST_IS_REGULAR)?std::string(path):std::string("dev.narad.narad_client");
  }();
  return icon.c_str();
}
bool send_device_notification(GApplication* app,FlValue* args,GError** error) {
  auto* bus=notification_bus(app,error);if(!bus)return false;
  const auto id=fl_value_get_int(fl_value_lookup_string(args,"id"));
  GVariantBuilder actions;g_variant_builder_init(&actions,G_VARIANT_TYPE("as"));
  g_variant_builder_add(&actions,"s","default");g_variant_builder_add(&actions,"s","Open Narad");
  auto* buttons=fl_value_lookup_string(args,"actions");
  if(buttons && fl_value_get_type(buttons)==FL_VALUE_TYPE_MAP)
    for(size_t i=0;i<fl_value_get_length(buttons);++i) {
      g_variant_builder_add(&actions,"s",fl_value_get_string(fl_value_get_map_key(buttons,i)));
      g_variant_builder_add(&actions,"s",fl_value_get_string(fl_value_get_map_value(buttons,i)));
    }
  GVariantBuilder hints;g_variant_builder_init(&hints,G_VARIANT_TYPE_VARDICT);
  notification_image_hint(args,&hints);
  g_variant_builder_add(&hints,"{sv}","x-narad-mirrored",g_variant_new_boolean(TRUE));
  auto* ongoing=fl_value_lookup_string(args,"ongoing");
  const bool resident=ongoing && fl_value_get_type(ongoing)==FL_VALUE_TYPE_BOOL && fl_value_get_bool(ongoing);
  g_variant_builder_add(&hints,"{sv}","resident",g_variant_new_boolean(resident));
  g_variant_builder_add(&hints,"{sv}","suppress-sound",g_variant_new_boolean(TRUE));
  auto* progress=fl_value_lookup_string(args,"progress");
  if(progress && fl_value_get_type(progress)==FL_VALUE_TYPE_INT)
    g_variant_builder_add(&hints,"{sv}","value",g_variant_new_int32(fl_value_get_int(progress)));
  const auto heading=std::string(fl_value_get_string(fl_value_lookup_string(args,"title")));
  const auto content=std::string(fl_value_get_string(fl_value_lookup_string(args,"text")));
  const auto line=content.find('\n');
  const auto summary=content.substr(0,line);
  const auto remaining=line==std::string::npos?std::string():content.substr(line+1);
  g_autofree gchar* body=g_markup_escape_text(remaining.c_str(),-1);
  auto found=mirrored_notifications.find(id);
  g_autoptr(GVariant) result=g_dbus_connection_call_sync(bus,"org.freedesktop.Notifications",
      "/org/freedesktop/Notifications","org.freedesktop.Notifications","Notify",
      g_variant_new("(susss@as@a{sv}i)",heading.c_str(),found==mirrored_notifications.end()?0:found->second,
          notification_app_icon(),summary.c_str(),body,
          g_variant_builder_end(&actions),g_variant_builder_end(&hints),resident?0:-1),
      G_VARIANT_TYPE("(u)"),G_DBUS_CALL_FLAGS_NONE,2000,nullptr,error);
  if(!result)return false;
  guint32 server_id=0;g_variant_get(result,"(u)",&server_id);mirrored_notifications[id]=server_id;
  return true;
}
FlValue* source_value(GVariant* value) {
  if(g_variant_is_of_type(value,G_VARIANT_TYPE_VARDICT)) {
    auto* result=fl_value_new_map();GVariantIter iter;const gchar* key;GVariant* child;
    g_variant_iter_init(&iter,value);
    while(g_variant_iter_next(&iter,"{&sv}",&key,&child)) {
      fl_value_set_string_take(result,key,source_value(child));g_variant_unref(child);
    }
    return result;
  }
  if(g_variant_is_of_type(value,G_VARIANT_TYPE_STRING))return fl_value_new_string(g_variant_get_string(value,nullptr));
  if(g_variant_is_of_type(value,G_VARIANT_TYPE_BOOLEAN))return fl_value_new_bool(g_variant_get_boolean(value));
  if(g_variant_is_of_type(value,G_VARIANT_TYPE_INT64))return fl_value_new_int(g_variant_get_int64(value));
  auto* result=fl_value_new_list();
  for(gsize i=0;i<g_variant_n_children(value);++i){g_autoptr(GVariant) child=g_variant_get_child_value(value,i);fl_value_append_take(result,source_value(child));}
  return result;
}
void handle(FlMethodChannel *, FlMethodCall *call, gpointer user_data) {
  const gchar *method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method,"notificationSourceStatus")==0 || g_strcmp0(method,"desktopNotifications")==0) {
    g_autoptr(GVariant) value=g_strcmp0(method,"notificationSourceStatus")==0?
        narad_notification_source_status(GTK_APPLICATION(user_data)):narad_notification_source_items(GTK_APPLICATION(user_data));
    g_autoptr(FlValue) result=source_value(value);
    response=FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if(g_strcmp0(method,"setNotificationSharing")==0 || g_strcmp0(method,"dismissDesktopNotification")==0) {
    auto* args=fl_method_call_get_args(call);g_autoptr(GError) error=nullptr;bool ok=false;
    if(args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP) {
      auto* enabled=fl_value_lookup_string(args,"enabled");auto* key=fl_value_lookup_string(args,"key");
      if(g_strcmp0(method,"setNotificationSharing")==0 && enabled && fl_value_get_type(enabled)==FL_VALUE_TYPE_BOOL)
        ok=narad_notification_source_enable(GTK_APPLICATION(user_data),fl_value_get_bool(enabled),&error);
      else if(key && fl_value_get_type(key)==FL_VALUE_TYPE_STRING)
        ok=narad_notification_source_dismiss(GTK_APPLICATION(user_data),fl_value_get_string(key),&error);
    }
    if(ok)response=FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    else response=FL_METHOD_RESPONSE(fl_method_error_response_new("notification_source",error?error->message:"Invalid notification request",nullptr));
  } else if (g_strcmp0(method, "desktopStatus") == 0) {
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
  } else if (g_strcmp0(method, "show") == 0) {
    g_application_activate(G_APPLICATION(user_data));
    response=FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "cancelPhoneNotification") == 0) {
    FlValue* args=fl_method_call_get_args(call);
    FlValue* id=args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,"id"):nullptr;
    if(id && fl_value_get_type(id)==FL_VALUE_TYPE_INT) {
      auto found=mirrored_notifications.find(fl_value_get_int(id));
      if(found!=mirrored_notifications.end()) {
        g_autoptr(GError) error=nullptr;
        auto* bus=notification_bus(G_APPLICATION(user_data),&error);
        if(bus)g_dbus_connection_call(bus,"org.freedesktop.Notifications","/org/freedesktop/Notifications",
            "org.freedesktop.Notifications","CloseNotification",g_variant_new("(u)",found->second),
            nullptr,G_DBUS_CALL_FLAGS_NONE,2000,nullptr,nullptr,nullptr);
        mirrored_notifications.erase(found);
      }
      auto key=std::string("narad-phone-")+std::to_string(fl_value_get_int(id));
      g_application_withdraw_notification(G_APPLICATION(user_data),key.c_str());
    }
    response=FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "phoneNotification") == 0) {
    FlValue* args=fl_method_call_get_args(call);
    FlValue* title=args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,"title"):nullptr;
    FlValue* text=args && fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,"text"):nullptr;
    FlValue* id=args?fl_value_lookup_string(args,"id"):nullptr;
    if(!id || fl_value_get_type(id)!=FL_VALUE_TYPE_INT || !title || !text || fl_value_get_type(title)!=FL_VALUE_TYPE_STRING || fl_value_get_type(text)!=FL_VALUE_TYPE_STRING) {
      response=FL_METHOD_RESPONSE(fl_method_error_response_new("arguments","Expected notification text",nullptr));
    } else if(auto* device=fl_value_lookup_string(args,"deviceName");device && fl_value_get_type(device)==FL_VALUE_TYPE_STRING) {
      g_autoptr(GError) error=nullptr;
      if(send_device_notification(G_APPLICATION(user_data),args,&error))
        response=FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      else response=FL_METHOD_RESPONSE(fl_method_error_response_new("notification",error?error->message:"Notification unavailable",nullptr));
    } else {
      g_autoptr(GNotification) notification=g_notification_new(fl_value_get_string(title));
      g_notification_set_body(notification,fl_value_get_string(text));
      g_notification_set_default_action(notification,"app.show");
      FlValue* actions=fl_value_lookup_string(args,"actions");
      if(actions && fl_value_get_type(actions)==FL_VALUE_TYPE_MAP) {
        for(size_t i=0;i<fl_value_get_length(actions);i++) {
          FlValue* key=fl_value_get_map_key(actions,i);FlValue* label=fl_value_get_map_value(actions,i);
          if(fl_value_get_type(key)!=FL_VALUE_TYPE_STRING || fl_value_get_type(label)!=FL_VALUE_TYPE_STRING)continue;
          auto target=std::to_string(fl_value_get_int(id))+":"+fl_value_get_string(key);
          if(g_strcmp0(fl_value_get_string(key),"pairing-review")==0)
            g_notification_set_default_action_and_target(notification,"app.notification-action","s",target.c_str());
          g_notification_add_button_with_target(notification,fl_value_get_string(label),"app.notification-action","s",target.c_str());
        }
      }
      auto key=std::string("narad-phone-")+std::to_string(fl_value_get_int(id));
      g_application_send_notification(G_APPLICATION(user_data),key.c_str(),notification);
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
void narad_desktop_open_files(GtkApplication *application, GFile **files, gint count) {
  auto *pending = static_cast<GPtrArray *>(g_object_get_data(G_OBJECT(application), "narad-shared-files"));
  if (!pending) {
    pending = g_ptr_array_new_with_free_func(g_free);
    g_object_set_data_full(G_OBJECT(application), "narad-shared-files", pending, reinterpret_cast<GDestroyNotify>(g_ptr_array_unref));
  }
  for (gint i = 0; i < count && pending->len < 16; ++i) {
    g_autofree gchar *uri = g_file_get_uri(files[i]);
    if (uri) g_ptr_array_add(pending, g_strdup(uri));
  }
  if (g_object_get_data(G_OBJECT(application), "narad-ready")) {
    send_shared_files(application, pending);
    g_ptr_array_set_size(pending, 0);
  }
}
void narad_desktop_flush_pending(GtkApplication *application) {
  auto *pending = static_cast<GPtrArray *>(g_object_get_data(G_OBJECT(application), "narad-shared-files"));
  if (pending && pending->len > 0) {
    send_shared_files(application, pending);
    g_ptr_array_set_size(pending, 0);
  }
}
void narad_register_desktop(FlView *view, GtkApplication *application) {
  if(!g_action_map_lookup_action(G_ACTION_MAP(application),"show")){
    GSimpleAction* action=g_simple_action_new("show",nullptr);
    g_signal_connect(action,"activate",G_CALLBACK(show_phone),application);
    g_action_map_add_action(G_ACTION_MAP(application),G_ACTION(action));
    g_object_unref(action);
  }
  if(!g_action_map_lookup_action(G_ACTION_MAP(application),"notification-action")) {
    GSimpleAction* action=g_simple_action_new("notification-action",G_VARIANT_TYPE_STRING);
    g_signal_connect(action,"activate",G_CALLBACK(notification_action),application);
    g_action_map_add_action(G_ACTION_MAP(application),G_ACTION(action));g_object_unref(action);
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
