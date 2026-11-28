#include "flutter_window.h"

#include <optional>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <cmath>

#include "desktop_registry.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// Names for MediaCommandKind, in enum order, as Dart expects them.
constexpr const char* kMediaCommandNames[] = {
    "play", "pause", "toggle", "next", "previous", "stop", "seek"};

// The single main window; used by the Flutter view's subclass procedure.
FlutterWindow* g_view_owner = nullptr;
WNDPROC g_view_original_proc = nullptr;

// Map arguments from Dart, or nullptr when the call sent something else.
const EncodableMap* AsMap(const EncodableValue* value) {
  return value ? std::get_if<EncodableMap>(value) : nullptr;
}

// Looks up |key| in a Dart map argument.
const EncodableValue* Field(const EncodableMap* map, const char* key) {
  if (!map) return nullptr;
  const auto found = map->find(EncodableValue(std::string(key)));
  return found == map->end() ? nullptr : &found->second;
}

// A boolean field, or |fallback| when missing.
bool BoolField(const EncodableMap* map, const char* key, bool fallback) {
  const auto* value = Field(map, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag ? *flag : fallback;
}

// A numeric field (Dart ints arrive as int32 or int64, doubles as double).
double NumberField(const EncodableMap* map, const char* key, double fallback) {
  const auto* value = Field(map, key);
  if (!value) return fallback;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) {
    return static_cast<double>(*l);
  }
  return fallback;
}

// UTF-8 -> UTF-16 for text Dart sends to Windows APIs.
std::wstring Wide(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), result.data(), length);
  return result;
}

// A string field converted to UTF-16, or |fallback| when missing.
std::wstring TextField(const EncodableMap* map, const char* key,
                       const std::wstring& fallback = std::wstring()) {
  const auto* value = Field(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? Wide(*text) : fallback;
}

// The bool argument of a call, or nullptr when it sent something else.
const bool* BoolArgument(const flutter::MethodCall<EncodableValue>& call) {
  return call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  // Flutter shortcuts/player controls share this window channel. It is kept
  // as a member so native code can also send events (fullscreen, close,
  // tray, media keys, drops) back to Dart on the same channel.
  channel_ = std::make_unique<Channel>(
      flutter_controller_->engine()->messenger(), "com.spyou.zangetsu/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
#ifdef ZANGETSU_DISCORD_SDK
  discord_ = std::make_unique<DiscordPresence>(
      flutter_controller_->engine()->messenger());
#endif

  const HWND window = GetHandle();
  // Tray, taskbar and session events are forwarded to Dart as-is.
  shell_ = std::make_unique<DesktopShell>(
      window, [this](const DesktopShell::Event& event) {
        if (event.kind) {
          EncodableMap command;
          command[EncodableValue("kind")] =
              EncodableValue(kMediaCommandNames[*event.kind]);
          Send(event.method, EncodableValue(command));
        } else if (event.flag) {
          Send(event.method, EncodableValue(*event.flag));
        } else if (event.method == "trayAction" && event.text &&
                   *event.text == "quit") {
          // Quit must work even if Dart cannot answer (e.g. after a hot
          // restart): any failure to handle it closes the window directly.
          if (!channel_) return ForceClose();
          channel_->InvokeMethod(
              "trayAction", std::make_unique<EncodableValue>(*event.text),
              std::make_unique<
                  flutter::MethodResultFunctions<EncodableValue>>(
                  nullptr,
                  [this](const std::string&, const std::string&,
                         const EncodableValue*) { ForceClose(); },
                  [this]() { ForceClose(); }));
        } else {
          Send(event.method, event.text ? EncodableValue(*event.text)
                                        : EncodableValue());
        }
      });
  media_ = std::make_unique<MediaSession>(window);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  view_window_ = flutter_controller_->view()->GetNativeWindow();

  // Snap Layouts: the view answers HTTRANSPARENT over the maximise button
  // so Windows asks this top-level window, which answers HTMAXBUTTON.
  g_view_owner = this;
  g_view_original_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      view_window_, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(&FlutterWindow::ViewSubclassProc)));

  // Files and links dropped on the window go to Dart (needs OleInitialize,
  // done in main.cpp).
  drop_target_ = new DropTarget(
      view_window_,
      [this](std::optional<std::pair<double, double>> position) {
        if (!position) {
          Send("dragLeave", EncodableValue());
          return;
        }
        EncodableMap point;
        point[EncodableValue("x")] = EncodableValue(position->first);
        point[EncodableValue("y")] = EncodableValue(position->second);
        Send("dragUpdate", EncodableValue(point));
      },
      [this](const DropTarget::DropData& drop) {
        EncodableList paths;
        for (const auto& path : drop.paths) paths.push_back(EncodableValue(path));
        EncodableMap data;
        data[EncodableValue("paths")] = EncodableValue(paths);
        data[EncodableValue("text")] =
            drop.text ? EncodableValue(*drop.text) : EncodableValue();
        data[EncodableValue("x")] = EncodableValue(drop.x);
        data[EncodableValue("y")] = EncodableValue(drop.y);
        Send("drop", EncodableValue(data));
      });
  drop_target_->Register();

  // Start without the OS caption so the plain Windows title bar never flashes
  // during the splash; Dart's own titlebar confirms this through
  // setTitlebarHidden(true), which is then a no-op.
  {
    caption_style_ = GetWindowLongPtr(window, GWL_STYLE);
    SetWindowLongPtr(window, GWL_STYLE, caption_style_ & ~WS_CAPTION);
    custom_caption_ = true;
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const HWND window = GetHandle();
  const std::string& method = call.method_name();
  const EncodableMap* args = AsMap(call.arguments());
  // Client-drawn desktop titlebar keeps the OS resize frame and system menu.
  // The Dart side shows it only after this handshake succeeds.
  if (method == "setTitlebarHidden") {
    const auto* hidden = BoolArgument(call);
    if (!hidden) { result->Error("ARGUMENT", "Expected a boolean"); return; }
    // Fullscreen and the mini player keep their own restoration style.
    LONG_PTR style = fullscreen_    ? window_style_
                     : mini_player_ ? mini_style_
                                    : GetWindowLongPtr(window, GWL_STYLE);
    if (*hidden && !custom_caption_) {
      caption_style_ = style;
      style &= ~WS_CAPTION;
    } else if (!*hidden && custom_caption_) {
      style = caption_style_;
    }
    // A chrome change during fullscreen updates the restoration style only;
    // it must never reintroduce a frame on the current fullscreen surface.
    if (fullscreen_) window_style_ = style;
    else if (mini_player_) mini_style_ = style;
    else SetWindowLongPtr(window, GWL_STYLE, style);
    custom_caption_ = *hidden;
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    result->Success(EncodableValue(true));
    return;
  }
  if (method == "startWindowDrag") {
    // The drag request arrives asynchronously. If the button is already up
    // (a quick flick on the title bar), starting the move loop now would
    // wait for a button-up that never comes and eat the keys (R1).
    const int drag_button =
        GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
    if (!(GetAsyncKeyState(drag_button) & 0x8000)) {
      result->Success(); return;
    }
    ReleaseCapture();
    SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    result->Success(); return;
  }
  if (method == "minimizeWindow") {
    ShowWindow(window, SW_MINIMIZE); result->Success(); return;
  }
  if (method == "isMaximizedWindow") {
    result->Success(EncodableValue(IsZoomed(window) != FALSE)); return;
  }
  if (method == "toggleMaximizeWindow") {
    ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success(EncodableValue(IsZoomed(window) != FALSE)); return;
  }
  // Same path as the caption X: WM_CLOSE runs the Dart close guard.
  if (method == "closeWindow") {
    PostMessage(window, WM_CLOSE, 0, 0); result->Success(); return;
  }
  // Dart's close guard decided to quit (or the user picked Quit).
  if (method == "forceCloseWindow") {
    ForceClose(); result->Success(); return;
  }
  // Dart registers / removes its close handler; while on, WM_CLOSE is
  // offered to Dart as closeRequested instead of closing.
  if (method == "setCloseGuard") {
    const auto* enabled = BoolArgument(call);
    if (!enabled) { result->Error("ARGUMENT", "Expected a boolean"); return; }
    close_guard_ = *enabled;
    result->Success(); return;
  }
  if (method == "restartApp") {
    restart_requested_ = true;
    ForceClose();
    result->Success(); return;
  }
  if (method == "getWindowState") {
    EncodableMap state;
    state[EncodableValue("fullscreen")] = EncodableValue(fullscreen_);
    state[EncodableValue("maximized")] =
        EncodableValue(!fullscreen_ && IsZoomed(window) != FALSE);
    state[EncodableValue("alwaysOnTop")] = EncodableValue(always_on_top_);
    state[EncodableValue("miniPlayer")] = EncodableValue(mini_player_);
    state[EncodableValue("launchedAtSignIn")] =
        EncodableValue(WasLaunchedAtSignIn());
    result->Success(EncodableValue(state)); return;
  }
  if (method == "setMaximizeButtonRect") {
    // Physical pixels relative to the Flutter view; empty disables it.
    const double width = NumberField(args, "w", 0);
    const double height = NumberField(args, "h", 0);
    if (width <= 0 || height <= 0) {
      SetRectEmpty(&maximize_button_);
      SetMaximizeHover(false);
    } else {
      const LONG left = std::lround(NumberField(args, "x", 0));
      const LONG top = std::lround(NumberField(args, "y", 0));
      SetRect(&maximize_button_, left, top, left + std::lround(width),
              top + std::lround(height));
    }
    result->Success(); return;
  }
  if (method == "setAlwaysOnTop") {
    const auto* on = BoolArgument(call);
    if (!on) { result->Error("ARGUMENT", "Expected a boolean"); return; }
    SetAlwaysOnTop(*on);
    result->Success(EncodableValue(always_on_top_)); return;
  }
  if (method == "enterMiniPlayer") {
    result->Success(EncodableValue(EnterMiniPlayer())); return;
  }
  if (method == "exitMiniPlayer") {
    ExitMiniPlayer();
    result->Success(EncodableValue(mini_player_)); return;
  }
  if (method == "isLaunchAtSignInEnabled") {
    result->Success(EncodableValue(IsLaunchAtSignInEnabled())); return;
  }
  if (method == "setLaunchAtSignIn") {
    const auto* enabled = BoolArgument(call);
    if (!enabled) { result->Error("ARGUMENT", "Expected a boolean"); return; }
    if (!SetLaunchAtSignIn(*enabled)) {
      result->Error("REGISTRY", "Windows could not change sign-in startup");
      return;
    }
    result->Success(); return;
  }
  if (method == "getRememberWindowPlacement") {
    result->Success(EncodableValue(IsRememberWindowPlacementEnabled()));
    return;
  }
  if (method == "setRememberWindowPlacement") {
    const auto* enabled = BoolArgument(call);
    if (!enabled) { result->Error("ARGUMENT", "Expected a boolean"); return; }
    SetRememberWindowPlacementEnabled(*enabled);
    result->Success(); return;
  }
  // Translated labels for the tray menu and thumbnail buttons.
  if (method == "setShellLabels") {
    ShellLabels labels;
    labels.tray_open = TextField(args, "open", labels.tray_open);
    labels.tray_pause_all = TextField(args, "pauseAll", labels.tray_pause_all);
    labels.tray_quit = TextField(args, "quit", labels.tray_quit);
    labels.thumb_previous = TextField(args, "previous", labels.thumb_previous);
    labels.thumb_play = TextField(args, "play", labels.thumb_play);
    labels.thumb_pause = TextField(args, "pause", labels.thumb_pause);
    labels.thumb_next = TextField(args, "next", labels.thumb_next);
    shell_->SetLabels(labels);
    result->Success(); return;
  }
  if (method == "showTray") {
    shell_->ShowTray(TextField(args, "tooltip", L"Zangetsu"));
    result->Success(); return;
  }
  if (method == "hideTray") {
    shell_->HideTray(); result->Success(); return;
  }
  if (method == "hideToTray") {
    shell_->HideToTray(); result->Success(); return;
  }
  if (method == "restoreFromTray") {
    shell_->RestoreFromTray(); result->Success(); return;
  }
  if (method == "showNotification") {
    const auto* payload_value = Field(args, "payload");
    const auto* payload =
        payload_value ? std::get_if<std::string>(payload_value) : nullptr;
    shell_->ShowNotification(
        TextField(args, "title"), TextField(args, "body"),
        payload ? std::optional<std::string>(*payload) : std::nullopt);
    result->Success(); return;
  }
  if (method == "setTaskbarProgress") {
    shell_->SetTaskbarProgress(
        static_cast<int>(NumberField(args, "state", 0)),
        NumberField(args, "fraction", 0));
    result->Success(); return;
  }
  if (method == "setThumbButtons") {
    shell_->SetThumbButtons(BoolField(args, "visible", false),
                            BoolField(args, "playing", false),
                            BoolField(args, "canPrevious", true),
                            BoolField(args, "canNext", true));
    result->Success(); return;
  }
  if (method == "updateMediaSession") {
    MediaSessionInfo info;
    info.title = TextField(args, "title");
    info.subtitle = TextField(args, "subtitle");
    info.artwork_url = TextField(args, "artworkUrl");
    info.playing = BoolField(args, "playing", false);
    info.position_ms = static_cast<int64_t>(NumberField(args, "positionMs", -1));
    info.duration_ms = static_cast<int64_t>(NumberField(args, "durationMs", -1));
    info.can_next = BoolField(args, "canNext", false);
    info.can_previous = BoolField(args, "canPrevious", false);
    result->Success(EncodableValue(media_->Update(info))); return;
  }
  if (method == "clearMediaSession") {
    media_->Clear(); result->Success(); return;
  }
  if (method == "registerOAuthProtocol") {
    // Register one of our own schemes for the current user when connecting
    // an account. No argument keeps the original "zangetsu" behaviour; a
    // string names the scheme (e.g. Discord's "discord-<appId>"). Unknown
    // schemes are refused by IsAllowedUrlScheme.
    std::wstring scheme = L"zangetsu";
    if (call.arguments() && !call.arguments()->IsNull()) {
      const auto* requested = std::get_if<std::string>(call.arguments());
      if (!requested) { result->Error("ARGUMENT", "Expected a scheme string"); return; }
      scheme.assign(requested->begin(), requested->end());
    }
    if (!IsAllowedUrlScheme(scheme)) {
      result->Error("ARGUMENT", "This sign-in scheme is not allowed");
      return;
    }
    if (RegisterUrlProtocol(scheme) != ERROR_SUCCESS) {
      result->Error("PROTOCOL", "Windows could not register the sign-in callback");
    } else {
      result->Success();
    }
    return;
  }
  // Readers preserve the incoming window state instead of treating Android's
  // system-bar API as Windows fullscreen. Repeated setters are idempotent.
  if (method == "isFullscreen") {
    result->Success(EncodableValue(fullscreen_));
    return;
  }
  if (method == "setFullscreen") {
    const auto* requested = BoolArgument(call);
    if (!requested) {
      result->Error("ARGUMENT", "Expected a fullscreen boolean");
      return;
    }
    if (*requested != fullscreen_) {
      if (*requested && !EnterFullscreen()) {
        result->Error("WINDOW", "Could not read monitor bounds");
        return;
      }
      if (!*requested) ExitFullscreen();
    }
    result->Success();
    return;
  }
  // exitFullscreen reports whether it handled Escape; toggling has no payload.
  if (method == "exitFullscreen") {
    if (!fullscreen_) { result->Success(EncodableValue(false)); return; }
    ExitFullscreen();
    result->Success(EncodableValue(true));
    return;
  }
  if (method == "toggleFullscreen") {
    if (fullscreen_) {
      ExitFullscreen();
    } else if (!EnterFullscreen()) {
      result->Error("WINDOW", "Could not read monitor bounds");
      return;
    }
    result->Success();
    return;
  }
  result->NotImplemented();
}

void FlutterWindow::Send(const std::string& method, EncodableValue argument) {
  if (!channel_) return;
  channel_->InvokeMethod(method,
                         std::make_unique<EncodableValue>(std::move(argument)));
}

bool FlutterWindow::EnterFullscreen() {
  if (fullscreen_) return true;
  // The mini player and fullscreen are exclusive; leave the mini player.
  if (mini_player_) ExitMiniPlayer();
  const HWND hwnd = GetHandle();
  // Capture the original style and placement before fullscreen so Escape
  // restores exactly the prior window, rather than a default size or monitor.
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  window_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
  window_placement_.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(hwnd, &window_placement_) ||
      !GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor)) {
    return false;
  }
  // Set the transition state before synchronous window messages fire.
  // Otherwise maximize constraints can clamp fullscreen to the work area.
  fullscreen_ = true;
  // Clear Windows' zoom state after saving placement. Leaving WS_MAXIMIZE
  // set makes SetWindowPlacement on exit think maximization already happened
  // and keeps the fullscreen-sized outer rectangle behind the restored UI.
  if (IsZoomed(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   window_style_ & ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE |
                                     WS_MINIMIZE));
  SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
               monitor.rcMonitor.right - monitor.rcMonitor.left,
               monitor.rcMonitor.bottom - monitor.rcMonitor.top,
               SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
  // Every change is reported so Dart's flag never drifts from the window.
  Send("fullscreenChanged", EncodableValue(true));
  return true;
}

void FlutterWindow::ExitFullscreen() {
  if (!fullscreen_) return;
  const HWND hwnd = GetHandle();
  // Placement restoration can synchronously ask for maximized bounds.
  fullscreen_ = false;
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   window_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE));
  SetWindowPlacement(hwnd, &window_placement_);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  Send("fullscreenChanged", EncodableValue(false));
  ReportMaximized();
}

void FlutterWindow::RefitFullscreen() {
  if (!fullscreen_) return;
  const HWND hwnd = GetHandle();
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor)) {
    return;
  }
  // Follow the monitor the window now sits on (resolution change, monitor
  // unplugged, or Win+Shift+Arrow to another display).
  SetWindowPos(hwnd, nullptr, monitor.rcMonitor.left, monitor.rcMonitor.top,
               monitor.rcMonitor.right - monitor.rcMonitor.left,
               monitor.rcMonitor.bottom - monitor.rcMonitor.top,
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

bool FlutterWindow::EnterMiniPlayer() {
  if (mini_player_) return true;
  if (fullscreen_) ExitFullscreen();
  const HWND hwnd = GetHandle();
  mini_placement_.length = sizeof(WINDOWPLACEMENT);
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetWindowPlacement(hwnd, &mini_placement_) ||
      !GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor)) {
    return false;
  }
  mini_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
  // Set first so WM_GETMINMAXINFO relaxes the 800x560 minimum.
  mini_player_ = true;
  if (IsZoomed(hwnd) || IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
  // No caption; keep the thick frame so the corners stay resizable.
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   (mini_style_ & ~(WS_CAPTION | WS_MAXIMIZE | WS_MINIMIZE)) |
                       WS_THICKFRAME);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  // Measure the non-client frame so the client area is exactly 16:9.
  RECT outer, inner;
  GetWindowRect(hwnd, &outer);
  GetClientRect(hwnd, &inner);
  mini_frame_.cx = (outer.right - outer.left) - (inner.right - inner.left);
  mini_frame_.cy = (outer.bottom - outer.top) - (inner.bottom - inner.top);
  const UINT dpi = GetDpiForWindow(hwnd);
  const int width = MulDiv(480, dpi, 96) + mini_frame_.cx;
  const int height = MulDiv(270, dpi, 96) + mini_frame_.cy;
  const int margin = MulDiv(16, dpi, 96);
  // Bottom-right corner of the current monitor's work area, above others.
  SetWindowPos(hwnd, HWND_TOPMOST, monitor.rcWork.right - width - margin,
               monitor.rcWork.bottom - height - margin, width, height,
               SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  Send("miniPlayerChanged", EncodableValue(true));
  ReportMaximized();
  return true;
}

void FlutterWindow::ExitMiniPlayer() {
  if (!mini_player_) return;
  const HWND hwnd = GetHandle();
  mini_player_ = false;
  SetWindowLongPtr(hwnd, GWL_STYLE,
                   mini_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE));
  // Never come back minimised: restore to the size it had (or maximised).
  WINDOWPLACEMENT placement = mini_placement_;
  if (placement.showCmd == SW_SHOWMINIMIZED ||
      placement.showCmd == SW_MINIMIZE ||
      placement.showCmd == SW_SHOWMINNOACTIVE) {
    placement.showCmd = (placement.flags & WPF_RESTORETOMAXIMIZED)
                            ? SW_SHOWMAXIMIZED
                            : SW_SHOWNORMAL;
  }
  SetWindowPlacement(hwnd, &placement);
  // Back to the user's own always-on-top choice.
  SetWindowPos(hwnd, always_on_top_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0,
               0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  Send("miniPlayerChanged", EncodableValue(false));
  ReportMaximized();
}

void FlutterWindow::KeepMiniAspect(WPARAM edge, RECT* frame) {
  LONG width = frame->right - frame->left - mini_frame_.cx;
  LONG height = frame->bottom - frame->top - mini_frame_.cy;
  if (edge == WMSZ_TOP || edge == WMSZ_BOTTOM) {
    // Dragging a horizontal edge: height leads, width follows.
    width = MulDiv(height, 16, 9);
    frame->right = frame->left + width + mini_frame_.cx;
    return;
  }
  // Side edges and corners: width leads, height follows from the edge
  // that is being dragged.
  height = MulDiv(width, 9, 16);
  if (edge == WMSZ_TOPLEFT || edge == WMSZ_TOPRIGHT) {
    frame->top = frame->bottom - height - mini_frame_.cy;
  } else {
    frame->bottom = frame->top + height + mini_frame_.cy;
  }
}

void FlutterWindow::SetAlwaysOnTop(bool on) {
  always_on_top_ = on;
  // The mini player is always topmost; its exit applies this choice.
  if (!mini_player_) {
    SetWindowPos(GetHandle(), on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  Send("alwaysOnTopChanged", EncodableValue(on));
}

void FlutterWindow::ForceClose() {
  force_closing_ = true;
  PostMessage(GetHandle(), WM_CLOSE, 0, 0);
}

bool FlutterWindow::IsOverMaximizeButton(LPARAM lparam) const {
  if (!custom_caption_ || fullscreen_ || mini_player_ || !view_window_ ||
      IsRectEmpty(&maximize_button_)) {
    return false;
  }
  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ScreenToClient(view_window_, &point);
  return PtInRect(&maximize_button_, point) != FALSE;
}

void FlutterWindow::SetMaximizeHover(bool hover) {
  if (hover == maximize_hover_) return;
  maximize_hover_ = hover;
  if (!hover) maximize_pressed_ = false;
  // The pointer is over the non-client area, so Flutter cannot see it;
  // tell the title bar to paint the hover itself.
  Send("maximizeHover", EncodableValue(hover));
}

void FlutterWindow::ReportMaximized() {
  const HWND hwnd = GetHandle();
  if (!hwnd) return;
  const bool maximized = !fullscreen_ && IsZoomed(hwnd) != FALSE;
  if (maximized == last_maximized_) return;
  last_maximized_ = maximized;
  Send("maximizedChanged", EncodableValue(maximized));
}

WINDOWPLACEMENT FlutterWindow::RestorablePlacement() {
  // Fullscreen and the mini player are temporary: remember the window as
  // it was before them.
  if (fullscreen_) return window_placement_;
  if (mini_player_) return mini_placement_;
  WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
  GetWindowPlacement(GetHandle(), &placement);
  return placement;
}

// static
LRESULT CALLBACK FlutterWindow::ViewSubclassProc(HWND window, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  // Let the hit test fall through to the top-level window over the
  // maximise button; everything else is the view's own business.
  if (message == WM_NCHITTEST && g_view_owner &&
      g_view_owner->IsOverMaximizeButton(lparam)) {
    return HTTRANSPARENT;
  }
  return CallWindowProc(g_view_original_proc, window, message, wparam, lparam);
}

void FlutterWindow::OnDestroy() {
  // Release native helpers while the view and window still exist.
  if (drop_target_) {
    drop_target_->Revoke();
    drop_target_->Release();
    drop_target_ = nullptr;
  }
  if (view_window_ && g_view_original_proc) {
    SetWindowLongPtr(view_window_, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(g_view_original_proc));
    g_view_original_proc = nullptr;
  }
  g_view_owner = nullptr;
  view_window_ = nullptr;
  media_ = nullptr;
  shell_ = nullptr;
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_ = nullptr;
  }
  if (flutter_controller_) {
    // Closing the engine waits for its drawing thread and for the video
    // player's threads. If one of them is stuck, the window is already gone
    // but the process would stay alive for good, and the app could not be
    // opened again until it was ended in Task Manager. So end the process if
    // it is still here after 15 seconds; a normal exit is over long before.
    // Not for a restart: that starts the new copy after this returns.
    if (!restart_requested_) {
      const HANDLE exit_guard = ::CreateThread(
          nullptr, 0,
          [](LPVOID) -> DWORD {
            ::Sleep(15000);
            ::TerminateProcess(::GetCurrentProcess(), 0);
            return 0;
          },
          nullptr, 0, nullptr);
      if (exit_guard) ::CloseHandle(exit_guard);
    }
#ifdef ZANGETSU_DISCORD_SDK
    // Takes the status off the Discord profile. After the guard above, so that
    // on a quit a stuck SDK cannot keep the process alive either.
    discord_ = nullptr;
#endif
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Tray icon, taskbar button, thumbnail buttons and session changes.
  if (shell_) {
    LRESULT shell_result = 0;
    if (shell_->HandleMessage(message, wparam, lparam, &shell_result)) {
      return shell_result;
    }
  }
  switch (message) {
    case WM_SYSCOMMAND:
      // A lone Alt or F10 (lparam 0: no mnemonic key) would enter the
      // system-menu loop. With the custom title bar that menu is invisible,
      // so it silently swallowed the next keys and every shortcut looked
      // dead (R1). Alt+Space (lparam ' ') still opens the system menu.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam == 0) {
        return 0;
      }
      break;
    case WM_CLOSE:
      // Caption X, Alt+F4 and the taskbar's Close all arrive here. While
      // Dart has a close guard, it decides (quit, tray or cancel). If Dart
      // cannot answer, the window closes as before.
      if (close_guard_ && !force_closing_ && channel_) {
        channel_->InvokeMethod(
            "closeRequested", nullptr,
            std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
                nullptr,
                [this](const std::string&, const std::string&,
                       const EncodableValue*) { ForceClose(); },
                [this]() { ForceClose(); }));
        return 0;
      }
      break;
    case WM_DESTROY:
      // Remember where the window was (when the user allows it).
      SaveWindowPlacement(RestorablePlacement());
      break;
    case WM_NCHITTEST:
      // Snap Layouts: Windows 11 shows its layout flyout over HTMAXBUTTON.
      if (IsOverMaximizeButton(lparam)) return HTMAXBUTTON;
      break;
    case WM_NCMOUSEMOVE:
      if (wparam == HTMAXBUTTON) {
        if (!maximize_hover_) {
          // Ask for WM_NCMOUSELEAVE so the hover can be cleared.
          TRACKMOUSEEVENT track = {sizeof(TRACKMOUSEEVENT)};
          track.dwFlags = TME_LEAVE | TME_NONCLIENT;
          track.hwndTrack = hwnd;
          TrackMouseEvent(&track);
        }
        SetMaximizeHover(true);
      } else {
        SetMaximizeHover(false);
      }
      break;
    case WM_NCMOUSELEAVE:
      SetMaximizeHover(false);
      break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      // DefWindowProc would draw a classic caption button here.
      if (wparam == HTMAXBUTTON) {
        maximize_pressed_ = true;
        return 0;
      }
      break;
    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        if (maximize_pressed_) {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
        maximize_pressed_ = false;
        return 0;
      }
      break;
    case WM_SIZING:
      if (mini_player_) {
        KeepMiniAspect(wparam, reinterpret_cast<RECT*>(lparam));
        return TRUE;
      }
      break;
    case WM_DISPLAYCHANGE:
      // Resolution or monitor layout changed: keep fullscreen covering it.
      RefitFullscreen();
      break;
    case kMediaCommandMessage: {
      // SMTC buttons, posted from a WinRT worker thread.
      const int kind = static_cast<int>(wparam);
      if (kind >= 0 && kind <= static_cast<int>(MediaCommandKind::kSeek)) {
        EncodableMap command;
        command[EncodableValue("kind")] =
            EncodableValue(kMediaCommandNames[kind]);
        if (lparam >= 0) {
          command[EncodableValue("positionMs")] =
              EncodableValue(static_cast<int64_t>(lparam));
        }
        Send("mediaCommand", EncodableValue(command));
      }
      return 0;
    }
    case WM_APPCOMMAND: {
      // Keyboard media keys. While the media overlay is active Windows
      // routes them to it instead, so only report them otherwise.
      if (media_ && media_->active()) break;
      int kind = -1;
      switch (GET_APPCOMMAND_LPARAM(lparam)) {
        case APPCOMMAND_MEDIA_PLAY: kind = 0; break;
        case APPCOMMAND_MEDIA_PAUSE: kind = 1; break;
        case APPCOMMAND_MEDIA_PLAY_PAUSE: kind = 2; break;
        case APPCOMMAND_MEDIA_NEXTTRACK: kind = 3; break;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK: kind = 4; break;
        case APPCOMMAND_MEDIA_STOP: kind = 5; break;
      }
      if (kind < 0) break;
      EncodableMap command;
      command[EncodableValue("kind")] =
          EncodableValue(kMediaCommandNames[kind]);
      Send("mediaCommand", EncodableValue(command));
      return TRUE;
    }
  }
  // The maximized outer bounds already equal rcWork. Do not let DefWindowProc
  // reserve an invisible resize border inside them, exposing the app behind us.
  if (message == WM_NCCALCSIZE && wparam && custom_caption_ &&
      !fullscreen_ && IsZoomed(hwnd)) {
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                       &monitor)) {
      reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0] = monitor.rcWork;
      return 0;
    }
  }
  // Keep the window at least 800x560 logical pixels (DPI-scaled) so the
  // desktop layout, docked panels and toasts never squeeze edge to edge.
  // The mini player instead allows a small 16:9 window (240x135 client).
  if (message == WM_GETMINMAXINFO) {
    const UINT dpi = GetDpiForWindow(hwnd);
    auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
    if (mini_player_) {
      limits->ptMinTrackSize.x = MulDiv(240, dpi, 96) + mini_frame_.cx;
      limits->ptMinTrackSize.y = MulDiv(135, dpi, 96) + mini_frame_.cy;
    } else {
      limits->ptMinTrackSize.x = MulDiv(800, dpi, 96);
      limits->ptMinTrackSize.y = MulDiv(560, dpi, 96);
    }
  }
  // A custom caption removes the standard maximized-frame adjustment. Bound
  // ordinary maximize to this monitor's work area so the taskbar stays visible.
  // Explicit player fullscreen continues to use the complete monitor bounds.
  if (message == WM_GETMINMAXINFO && custom_caption_ && !fullscreen_) {
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                       &monitor)) {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
      limits->ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
      limits->ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
      limits->ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
      return 0;
    }
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
    case WM_SIZE: {
      // Resize the view first, then report maximise changes made by any
      // route (caption button, Snap, Win+Up, double-click).
      const LRESULT sized =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      ReportMaximized();
      return sized;
    }
    case WM_DPICHANGED: {
      // Moving fullscreen to a monitor with another scale: cover it fully.
      const LRESULT moved =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      RefitFullscreen();
      return moved;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
