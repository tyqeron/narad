#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <optional>

#include "backend_host.h"
#include "notification_source.h"
#include "win32_window.h"
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject &project);
  virtual ~FlutterWindow();
  void SetStartHidden(bool hidden) { start_hidden_ = hidden; }

protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

private:
  bool start_hidden_ = false;
  bool quitting_ = false;
  bool quit_requested_ = false;
  bool tray_added_ = false;
  bool dart_ready_ = false;
  std::optional<flutter::EncodableList> pending_shared_;
  void AddTray();
  void RemoveTray();
  BackendHost backend_;
  std::shared_ptr<WindowsNotificationSource> notification_source_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      backend_channel_;
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif // RUNNER_FLUTTER_WINDOW_H_
