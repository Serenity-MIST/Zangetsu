#include "desktop_registry.h"

#include <flutter_windows.h>
#include <shellapi.h>

#include <algorithm>
#include <string>

namespace {

// Placement memory lives next to nothing else of ours, so a reset is just
// deleting this one key.
constexpr wchar_t kWindowKey[] = L"Software\\Zangetsu\\Window";
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Zangetsu";
constexpr wchar_t kAutostartFlag[] = L"--autostart";

// Reads one DWORD from HKCU\|key|; false when missing or of another type.
bool ReadDword(const wchar_t* key, const wchar_t* name, DWORD* value) {
  DWORD size = sizeof(DWORD);
  return ::RegGetValueW(HKEY_CURRENT_USER, key, name, RRF_RT_REG_DWORD,
                        nullptr, value, &size) == ERROR_SUCCESS;
}

// Writes one DWORD under HKCU\|key|, creating the key when needed.
void WriteDword(HKEY key, const wchar_t* name, DWORD value) {
  ::RegSetValueExW(key, name, 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&value), sizeof(value));
}

// Full path of this executable, or empty when Windows cannot report it.
std::wstring ExecutablePath() {
  wchar_t path[32768];
  const DWORD length = ::GetModuleFileNameW(nullptr, path, 32768);
  if (length == 0 || length >= 32768) return std::wstring();
  return std::wstring(path, length);
}

// GetWindowPlacement reports "workspace" coordinates, which are offset by
// any taskbar docked at the top/left of the primary monitor. Returns the
// offset to add to turn them into screen coordinates.
POINT WorkspaceToScreenOffset() {
  POINT offset = {0, 0};
  MONITORINFO primary = {sizeof(MONITORINFO)};
  const POINT origin = {0, 0};
  if (::GetMonitorInfoW(::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY),
                        &primary)) {
    offset.x = primary.rcWork.left - primary.rcMonitor.left;
    offset.y = primary.rcWork.top - primary.rcMonitor.top;
  }
  return offset;
}

// First-run frame: centred on the monitor under the cursor, about 80% of
// its work area, never below the window's 800x560 minimum (DPI-scaled).
InitialWindowRect DefaultWindowRect() {
  POINT cursor = {0, 0};
  ::GetCursorPos(&cursor);
  const HMONITOR monitor = ::MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {sizeof(MONITORINFO)};
  InitialWindowRect result = {{0, 0, 1280, 720}, false};
  if (!::GetMonitorInfoW(monitor, &info)) return result;
  const RECT work = info.rcWork;
  const LONG work_width = work.right - work.left;
  const LONG work_height = work.bottom - work.top;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const LONG min_width = ::MulDiv(800, dpi, 96);
  const LONG min_height = ::MulDiv(560, dpi, 96);
  // 80% of the work area, but at least the minimum and at most the area.
  const LONG width =
      (std::min)(work_width, (std::max)(min_width, work_width * 8 / 10));
  const LONG height =
      (std::min)(work_height, (std::max)(min_height, work_height * 8 / 10));
  result.frame.left = work.left + (work_width - width) / 2;
  result.frame.top = work.top + (work_height - height) / 2;
  result.frame.right = result.frame.left + width;
  result.frame.bottom = result.frame.top + height;
  return result;
}

}  // namespace

bool IsRememberWindowPlacementEnabled() {
  DWORD remember = 1;
  // A missing value means the user never turned it off: default on.
  if (!ReadDword(kWindowKey, L"Remember", &remember)) return true;
  return remember != 0;
}

void SetRememberWindowPlacementEnabled(bool enabled) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kWindowKey, 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  WriteDword(key, L"Remember", enabled ? 1 : 0);
  ::RegCloseKey(key);
}

InitialWindowRect ComputeInitialWindowRect() {
  if (!IsRememberWindowPlacementEnabled()) return DefaultWindowRect();
  DWORD left, top, right, bottom, maximized = 0;
  if (!ReadDword(kWindowKey, L"Left", &left) ||
      !ReadDword(kWindowKey, L"Top", &top) ||
      !ReadDword(kWindowKey, L"Right", &right) ||
      !ReadDword(kWindowKey, L"Bottom", &bottom)) {
    return DefaultWindowRect();
  }
  ReadDword(kWindowKey, L"Maximized", &maximized);
  // Coordinates are stored as signed values (monitors left of or above the
  // primary have negative coordinates).
  InitialWindowRect saved = {
      {static_cast<LONG>(left), static_cast<LONG>(top),
       static_cast<LONG>(right), static_cast<LONG>(bottom)},
      maximized != 0};
  // Reject nonsense sizes from a damaged key.
  if (saved.frame.right - saved.frame.left < 200 ||
      saved.frame.bottom - saved.frame.top < 150) {
    return DefaultWindowRect();
  }
  // The monitor it lived on may be unplugged; then fall back to the default
  // rather than opening off-screen.
  if (::MonitorFromRect(&saved.frame, MONITOR_DEFAULTTONULL) == nullptr) {
    return DefaultWindowRect();
  }
  return saved;
}

void SaveWindowPlacement(const WINDOWPLACEMENT& placement) {
  if (!IsRememberWindowPlacementEnabled()) return;
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kWindowKey, 0, nullptr, 0,
                        KEY_WRITE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  // Store the normal (restored) frame in screen coordinates plus whether
  // the window was maximised, so reopening restores both.
  const POINT offset = WorkspaceToScreenOffset();
  RECT frame = placement.rcNormalPosition;
  ::OffsetRect(&frame, offset.x, offset.y);
  const bool maximized =
      placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.showCmd == SW_SHOWMINIMIZED &&
       (placement.flags & WPF_RESTORETOMAXIMIZED) != 0);
  WriteDword(key, L"Left", static_cast<DWORD>(frame.left));
  WriteDword(key, L"Top", static_cast<DWORD>(frame.top));
  WriteDword(key, L"Right", static_cast<DWORD>(frame.right));
  WriteDword(key, L"Bottom", static_cast<DWORD>(frame.bottom));
  WriteDword(key, L"Maximized", maximized ? 1 : 0);
  // The monitor's device name is informational (the frame alone decides
  // where the window reopens) but makes support reports easier to read.
  MONITORINFOEXW monitor = {};
  monitor.cbSize = sizeof(MONITORINFOEXW);
  if (::GetMonitorInfoW(::MonitorFromRect(&frame, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
    ::RegSetValueExW(
        key, L"Monitor", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(monitor.szDevice),
        static_cast<DWORD>((wcslen(monitor.szDevice) + 1) * sizeof(wchar_t)));
  }
  ::RegCloseKey(key);
}

bool IsLaunchAtSignInEnabled() {
  DWORD size = 0;
  return ::RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                        nullptr, nullptr, &size) == ERROR_SUCCESS;
}

bool SetLaunchAtSignIn(bool enabled) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status;
  if (enabled) {
    const std::wstring executable = ExecutablePath();
    if (executable.empty()) {
      ::RegCloseKey(key);
      return false;
    }
    // Quoted path survives spaces; the flag lets the app know it was not
    // opened by the user directly.
    const std::wstring command =
        L"\"" + executable + L"\" " + std::wstring(kAutostartFlag);
    status = ::RegSetValueExW(
        key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = ::RegDeleteValueW(key, kRunValue);
    // Already absent counts as success.
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

bool WasLaunchedAtSignIn() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) return false;
  bool found = false;
  // Skip argv[0], the executable itself.
  for (int i = 1; i < argc && !found; ++i) {
    found = wcscmp(argv[i], kAutostartFlag) == 0;
  }
  ::LocalFree(argv);
  return found;
}

bool RelaunchCurrentProcess() {
  const std::wstring executable = ExecutablePath();
  if (executable.empty()) return false;
  // Start with the executable alone: the original arguments could hold a
  // zangetsu:// sign-in link (replaying it would reuse a spent OAuth code)
  // or --autostart (the restart was asked for by the user, not sign-in).
  // CreateProcessW may write into the command line buffer, so it is a copy.
  std::wstring command_line = L"\"" + executable + L"\"";
  STARTUPINFOW startup = {sizeof(STARTUPINFOW)};
  PROCESS_INFORMATION process = {};
  if (!::CreateProcessW(executable.c_str(), command_line.data(), nullptr,
                        nullptr, FALSE, 0, nullptr, nullptr, &startup,
                        &process)) {
    return false;
  }
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return true;
}
