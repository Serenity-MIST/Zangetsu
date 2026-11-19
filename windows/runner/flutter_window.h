#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "desktop_shell.h"
#include "drop_target.h"
#include "media_session.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // True once Dart asked for a restart; main() relaunches the executable
  // after the message loop ends and the single-instance mutex is released.
  bool restart_requested() const { return restart_requested_; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  // Handles every Dart -> native call on com.spyou.zangetsu/window.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Sends a native -> Dart event on the same channel (fire and forget).
  void Send(const std::string& method, flutter::EncodableValue argument);

  // Borderless fullscreen on the window's monitor; both report the change
  // to Dart through fullscreenChanged.
  bool EnterFullscreen();
  void ExitFullscreen();
  // Re-fits a fullscreen window after a monitor or DPI change.
  void RefitFullscreen();

  // Small always-on-top 16:9 window in the corner of the current monitor.
  bool EnterMiniPlayer();
  void ExitMiniPlayer();
  // Keeps the mini player's client area 16:9 while the user resizes it.
  void KeepMiniAspect(WPARAM edge, RECT* frame);

  void SetAlwaysOnTop(bool on);

  // Quits without asking Dart (the close guard already decided).
  void ForceClose();

  // Snap Layouts: true when the screen point in |lparam| is over the
  // maximise button Dart reported.
  bool IsOverMaximizeButton(LPARAM lparam) const;
  void SetMaximizeHover(bool hover);
  void ReportMaximized();

  // Placement worth remembering, ignoring fullscreen / mini player.
  WINDOWPLACEMENT RestorablePlacement();

  // Window procedure wrapped around the Flutter view HWND (Snap Layouts
  // hit test); forwards everything else to the view's own procedure.
  static LRESULT CALLBACK ViewSubclassProc(HWND window, UINT message,
                                           WPARAM wparam, LPARAM lparam);

  // Original caption style is restored when leaving desktop chrome.
  bool custom_caption_ = false;
  LONG_PTR caption_style_ = 0;
  bool fullscreen_ = false;
  LONG_PTR window_style_ = 0;
  WINDOWPLACEMENT window_placement_ = {sizeof(WINDOWPLACEMENT)};

  // Mini player: the style/placement to go back to, and the size of the
  // non-client frame so WM_SIZING can keep the client area 16:9.
  bool mini_player_ = false;
  LONG_PTR mini_style_ = 0;
  WINDOWPLACEMENT mini_placement_ = {sizeof(WINDOWPLACEMENT)};
  SIZE mini_frame_ = {0, 0};

  // Pinned above other windows by the user (kept separately from the mini
  // player, which is always topmost while shown).
  bool always_on_top_ = false;

  // Close guard: WM_CLOSE is offered to Dart while it has a handler.
  bool close_guard_ = false;
  bool force_closing_ = false;
  bool restart_requested_ = false;

  // Snap Layouts: maximise button rect in view client pixels.
  RECT maximize_button_ = {0, 0, 0, 0};
  bool maximize_hover_ = false;
  bool maximize_pressed_ = false;
  bool last_maximized_ = false;
  HWND view_window_ = nullptr;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Window channel kept alive so native code can send events to Dart.
  std::unique_ptr<Channel> channel_;

  // Taskbar / tray / notification / session helpers.
  std::unique_ptr<DesktopShell> shell_;
  // Windows media overlay and media keys.
  std::unique_ptr<MediaSession> media_;
  // OLE drop target on the Flutter view (COM ref counted).
  DropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
