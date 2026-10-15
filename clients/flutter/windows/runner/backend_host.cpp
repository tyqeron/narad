#include "backend_host.h"
#include <shlobj.h>
#include <filesystem>
#include <vector>

namespace {
std::wstring Quote(const std::wstring& value) {
  // Windows CRT argument quoting, including trailing backslashes and quotes.
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : value) {
    if (c == L'\\') { ++slashes; continue; }
    if (c == L'\"') result.append(slashes * 2 + 1, L'\\');
    else result.append(slashes, L'\\');
    slashes = 0;
    result += c;
  }
  result.append(slashes * 2, L'\\');
  return result + L"\"";
}
}
BackendHost::~BackendHost() { Close(); }
void BackendHost::Close() {
  // KILL_ON_JOB_CLOSE also handles a crashed GUI or command descendants.
  if (job_) { CloseHandle(job_); job_ = nullptr; }
  if (process_) { CloseHandle(process_); process_ = nullptr; }
}
bool BackendHost::Configure() {
  if (!state_directory_.empty()) return true;
  std::vector<wchar_t> path(32768);
  DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) { error_ = "Cannot locate the Narad executable."; return false; }
  executable_directory_ = std::filesystem::path(path.data()).parent_path().wstring();
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local))) {
    error_ = "Cannot locate your Windows application data folder."; return false;
  }
  state_directory_ = std::wstring(local) + L"\\Narad\\state";
  CoTaskMemFree(local);
  return true;
}
bool BackendHost::Running() const {
  return process_ && WaitForSingleObject(process_, 0) == WAIT_TIMEOUT;
}
bool BackendHost::Start() {
  if (!Configure()) return false;
  if (Running()) return true;
  Close();
  error_.clear();
  const std::wstring executable = executable_directory_ + L"\\narad.exe";
  if (GetFileAttributesW(executable.c_str()) == INVALID_FILE_ATTRIBUTES) {
    error_ = "narad.exe is missing. Extract the entire Windows package, including its DLLs.";
    return false;
  }
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (!job_) { error_ = "Cannot create the Narad process job."; return false; }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
    error_ = "Cannot configure the Narad process job."; Close(); return false;
  }
  wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
  if (!GetComputerNameW(computer, &size)) wcscpy_s(computer, L"Windows PC");
  std::wstring args = Quote(executable) + L" --state " + Quote(state_directory_) +
      L" serve --name " + Quote(computer);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  // Start suspended so no descendants can escape job ownership before assignment.
  if (!CreateProcessW(executable.c_str(), args.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                      executable_directory_.c_str(), &startup, &process)) {
    error_ = "Cannot start narad.exe (Windows error " + std::to_string(GetLastError()) + ").";
    Close(); return false;
  }
  process_ = process.hProcess;
  bool assigned = AssignProcessToJobObject(job_, process_) != FALSE;
  bool resumed = assigned && ResumeThread(process.hThread) != static_cast<DWORD>(-1);
  CloseHandle(process.hThread);
  if (!resumed) {
    TerminateProcess(process_, 1);
    error_ = "Cannot supervise the Narad backend process."; Close(); return false;
  }
  return true;
}
