#include "desktop_preferences.h"
#include <vector>
#include <windows.h>
namespace {
constexpr wchar_t kRun[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kPrefs[] = L"Software\\Narad";
} // namespace
bool NaradAutostartEnabled() {
  DWORD bytes = 0;
  return RegGetValueW(HKEY_CURRENT_USER, kRun, L"Narad", RRF_RT_REG_SZ, nullptr,
                      nullptr, &bytes) == ERROR_SUCCESS &&
         bytes > sizeof(wchar_t);
}
bool NaradSetAutostart(bool enabled, std::string *error) {
  HKEY run = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRun, 0, nullptr, 0,
                                   KEY_SET_VALUE, nullptr, &run, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = "Cannot access your Windows startup settings.";
    return false;
  }
  if (enabled) {
    std::vector<wchar_t> path(32768);
    DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                      static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) {
      RegCloseKey(run);
      *error = "Cannot locate the Narad executable.";
      return false;
    }
    // Windows paths cannot contain a quotation mark.
    const std::wstring command =
        L"\"" + std::wstring(path.data()) + L"\" --background";
    status = RegSetValueExW(
        run, L"Narad", 0, REG_SZ,
        reinterpret_cast<const BYTE *>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(run, L"Narad");
    if (status == ERROR_FILE_NOT_FOUND)
      status = ERROR_SUCCESS;
  }
  RegCloseKey(run);
  if (status != ERROR_SUCCESS) {
    *error = "Cannot update your Windows startup entry.";
    return false;
  }
  HKEY prefs = nullptr;
  status = RegCreateKeyExW(HKEY_CURRENT_USER, kPrefs, 0, nullptr, 0,
                           KEY_SET_VALUE, nullptr, &prefs, nullptr);
  if (status == ERROR_SUCCESS) {
    DWORD value = enabled ? 1 : 0;
    status =
        RegSetValueExW(prefs, L"StartAtLogin", 0, REG_DWORD,
                       reinterpret_cast<const BYTE *>(&value), sizeof(value));
    RegCloseKey(prefs);
  }
  if (status != ERROR_SUCCESS) {
    *error = "Startup changed, but your preference could not be saved.";
    return false;
  }
  return true;
}
