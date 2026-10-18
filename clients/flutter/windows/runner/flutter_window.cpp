#include "flutter_window.h"

#include "desktop_preferences.h"
#include "resource.h"
#include "utils.h"
#include <flutter/standard_method_codec.h>
#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { RemoveTray(); }
void FlutterWindow::AddTray() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = WM_APP + 10;
  icon.hIcon =
      LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Narad · available nearby");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}
void FlutterWindow::RemoveTray() {
  if (!tray_added_)
    return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_added_ = false;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  backend_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.narad/windows",
          &flutter::StandardMethodCodec::GetInstance());
  backend_channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    if (call.method_name() == "configuration") {
      if (!backend_.Configure()) {
        result->Error("windows_backend", backend_.error());
        return;
      }
      result->Success(flutter::EncodableValue(
          flutter::EncodableMap{{flutter::EncodableValue("stateDirectory"),
                                 flutter::EncodableValue(Utf8FromUtf16(
                                     backend_.state_directory().c_str()))},
                                {flutter::EncodableValue("apiPort"),
                                 flutter::EncodableValue(45700)}}));
    } else if (call.method_name() == "start") {
      if (backend_.Start())
        result->Success();
      else
        result->Error("windows_backend", backend_.error());
    } else if (call.method_name() == "running") {
      result->Success(flutter::EncodableValue(backend_.Running()));
    } else if (call.method_name() == "desktopStatus") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("autostart"),
           flutter::EncodableValue(NaradAutostartEnabled())}}));
    } else if (call.method_name() == "setAutostart") {
      const auto *args =
          call.arguments()
              ? std::get_if<flutter::EncodableMap>(call.arguments())
              : nullptr;
      if (!args) {
        result->Error("arguments", "Expected enabled boolean");
        return;
      }
      const auto found = args->find(flutter::EncodableValue("enabled"));
      const bool *enabled =
          found == args->end() ? nullptr : std::get_if<bool>(&found->second);
      if (!enabled) {
        result->Error("arguments", "Expected enabled boolean");
        return;
      }
      std::string error;
      if (NaradSetAutostart(*enabled, &error))
        result->Success();
      else
        result->Error("autostart", error);
    } else if (call.method_name() == "show") {
      ShowWindow(GetHandle(), SW_SHOW);
      SetForegroundWindow(GetHandle());
      result->Success();
    } else if (call.method_name() == "quit") {
      quitting_ = true;
      result->Success();
      PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
    }
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  AddTray();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_)
      this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTray();
  backend_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created) {
    tray_added_ = false;
    AddTray();
    return 0;
  }
  if (message == WM_APP + 11) {
    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);
    return 0;
  }
  if (message == WM_TIMER && wparam == 47001) {
    KillTimer(hwnd, 47001);
    quitting_ = true;
    PostMessageW(hwnd, WM_CLOSE, 0, 0);
    return 0;
  }
  if (message == WM_CLOSE && !quitting_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == WM_APP + 10) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK || lparam == NIN_BALLOONUSERCLICK) {
      ShowWindow(hwnd, SW_SHOW);
      SetForegroundWindow(hwnd);
    } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      POINT point{};
      GetCursorPos(&point);
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Open Narad");
      AppendMenuW(menu, MF_STRING, 2, L"Quit Narad");
      SetForegroundWindow(hwnd);
      const UINT choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                         point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessageW(hwnd, WM_NULL, 0, 0);
      if (choice == 1) {
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
      }
      if (choice == 2 && !quit_requested_) {
        quit_requested_ = true;
        SetTimer(hwnd, 47001, 30000, nullptr);
        backend_channel_->InvokeMethod("prepareQuit", nullptr);
      }
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
  case WM_FONTCHANGE:
    flutter_controller_->engine()->ReloadSystemFonts();
    break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
