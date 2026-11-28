#ifndef RUNNER_DESKTOP_SHELL_H_
#define RUNNER_DESKTOP_SHELL_H_

#include <windows.h>
#include <shobjidl.h>

#include <functional>
#include <optional>
#include <string>

// Window messages shared between the runner pieces. WM_APP based ids are
// private to our own window; the restore message is registered by name so
// a second launch (another process) can post it.
constexpr UINT kTrayIconMessage = WM_APP + 0x40;
constexpr UINT kMediaCommandMessage = WM_APP + 0x41;
constexpr wchar_t kRestoreWindowMessageName[] = L"Zangetsu.RestoreWindow";

// Thumbnail toolbar button ids, delivered as WM_COMMAND/THBN_CLICKED.
constexpr UINT kThumbPrevious = 0x5A01;
constexpr UINT kThumbPlayPause = 0x5A02;
constexpr UINT kThumbNext = 0x5A03;

// Media command kinds. The order matches the Dart DesktopMediaCommandKind
// enum (play, pause, toggle, next, previous, stop, seek).
enum class MediaCommandKind : int {
  kPlay = 0,
  kPause,
  kToggle,
  kNext,
  kPrevious,
  kStop,
  kSeek,
};

// Labels for the tray menu and thumbnail buttons. Dart passes them so the
// visible text can be translated alongside the rest of the app.
struct ShellLabels {
  std::wstring tray_open = L"Open";
  std::wstring tray_pause_all = L"Pause all downloads";
  std::wstring tray_quit = L"Quit";
  std::wstring thumb_previous = L"Previous";
  std::wstring thumb_play = L"Play";
  std::wstring thumb_pause = L"Pause";
  std::wstring thumb_next = L"Next";
};

// Taskbar, notification area and session plumbing for the main window:
// tray icon + menu, balloon notifications (shown as toasts on Windows
// 10/11), taskbar progress, thumbnail toolbar buttons and lock/unlock
// notifications. Events are reported through the |sink| callback as
// (method, argument) pairs that the window forwards to Dart.
class DesktopShell {
 public:
  // An event for Dart: method name plus an optional UTF-8 string argument
  // or boolean. Only one of the two is meaningful per event.
  struct Event {
    std::string method;
    std::optional<std::string> text;
    std::optional<bool> flag;
    std::optional<int> kind;
  };
  using Sink = std::function<void(const Event&)>;

  DesktopShell(HWND window, Sink sink);
  ~DesktopShell();

  DesktopShell(const DesktopShell&) = delete;
  DesktopShell& operator=(const DesktopShell&) = delete;

  // Handles shell-related messages; returns true (with |result|) when the
  // message was consumed and must not reach DefWindowProc.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result);

  // Keeps a tray icon visible with |tooltip| until HideTray.
  void ShowTray(const std::wstring& tooltip);
  // Removes the explicit tray icon (a temporary one may remain while the
  // window is hidden in the tray or a notification is on screen).
  void HideTray();
  // Hides the window, leaving the tray icon as the way back.
  void HideToTray();
  // Shows, restores and focuses the window after HideToTray / minimise.
  void RestoreFromTray();
  bool hidden_to_tray() const { return hidden_to_tray_; }

  // Shows a balloon notification. |payload| comes back on click.
  void ShowNotification(const std::wstring& title, const std::wstring& body,
                        std::optional<std::string> payload);

  // Taskbar button progress: |state| 0 none, 1 normal, 2 paused, 3 error,
  // 4 indeterminate; |fraction| in 0..1.
  void SetTaskbarProgress(int state, double fraction);

  // Previous / Play-Pause / Next under the taskbar thumbnail.
  void SetThumbButtons(bool visible, bool playing, bool can_previous,
                       bool can_next);

  // Replaces the visible labels (tray menu, thumbnail tooltips).
  void SetLabels(const ShellLabels& labels);

 private:
  // Adds, updates or removes the notification-area icon to match the
  // current needs (explicit, hidden window, or pending balloon).
  void RefreshIcon();
  void ShowTrayMenu(POINT anchor);
  bool EnsureTaskbar();
  void ApplyTaskbarProgress();
  void ApplyThumbButtons();
  void Emit(const char* method);
  void EmitText(const char* method, std::optional<std::string> text);

  HWND window_;
  Sink sink_;
  ShellLabels labels_;
  UINT taskbar_created_message_ = 0;
  UINT taskbar_button_created_message_ = 0;
  UINT restore_message_ = 0;

  // Notification-area icon state.
  HICON tray_icon_ = nullptr;
  HICON balloon_icon_ = nullptr;
  bool icon_added_ = false;
  bool tray_requested_ = false;
  bool hidden_to_tray_ = false;
  bool balloon_active_ = false;
  std::wstring tooltip_ = L"Zangetsu";
  std::optional<std::string> balloon_payload_;

  // Taskbar button state, re-applied whenever Explorer recreates it.
  ITaskbarList3* taskbar_ = nullptr;
  bool taskbar_button_ready_ = false;
  int progress_state_ = 0;
  double progress_fraction_ = 0;
  bool thumb_added_ = false;
  bool thumb_visible_ = false;
  bool thumb_playing_ = false;
  bool thumb_can_previous_ = true;
  bool thumb_can_next_ = true;
  HICON icon_previous_ = nullptr;
  HICON icon_play_ = nullptr;
  HICON icon_pause_ = nullptr;
  HICON icon_next_ = nullptr;

  bool session_registered_ = false;
};

#endif  // RUNNER_DESKTOP_SHELL_H_
