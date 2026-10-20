#ifndef NARAD_SYSTEM_TRAY_H_
#define NARAD_SYSTEM_TRAY_H_
#include <gtk/gtk.h>
struct NaradSystemTray;
NaradSystemTray *narad_system_tray_new(GtkApplication *app, const gchar *icon);
void narad_system_tray_free(NaradSystemTray *tray);
#endif
