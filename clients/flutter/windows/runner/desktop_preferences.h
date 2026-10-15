#ifndef NARAD_DESKTOP_PREFERENCES_H_
#define NARAD_DESKTOP_PREFERENCES_H_
#include <string>
bool NaradAutostartEnabled();
bool NaradSetAutostart(bool enabled, std::string *error);
#endif
