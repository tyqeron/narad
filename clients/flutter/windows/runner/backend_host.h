#ifndef NARAD_BACKEND_HOST_H_
#define NARAD_BACKEND_HOST_H_
#include <windows.h>
#include <string>

// Owns only the daemon launched by this window; never terminates a reused daemon.
class BackendHost {
 public:
  BackendHost() = default;
  ~BackendHost();
  BackendHost(const BackendHost&) = delete;
  BackendHost& operator=(const BackendHost&) = delete;
  bool Configure();
  bool Start();
  bool Running() const;
  const std::wstring& state_directory() const { return state_directory_; }
  const std::string& error() const { return error_; }
 private:
  void Close();
  std::wstring executable_directory_;
  std::wstring state_directory_;
  std::string error_;
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
};
#endif
