#include "notification_source.h"
#include <algorithm>
#include <charconv>
#include <vector>
#include <windows.h>
#include <appmodel.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.Management.h>
#include <winrt/Windows.UI.Notifications.h>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::UI::Notifications;
using namespace winrt::Windows::UI::Notifications::Management;
namespace {
constexpr wchar_t kPreferences[] = L"Software\\Narad";
bool packaged() {
  UINT32 length = 0;
  return GetCurrentPackageFullName(&length, nullptr) ==
         ERROR_INSUFFICIENT_BUFFER;
}
bool preference() {
  DWORD value = 0, size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, kPreferences, L"NotificationSharing",
                      RRF_RT_REG_DWORD, nullptr, &value,
                      &size) == ERROR_SUCCESS &&
         value == 1;
}
void preference(bool enabled) {
  HKEY key = nullptr;
  winrt::check_win32(RegCreateKeyExW(HKEY_CURRENT_USER, kPreferences, 0,
                                     nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                                     nullptr));
  DWORD value = enabled ? 1 : 0;
  const auto result =
      RegSetValueExW(key, L"NotificationSharing", 0, REG_DWORD,
                     reinterpret_cast<const BYTE *>(&value), sizeof(value));
  RegCloseKey(key);
  winrt::check_win32(result);
}
std::wstring own_id() {
  UINT32 length = 0;
  if (GetCurrentApplicationUserModelId(&length, nullptr) !=
      ERROR_INSUFFICIENT_BUFFER)
    return L"dev.narad.narad_client";
  std::wstring id(length, L'\0');
  if (GetCurrentApplicationUserModelId(&length, id.data()) != ERROR_SUCCESS)
    return L"dev.narad.narad_client";
  if (!id.empty() && id.back() == L'\0')
    id.pop_back();
  return id;
}
bool own(const UserNotification &notice) {
  const auto info = notice.AppInfo();
  if (!info)
    return true;
  const std::wstring id(info.AppUserModelId());
  return id == own_id() || id == L"dev.narad.narad_client";
}
EncodableValue status() {
  bool supported = packaged(), enabled = false;
  std::string error;
  if (!supported)
    error = "Install Narad MSIX to share Windows notifications. The ZIP build "
            "can receive notifications.";
  else {
    const auto access = UserNotificationListener::Current().GetAccessStatus();
    enabled =
        preference() && access == UserNotificationListenerAccessStatus::Allowed;
    if (preference() && !enabled)
      error = "Allow Narad notification access in Windows Settings, then turn "
              "sharing on again.";
  }
  return EncodableValue(
      EncodableMap{{EncodableValue("supported"), EncodableValue(supported)},
                   {EncodableValue("enabled"), EncodableValue(enabled)},
                   {EncodableValue("error"), EncodableValue(error)}});
}
EncodableMap arguments(const EncodableValue *value) {
  if (value)
    if (auto *map = std::get_if<EncodableMap>(value))
      return *map;
  return {};
}
std::string text(const winrt::hstring &value, size_t limit) {
  auto shortened = std::wstring(value).substr(0, limit);
  // Do not split a UTF-16 surrogate pair at the bound.
  if (!shortened.empty() && shortened.back() >= 0xD800 &&
      shortened.back() <= 0xDBFF)
    shortened.pop_back();
  return winrt::to_string(shortened);
}
} // namespace
WindowsNotificationSource::WindowsNotificationSource() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
}
WindowsNotificationSource::~WindowsNotificationSource() {
  winrt::uninit_apartment();
}
bool WindowsNotificationSource::Handles(const std::string &method) {
  return method == "notificationSourceStatus" ||
         method == "setNotificationSharing" ||
         method == "desktopNotifications" ||
         method == "dismissDesktopNotification";
}
void WindowsNotificationSource::Handle(
    std::string method, const EncodableValue *raw,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  // Parameters are copied before suspension. WinRT resumes in the UI apartment,
  // so Flutter replies never run on a worker thread.
  static const auto run =
      [](std::shared_ptr<WindowsNotificationSource> self, std::string method,
         EncodableMap args,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result)
      -> winrt::fire_and_forget {
    try {
      if (method == "notificationSourceStatus") {
        result->Success(status());
        co_return;
      }
      if (method == "setNotificationSharing") {
        auto found = args.find(EncodableValue("enabled"));
        if (found == args.end() || !std::holds_alternative<bool>(found->second))
          throw winrt::hresult_invalid_argument(L"Expected enabled boolean");
        bool enabled = std::get<bool>(found->second);
        if (enabled) {
          if (!packaged())
            throw winrt::hresult_error(
                E_ACCESSDENIED, L"Install the MSIX package before enabling "
                                L"Windows notification capture.");
          auto access =
              co_await UserNotificationListener::Current().RequestAccessAsync();
          if (self->closed_)
            co_return;
          if (access != UserNotificationListenerAccessStatus::Allowed)
            throw winrt::hresult_error(
                E_ACCESSDENIED, L"Allow Narad notification access in Windows "
                                L"Settings to share desktop notifications.");
        }
        preference(enabled);
        if (!enabled)
          self->visible_.clear();
        result->Success();
        co_return;
      }
      if (!packaged() || !preference())
        throw winrt::hresult_error(
            E_ACCESSDENIED, L"Desktop notification sharing is disabled.");
      auto listener = UserNotificationListener::Current();
      if (listener.GetAccessStatus() !=
          UserNotificationListenerAccessStatus::Allowed) {
        self->visible_.clear();
        throw winrt::hresult_error(E_ACCESSDENIED,
                                   L"Windows notification access was revoked.");
      }
      if (method == "desktopNotifications") {
        auto raw_notices =
            co_await listener.GetNotificationsAsync(NotificationKinds::Toast);
        std::vector<UserNotification> notices;
        for (const auto &notice : raw_notices)
          notices.push_back(notice);
        std::sort(notices.begin(), notices.end(),
                  [](const auto &a, const auto &b) {
                    return a.CreationTime() > b.CreationTime();
                  });
        if (self->closed_)
          co_return;
        EncodableList items;
        self->visible_.clear();
        for (const auto &notice : notices) {
          if (items.size() >= 30)
            break;
          try {
            if (own(notice))
              continue;
            const auto binding = notice.Notification().Visual().GetBinding(
                KnownNotificationBindings::ToastGeneric());
            if (!binding)
              continue;
            auto lines = binding.GetTextElements();
            std::string title, body;
            for (uint32_t index = 0; index < lines.Size(); ++index) {
              auto line =
                  text(lines.GetAt(index).Text(), index == 0 ? 1000 : 2000);
              if (index == 0)
                title = line;
              else {
                if (!body.empty())
                  body += '\n';
                body += line;
              }
              if (body.size() > 12000)
                break;
            }
            const auto id = notice.Id();
            self->visible_.insert(id);
            const auto timestamp =
                notice.CreationTime().time_since_epoch().count() / 10000 -
                11644473600000LL;
            items.emplace_back(EncodableMap{
                {EncodableValue("key"),
                 EncodableValue("windows:" + std::to_string(id))},
                {EncodableValue("app"),
                 EncodableValue(
                     text(notice.AppInfo().DisplayInfo().DisplayName(), 120))},
                {EncodableValue("title"), EncodableValue(title)},
                {EncodableValue("text"), EncodableValue(body)},
                {EncodableValue("time"),
                 EncodableValue(static_cast<int64_t>(timestamp))},
                {EncodableValue("reply"), EncodableValue(false)},
                {EncodableValue("actions"), EncodableValue(EncodableList{})},
                {EncodableValue("dismissible"), EncodableValue(true)}});
          } catch (
              const winrt::hresult_error
                  &) { /* One inaccessible notice must not discard the rest. */
          }
        }
        result->Success(EncodableValue(items));
        co_return;
      }
      auto found = args.find(EncodableValue("key"));
      if (found == args.end() ||
          !std::holds_alternative<std::string>(found->second))
        throw winrt::hresult_invalid_argument(L"Missing notification key");
      const auto key = std::get<std::string>(found->second);
      uint32_t id = 0;
      if (key.rfind("windows:", 0) != 0)
        throw winrt::hresult_invalid_argument(L"Invalid notification key");
      const auto parsed =
          std::from_chars(key.data() + 8, key.data() + key.size(), id);
      if (parsed.ec != std::errc{} || parsed.ptr != key.data() + key.size() ||
          !self->visible_.count(id))
        throw winrt::hresult_invalid_argument(
            L"Notification is no longer available");
      auto current = listener.GetNotification(id);
      if (!current || own(current))
        throw winrt::hresult_invalid_argument(
            L"Notification is no longer available");
      listener.RemoveNotification(id);
      self->visible_.erase(id);
      result->Success();
    } catch (const winrt::hresult_error &error) {
      if (!self->closed_)
        result->Error("notification_source", winrt::to_string(error.message()));
    } catch (const std::exception &error) {
      if (!self->closed_)
        result->Error("notification_source", error.what());
    }
  };
  run(shared_from_this(), std::move(method), arguments(raw), std::move(result));
}
