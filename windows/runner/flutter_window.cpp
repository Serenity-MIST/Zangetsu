#include "flutter_window.h"

#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

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
  // Flutter shortcuts/player controls share this window channel. Capture the
  // original style and placement before fullscreen so Escape restores exactly
  // the prior window, rather than imposing a default size or monitor.
  flutter::MethodChannel<flutter::EncodableValue> window_channel(
      flutter_controller_->engine()->messenger(), "com.spyou.zangetsu/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel.SetMethodCallHandler([this](const auto& call, auto result) {
    // Client-drawn desktop titlebar keeps the OS resize frame and system menu.
    // The Dart side shows it only after this handshake succeeds.
    const HWND window = GetHandle();
    if (call.method_name() == "setTitlebarHidden") {
      const auto* hidden = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!hidden) { result->Error("ARGUMENT", "Expected a boolean"); return; }
      LONG_PTR style = fullscreen_ ? window_style_ : GetWindowLongPtr(window, GWL_STYLE);
      if (*hidden && !custom_caption_) {
        caption_style_ = style;
        style &= ~WS_CAPTION;
      } else if (!*hidden && custom_caption_) {
        style = caption_style_;
      }
      // A chrome change during fullscreen updates the restoration style only;
      // it must never reintroduce a frame on the current fullscreen surface.
      if (fullscreen_) window_style_ = style;
      else SetWindowLongPtr(window, GWL_STYLE, style);
      custom_caption_ = *hidden;
      SetWindowPos(window, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
      result->Success(flutter::EncodableValue(true));
      return;
    }
    if (call.method_name() == "startWindowDrag") {
      ReleaseCapture();
      SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      result->Success(); return;
    }
    if (call.method_name() == "minimizeWindow") {
      ShowWindow(window, SW_MINIMIZE); result->Success(); return;
    }
    if (call.method_name() == "isMaximizedWindow") {
      result->Success(flutter::EncodableValue(IsZoomed(window) != FALSE)); return;
    }
    if (call.method_name() == "toggleMaximizeWindow") {
      ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
      result->Success(flutter::EncodableValue(IsZoomed(window) != FALSE)); return;
    }
    if (call.method_name() == "closeWindow") {
      PostMessage(window, WM_CLOSE, 0, 0); result->Success(); return;
    }
    if (call.method_name() == "registerOAuthProtocol") {
      // Register only our own scheme for the current user when connecting an
      // account. Quote both executable and URI; never invoke a command shell.
      wchar_t executable[32768];
      const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
      if (length == 0 || length >= 32768) {
        result->Error("PROTOCOL", "Could not locate the app executable");
        return;
      }
      HKEY key = nullptr;
      LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER,
          L"Software\\Classes\\zangetsu", 0, nullptr, 0, KEY_WRITE,
          nullptr, &key, nullptr);
      if (status == ERROR_SUCCESS) {
        const wchar_t description[] = L"URL:Zangetsu";
        status = RegSetValueExW(key, nullptr, 0, REG_SZ,
            reinterpret_cast<const BYTE*>(description), sizeof(description));
        if (status == ERROR_SUCCESS) {
          const wchar_t empty[] = L"";
          status = RegSetValueExW(key, L"URL Protocol", 0, REG_SZ,
              reinterpret_cast<const BYTE*>(empty), sizeof(empty));
        }
        RegCloseKey(key);
      }
      if (status == ERROR_SUCCESS) {
        status = RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Classes\\zangetsu\\shell\\open\\command", 0,
            nullptr, 0, KEY_WRITE, nullptr, &key, nullptr);
        if (status == ERROR_SUCCESS) {
          const std::wstring command = L"\"" + std::wstring(executable, length) + L"\" \"%1\"";
          status = RegSetValueExW(key, nullptr, 0, REG_SZ,
              reinterpret_cast<const BYTE*>(command.c_str()),
              static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
          RegCloseKey(key);
        }
      }
      if (status != ERROR_SUCCESS) {
        result->Error("PROTOCOL", "Windows could not register the sign-in callback");
      } else {
        result->Success();
      }
      return;
    }
    // Readers preserve the incoming window state instead of treating Android's
    // system-bar API as Windows fullscreen. Repeated setters are idempotent.
    if (call.method_name() == "isFullscreen") {
      result->Success(flutter::EncodableValue(fullscreen_));
      return;
    }
    if (call.method_name() == "setFullscreen") {
      const auto* requested = call.arguments()
          ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!requested) {
        result->Error("ARGUMENT", "Expected a fullscreen boolean");
        return;
      }
      if (*requested == fullscreen_) {
        result->Success();
        return;
      }
    }
    // exitFullscreen reports whether it handled Escape; toggling has no payload.
    const bool exit_only = call.method_name() == "exitFullscreen";
    if (exit_only && !fullscreen_) { result->Success(flutter::EncodableValue(false)); return; }
    if (!exit_only && call.method_name() != "toggleFullscreen" &&
        call.method_name() != "setFullscreen") {
      result->NotImplemented();
      return;
    }
    const HWND hwnd = GetHandle();
    if (!fullscreen_) {
      MONITORINFO monitor = {sizeof(MONITORINFO)};
      window_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (!GetWindowPlacement(hwnd, &window_placement_) ||
          !GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
        result->Error("WINDOW", "Could not read monitor bounds");
        return;
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
    } else {
      // Placement restoration can synchronously ask for maximized bounds.
      fullscreen_ = false;
      SetWindowLongPtr(hwnd, GWL_STYLE,
                       window_style_ & ~(WS_MAXIMIZE | WS_MINIMIZE));
      SetWindowPlacement(hwnd, &window_placement_);
      SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }
    result->Success(exit_only ? flutter::EncodableValue(true) : flutter::EncodableValue());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
