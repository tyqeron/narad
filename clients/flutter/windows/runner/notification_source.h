#ifndef NARAD_WINDOWS_NOTIFICATION_SOURCE_H_
#define NARAD_WINDOWS_NOTIFICATION_SOURCE_H_
#include <atomic>
#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>
#include <set>
#include <string>

class WindowsNotificationSource
    : public std::enable_shared_from_this<WindowsNotificationSource> {
public:
  WindowsNotificationSource();
  ~WindowsNotificationSource();
  static bool Handles(const std::string &method);
  void Handle(
      std::string method, const flutter::EncodableValue *arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Close() { closed_ = true; }

private:
  std::atomic<bool> closed_{false};
  std::set<uint32_t> visible_;
};
#endif
