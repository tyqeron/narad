#ifndef NARAD_NOTIFICATION_SOURCE_H_
#define NARAD_NOTIFICATION_SOURCE_H_
#include <gtk/gtk.h>
bool narad_notification_source_enable(GtkApplication *app, bool enabled,
                                      GError **error);
GVariant *narad_notification_source_status(GtkApplication *app);
GVariant *narad_notification_source_items(GtkApplication *app);
bool narad_notification_source_dismiss(GtkApplication *app, const char *key,
                                       GError **error);
#endif
