#ifndef NARAD_DESKTOP_INTEGRATION_H_
#define NARAD_DESKTOP_INTEGRATION_H_
#include <flutter_linux/flutter_linux.h>
void narad_register_desktop(FlView *view, GtkApplication *application);
void narad_desktop_open_files(GtkApplication *application, GFile **files, gint count);
void narad_desktop_flush_pending(GtkApplication *application);
void narad_request_quit(GtkApplication *application);
#endif
