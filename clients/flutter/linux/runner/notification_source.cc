#include "notification_source.h"
#include <algorithm>
#include <glib/gstdio.h>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {
struct Notice {
  std::string app, title, text, icon;
  gint64 time;
  bool ongoing = false;
  gint32 progress = -1;
};
struct State {
  std::mutex mutex;
  std::string own, server;
  bool active = false;
  std::map<std::pair<std::string, guint32>, std::pair<Notice, gint64>> pending;
  std::map<guint32, Notice> items;
};
struct Source {
  std::shared_ptr<State> state = std::make_shared<State>();
  GDBusConnection *bus = nullptr;
  GDBusConnection *monitor = nullptr;
  guint filter = 0;
  std::string error;
  gint64 next_retry = 0;
  ~Source() {
    if (monitor) {
      if (filter)
        g_dbus_connection_remove_filter(monitor, filter);
      g_dbus_connection_close_sync(monitor, nullptr, nullptr);
      g_object_unref(monitor);
    }
    g_clear_object(&bus);
  }
};
std::string bounded(const gchar *value, glong maximum) {
  g_autofree gchar *text =
      g_utf8_substring(value, 0, std::min(g_utf8_strlen(value, -1), maximum));
  return text;
}
std::string plain_body(const gchar *value) {
  std::string result;
  GMarkupParser parser{};
  parser.text = [](GMarkupParseContext *, const gchar *text, gsize length,
                   gpointer data, GError **) {
    static_cast<std::string *>(data)->append(text, length);
  };
  g_autoptr(GMarkupParseContext) context = g_markup_parse_context_new(
      &parser, G_MARKUP_TREAT_CDATA_AS_TEXT, &result, nullptr);
  auto wrapped = std::string("<root>") + bounded(value, 6000) + "</root>";
  if (!g_markup_parse_context_parse(context, wrapped.c_str(), wrapped.size(),
                                    nullptr) ||
      !g_markup_parse_context_end_parse(context, nullptr))
    return bounded(value, 6000);
  return result;
}
gchar *preference_path() {
  return g_build_filename(g_get_user_config_dir(), "narad",
                          "notification-sharing", nullptr);
}
void stop(Source *source) {
  {
    std::lock_guard<std::mutex> lock(source->state->mutex);
    source->state->active = false;
    source->state->items.clear();
    source->state->pending.clear();
  }
  if (source->monitor) {
    g_dbus_connection_remove_filter(source->monitor, source->filter);
    g_dbus_connection_close_sync(source->monitor, nullptr, nullptr);
    g_clear_object(&source->monitor);
    source->filter = 0;
  }
}
GDBusMessage *observed(GDBusConnection *, GDBusMessage *message,
                       gboolean incoming, gpointer data) {
  if (!incoming)
    return message;
  auto state = *static_cast<std::shared_ptr<State> *>(data);
  std::lock_guard<std::mutex> lock(state->mutex);
  if (!state->active)
    return message;
  const auto type = g_dbus_message_get_message_type(message);
  auto *body = g_dbus_message_get_body(message);
  const auto now = g_get_monotonic_time();
  for (auto it = state->pending.begin(); it != state->pending.end();)
    if (now - it->second.second > 30 * G_USEC_PER_SEC)
      it = state->pending.erase(it);
    else
      ++it;
  if (type == G_DBUS_MESSAGE_TYPE_METHOD_CALL &&
      g_strcmp0(g_dbus_message_get_interface(message),
                "org.freedesktop.Notifications") == 0 &&
      g_strcmp0(g_dbus_message_get_member(message), "Notify") == 0 && body &&
      g_variant_is_of_type(body, G_VARIANT_TYPE("(susssasa{sv}i)"))) {
    const char *sender = g_dbus_message_get_sender(message);
    if (!sender || state->own == sender)
      return message;
    const gchar *app, *icon, *title, *text;
    guint32 replaces;
    gint32 expiry;
    g_autoptr(GVariant) actions = nullptr;
    g_autoptr(GVariant) hints = nullptr;
    g_variant_get(body, "(&su&s&s&s@as@a{sv}i)", &app, &replaces, &icon, &title,
                  &text, &actions, &hints, &expiry);
    gboolean resident = FALSE;
    gint32 progress = -1;
    g_variant_lookup(hints, "resident", "b", &resident);
    g_variant_lookup(hints, "value", "i", &progress);
    gboolean mirrored = FALSE;
    g_variant_lookup(hints, "x-narad-mirrored", "b", &mirrored);
    if (mirrored)
      return message;
    if (state->pending.size() >= 128)
      state->pending.erase(state->pending.begin());
    state->pending[{sender, g_dbus_message_get_serial(message)}] = {
        {(*app ? bounded(app, 120) : std::string("App")), bounded(title, 1000),
         plain_body(text), bounded(icon, 1024), g_get_real_time() / 1000, resident != FALSE, progress},
        now};
  } else if ((type == G_DBUS_MESSAGE_TYPE_METHOD_RETURN ||
              type == G_DBUS_MESSAGE_TYPE_ERROR) &&
             state->server ==
                 std::string(g_dbus_message_get_sender(message)
                                 ? g_dbus_message_get_sender(message)
                                 : "")) {
    const char *destination = g_dbus_message_get_destination(message);
    if (!destination)
      return message;
    auto it = state->pending.find(
        {destination, g_dbus_message_get_reply_serial(message)});
    if (it == state->pending.end())
      return message;
    if (type == G_DBUS_MESSAGE_TYPE_METHOD_RETURN && body &&
        g_variant_is_of_type(body, G_VARIANT_TYPE("(u)"))) {
      guint32 id;
      g_variant_get(body, "(u)", &id);
      state->items[id] = it->second.first;
      while (state->items.size() > 128) {
        auto oldest = std::min_element(state->items.begin(), state->items.end(),
                                       [](const auto &a, const auto &b) {
                                         return a.second.time < b.second.time;
                                       });
        state->items.erase(oldest);
      }
    }
    state->pending.erase(it);
  } else if (type == G_DBUS_MESSAGE_TYPE_SIGNAL &&
             g_strcmp0(g_dbus_message_get_interface(message),
                       "org.freedesktop.Notifications") == 0 &&
             g_strcmp0(g_dbus_message_get_member(message),
                       "NotificationClosed") == 0 &&
             state->server ==
                 std::string(g_dbus_message_get_sender(message)
                                 ? g_dbus_message_get_sender(message)
                                 : "") &&
             body && g_variant_is_of_type(body, G_VARIANT_TYPE("(uu)"))) {
    guint32 id, reason;
    g_variant_get(body, "(uu)", &id, &reason);
    state->items.erase(id);
  }
  return message;
}
GDBusMessage *monitor_filter(GDBusConnection *bus, GDBusMessage *message,
                             gboolean incoming, gpointer data) {
  observed(bus, message, incoming, data);
  // A monitor must not answer intercepted method calls. Only its own setup
  // reply may reach GDBus dispatch, otherwise it would send UnknownObject.
  auto type = g_dbus_message_get_message_type(message);
  if (incoming && !((type == G_DBUS_MESSAGE_TYPE_METHOD_RETURN ||
                     type == G_DBUS_MESSAGE_TYPE_ERROR) &&
                    g_strcmp0(g_dbus_message_get_destination(message),
                              g_dbus_connection_get_unique_name(bus)) == 0)) {
    g_object_unref(message);
    return nullptr;
  }
  return message;
}
bool start(Source *source, GError **error) {
  stop(source);
  source->state = std::make_shared<State>();
  if (!source->bus)
    source->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, error);
  if (!source->bus)
    return false;
  g_autoptr(GVariant) owner = g_dbus_connection_call_sync(
      source->bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "GetNameOwner",
      g_variant_new("(s)", "org.freedesktop.Notifications"),
      G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, error);
  if (!owner)
    return false;
  const gchar *name;
  g_variant_get(owner, "(&s)", &name);
  source->state->server = name;
  source->state->own = g_dbus_connection_get_unique_name(source->bus);
  g_autofree gchar *address =
      g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, error);
  if (!address)
    return false;
  source->monitor = g_dbus_connection_new_for_address_sync(
      address,
      static_cast<GDBusConnectionFlags>(
          G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
          G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
      nullptr, nullptr, error);
  if (!source->monitor)
    return false;
  source->filter = g_dbus_connection_add_filter(
      source->monitor, monitor_filter,
      new std::shared_ptr<State>(source->state), [](gpointer data) {
        delete static_cast<std::shared_ptr<State> *>(data);
      });
  std::string replies =
      "type='method_return',sender='" + source->state->server + "'";
  std::string errors = "type='error',sender='" + source->state->server + "'";
  const gchar *rules[] = {"type='method_call',interface='org.freedesktop."
                          "Notifications',member='Notify'",
                          replies.c_str(), errors.c_str(),
                          "type='signal',interface='org.freedesktop."
                          "Notifications',member='NotificationClosed'",
                          nullptr};
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      source->monitor, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus.Monitoring", "BecomeMonitor",
      g_variant_new("(^asu)", rules, 0u), nullptr, G_DBUS_CALL_FLAGS_NONE, 3000,
      nullptr, error);
  if (!result) {
    stop(source);
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(source->state->mutex);
    source->state->active = true;
  }
  source->error.clear();
  return true;
}
Source *get(GtkApplication *app) {
  auto *source = static_cast<Source *>(
      g_object_get_data(G_OBJECT(app), "narad-notification-source"));
  if (!source) {
    source = new Source();
    g_object_set_data_full(
        G_OBJECT(app), "narad-notification-source", source,
        [](gpointer data) { delete static_cast<Source *>(data); });
    g_autofree gchar *path = preference_path();
    if (g_file_test(path, G_FILE_TEST_EXISTS)) {
      g_autoptr(GError) error = nullptr;
      if (!start(source, &error))
        source->error =
            error ? error->message : "Notification access unavailable";
    }
  }
  return source;
}
} // namespace
bool narad_notification_source_enable(GtkApplication *app, bool enabled,
                                      GError **error) {
  auto *source = get(app);
  g_autofree gchar *path = preference_path();
  if (!enabled) {
    stop(source);
    source->error.clear();
    return !g_file_test(path, G_FILE_TEST_EXISTS) || g_unlink(path) == 0;
  }
  if (!start(source, error)) {
    source->error =
        error && *error ? (*error)->message : "Notification access unavailable";
    return false;
  }
  g_autofree gchar *parent = g_path_get_dirname(path);
  g_mkdir_with_parents(parent, 0700);
  if (!g_file_set_contents(path, "enabled\n", -1, error)) {
    stop(source);
    return false;
  }
  return true;
}
GVariant *narad_notification_source_status(GtkApplication *app) {
  auto *source = get(app);
  if (source->monitor && g_dbus_connection_is_closed(source->monitor)) {
    stop(source);
    source->error = "Notification connection lost. Reconnecting…";
  }
  if (source->state->active) {
    g_autoptr(GVariant) owner = g_dbus_connection_call_sync(
        source->bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetNameOwner",
        g_variant_new("(s)", "org.freedesktop.Notifications"),
        G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, 1000, nullptr, nullptr);
    const gchar *name = nullptr;
    if (owner)
      g_variant_get(owner, "(&s)", &name);
    if (!name || source->state->server != name) {
      stop(source);
      source->error = "Notification service restarted. Reconnecting…";
    }
  }
  g_autofree gchar *path = preference_path();
  if (!source->state->active && g_file_test(path, G_FILE_TEST_EXISTS) &&
      g_get_monotonic_time() >= source->next_retry) {
    source->next_retry = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
    g_autoptr(GError) error = nullptr;
    if (!start(source, &error))
      source->error =
          error ? error->message : "Notification access unavailable";
  }
  GVariantBuilder result;
  g_variant_builder_init(&result, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&result, "{sv}", "supported",
                        g_variant_new_boolean(TRUE));
  g_variant_builder_add(&result, "{sv}", "enabled",
                        g_variant_new_boolean(source->state->active));
  g_variant_builder_add(&result, "{sv}", "error",
                        g_variant_new_string(source->error.c_str()));
  return g_variant_builder_end(&result);
}
GVariant *narad_notification_source_items(GtkApplication *app) {
  auto *source = get(app);
  std::vector<std::pair<guint32, Notice>> items;
  {
    std::lock_guard<std::mutex> lock(source->state->mutex);
    items.assign(source->state->items.begin(), source->state->items.end());
  }
  std::sort(items.begin(), items.end(), [](const auto &a, const auto &b) {
    return a.second.time > b.second.time;
  });
  GVariantBuilder result;
  g_variant_builder_init(&result, G_VARIANT_TYPE("aa{sv}"));
  unsigned count = 0;
  std::map<std::string, std::string> icons;
  for (const auto &pair : items) {
    if (++count > 30)
      break;
    GVariantBuilder item;
    g_variant_builder_init(&item, G_VARIANT_TYPE_VARDICT);
    auto key = "linux:" + std::to_string(pair.first);
    for (const auto &field : std::vector<std::pair<const char *, std::string>>{
             {"key", key},
             {"app", pair.second.app},
             {"title", pair.second.title},
             {"text", pair.second.text}})
      g_variant_builder_add(&item, "{sv}", field.first,
                            g_variant_new_string(field.second.c_str()));
    const auto &icon = pair.second.icon;
    if (!icon.empty()) {
      if (!icons.count(icon)) {
        GdkPixbuf *raw = nullptr;
        if (g_path_is_absolute(icon.c_str())) {
          GStatBuf info;
          if (g_stat(icon.c_str(), &info) == 0 && info.st_size <= 1024 * 1024)
            raw = gdk_pixbuf_new_from_file_at_scale(icon.c_str(), 32, 32, TRUE,
                                                    nullptr);
        } else if (icon.find('/') == std::string::npos) {
          raw = gtk_icon_theme_load_icon(gtk_icon_theme_get_default(),
                                         icon.c_str(), 32,
                                         GTK_ICON_LOOKUP_FORCE_SIZE, nullptr);
        }
        g_autoptr(GdkPixbuf) image = raw;
        if (image) {
          g_autoptr(GdkPixbuf) scaled =
              gdk_pixbuf_scale_simple(image, 32, 32, GDK_INTERP_BILINEAR);
          gchar *bytes = nullptr;
          gsize length = 0;
          if (gdk_pixbuf_save_to_buffer(scaled, &bytes, &length, "png", nullptr,
                                        nullptr)) {
            if (length <= 6144) {
              g_autofree gchar *encoded =
                  g_base64_encode(reinterpret_cast<guchar *>(bytes), length);
              icons[icon] = encoded;
            }
            g_free(bytes);
          }
        }
        if (!icons.count(icon))
          icons[icon] = "";
      }
      if (!icons[icon].empty())
        g_variant_builder_add(&item, "{sv}", "icon",
                              g_variant_new_string(icons[icon].c_str()));
    }
    g_variant_builder_add(&item, "{sv}", "time",
                          g_variant_new_int64(pair.second.time));
    g_variant_builder_add(&item, "{sv}", "ongoing", g_variant_new_boolean(pair.second.ongoing));
    if (pair.second.progress >= 0) {
      g_variant_builder_add(&item, "{sv}", "progress", g_variant_new_int64(pair.second.progress));
      g_variant_builder_add(&item, "{sv}", "progressMax", g_variant_new_int64(100));
    }
    g_variant_builder_add(&item, "{sv}", "reply", g_variant_new_boolean(FALSE));
    g_variant_builder_add(&item, "{sv}", "dismissible",
                          g_variant_new_boolean(TRUE));
    g_variant_builder_add(
        &item, "{sv}", "actions",
        g_variant_new_array(G_VARIANT_TYPE_VARDICT, nullptr, 0));
    g_variant_builder_add(&result, "@a{sv}", g_variant_builder_end(&item));
  }
  return g_variant_builder_end(&result);
}
bool narad_notification_source_dismiss(GtkApplication *app, const char *key,
                                       GError **error) {
  auto *source = get(app);
  guint64 id = 0;
  if (!g_str_has_prefix(key, "linux:") ||
      !g_ascii_string_to_unsigned(key + 6, 10, 1, G_MAXUINT32, &id, error))
    return false;
  {
    std::lock_guard<std::mutex> lock(source->state->mutex);
    if (!source->state->active || !source->state->items.count(id)) {
      g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                          "Notification is no longer available");
      return false;
    }
  }
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(
      source->bus, "org.freedesktop.Notifications",
      "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
      "CloseNotification", g_variant_new("(u)", static_cast<guint32>(id)),
      nullptr, G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, error);
  return result != nullptr;
}
