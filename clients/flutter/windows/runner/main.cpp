#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // One desktop window per signed-in session; a second launch restores it.
  HANDLE singleton = CreateMutexW(nullptr, FALSE, L"Local\\NaradDesktopWindow");
  if (!singleton)
    return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Narad");
    if (existing) {
      const auto arguments = GetCommandLineArguments();
      std::vector<std::wstring> shared;
      for (const auto &arg : arguments) {
        if (arg == "--share" || arg == "--background") continue;
        if (!arg.empty() && arg[0] != '-') {
          const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, arg.c_str(), -1, nullptr, 0);
          if (size > 1) { std::wstring converted(size, L'\0'); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, arg.c_str(), -1, converted.data(), size); converted.pop_back(); shared.push_back(std::move(converted)); }
        }
      }
      if (!shared.empty()) {
        std::vector<wchar_t> payload;
        for (const auto &value : shared) { payload.insert(payload.end(), value.begin(), value.end()); payload.push_back(L'\0'); }
        payload.push_back(L'\0');
        COPYDATASTRUCT data{}; data.dwData = 0x4E415241; data.cbData = static_cast<DWORD>(payload.size() * sizeof(wchar_t)); data.lpData = payload.data();
        DWORD_PTR ignored = 0;
        SendMessageTimeoutW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 3000, &ignored);
      } else PostMessageW(existing, WM_APP + 11, 0, 0);
    }
    CloseHandle(singleton);
    CoUninitialize();
    return EXIT_SUCCESS;
  }
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  bool start_hidden = false;
  for (const auto &arg : command_line_arguments)
    if (arg == "--background")
      start_hidden = true;
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartHidden(start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Narad", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  CloseHandle(singleton);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
