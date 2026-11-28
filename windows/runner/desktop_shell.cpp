#include "desktop_shell.h"

#include <shellapi.h>
#include <windowsx.h>
#include <wtsapi32.h>

#include <algorithm>
#include <cmath>
#include <vector>

#include "resource.h"
#include "utils.h"

namespace {

// Notification-area icon id; one icon per window is all we need.
constexpr UINT kTrayIconId = 1;

// Tray context menu command ids.
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuPauseAll = 2;
constexpr UINT kMenuQuit = 3;

// Simple shapes for the thumbnail toolbar icons. There are no icon assets
// for these in the resource file, so they are drawn at runtime.
enum class Glyph { kPrevious, kPlay, kPause, kNext };

// Signed area test: which side of edge a->b point p lies on.
double Edge(double ax, double ay, double bx, double by, double px, double py) {
  return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

// True when (x, y) lies inside the triangle a, b, c (either winding).
bool InTriangle(double x, double y, double ax, double ay, double bx, double by,
                double cx, double cy) {
  const double d1 = Edge(ax, ay, bx, by, x, y);
  const double d2 = Edge(bx, by, cx, cy, x, y);
  const double d3 = Edge(cx, cy, ax, ay, x, y);
  const bool negative = d1 < 0 || d2 < 0 || d3 < 0;
  const bool positive = d1 > 0 || d2 > 0 || d3 > 0;
  return !(negative && positive);
}

// True when (x, y) lies inside the axis-aligned box.
bool InBox(double x, double y, double left, double top, double right,
           double bottom) {
  return x >= left && x <= right && y >= top && y <= bottom;
}

// Whether the glyph covers normalised point (x, y) in a 0..1 square.
bool Covers(Glyph glyph, double x, double y) {
  switch (glyph) {
    case Glyph::kPlay:
      return InTriangle(x, y, .30, .20, .30, .80, .80, .50);
    case Glyph::kPause:
      return InBox(x, y, .26, .20, .42, .80) || InBox(x, y, .58, .20, .74, .80);
    case Glyph::kNext:
      return InTriangle(x, y, .20, .22, .20, .78, .64, .50) ||
             InBox(x, y, .66, .22, .79, .78);
    case Glyph::kPrevious:
      // Mirror image of "next".
      return Covers(Glyph::kNext, 1.0 - x, y);
  }
  return false;
}

// Renders a white, anti-aliased (4x4 supersampled) glyph into a 32-bit
// alpha icon of |size| pixels.
HICON MakeGlyphIcon(Glyph glyph, int size) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;  // top-down rows
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = ::GetDC(nullptr);
  HBITMAP colour =
      ::CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  ::ReleaseDC(nullptr, screen);
  if (!colour || !bits) return nullptr;
  auto* pixels = static_cast<DWORD*>(bits);
  constexpr int kSamples = 4;
  for (int row = 0; row < size; ++row) {
    for (int col = 0; col < size; ++col) {
      int hits = 0;
      for (int sy = 0; sy < kSamples; ++sy) {
        for (int sx = 0; sx < kSamples; ++sx) {
          const double x = (col + (sx + .5) / kSamples) / size;
          const double y = (row + (sy + .5) / kSamples) / size;
          if (Covers(glyph, x, y)) ++hits;
        }
      }
      const DWORD alpha =
          static_cast<DWORD>(hits * 255 / (kSamples * kSamples));
      // Straight (non-premultiplied) white with coverage as alpha.
      pixels[row * size + col] = (alpha << 24) | 0x00FFFFFF;
    }
  }
  // The mask is ignored for 32-bit icons with alpha but must exist.
  HBITMAP mask = ::CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO icon = {};
  icon.fIcon = TRUE;
  icon.hbmColor = colour;
  icon.hbmMask = mask;
  HICON result = ::CreateIconIndirect(&icon);
  ::DeleteObject(colour);
  if (mask) ::DeleteObject(mask);
  return result;
}

// Copies |source| into a fixed WCHAR buffer, truncating when too long.
template <size_t N>
void CopyText(wchar_t (&target)[N], const std::wstring& source) {
  wcsncpy_s(target, N, source.c_str(), _TRUNCATE);
}

}  // namespace

DesktopShell::DesktopShell(HWND window, Sink sink)
    : window_(window), sink_(std::move(sink)) {
  // Explorer broadcasts these when the taskbar (re)starts; icons and
  // taskbar buttons must then be added again.
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  taskbar_button_created_message_ =
      ::RegisterWindowMessageW(L"TaskbarButtonCreated");
  restore_message_ = ::RegisterWindowMessageW(kRestoreWindowMessageName);
  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  tray_icon_ = static_cast<HICON>(::LoadImageW(
      instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON), 0));
  balloon_icon_ = static_cast<HICON>(
      ::LoadImageW(instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
                   ::GetSystemMetrics(SM_CXICON),
                   ::GetSystemMetrics(SM_CYICON), 0));
  // Lock / unlock notifications for "lock the profile when Windows locks".
  session_registered_ =
      ::WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) !=
      FALSE;
}

DesktopShell::~DesktopShell() {
  // Never leave a ghost icon in the notification area after exit.
  if (icon_added_) {
    NOTIFYICONDATAW data = {sizeof(NOTIFYICONDATAW)};
    data.hWnd = window_;
    data.uID = kTrayIconId;
    ::Shell_NotifyIconW(NIM_DELETE, &data);
  }
  if (session_registered_) ::WTSUnRegisterSessionNotification(window_);
  if (taskbar_) taskbar_->Release();
  for (HICON icon : {tray_icon_, balloon_icon_, icon_previous_, icon_play_,
                     icon_pause_, icon_next_}) {
    if (icon) ::DestroyIcon(icon);
  }
}

void DesktopShell::Emit(const char* method) {
  if (sink_) sink_(Event{method, std::nullopt, std::nullopt, std::nullopt});
}

void DesktopShell::EmitText(const char* method,
                            std::optional<std::string> text) {
  if (sink_) sink_(Event{method, std::move(text), std::nullopt, std::nullopt});
}

bool DesktopShell::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                 LRESULT* result) {
  // Explorer restarted: the icon is gone, add it again if still wanted.
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    icon_added_ = false;
    RefreshIcon();
    return false;
  }
  // Taskbar button exists (or was recreated): progress and thumbnail
  // buttons can only be set from now on.
  if (taskbar_button_created_message_ != 0 &&
      message == taskbar_button_created_message_) {
    taskbar_button_ready_ = true;
    thumb_added_ = false;
    ApplyTaskbarProgress();
    ApplyThumbButtons();
    return false;
  }
  // A second launch found us hidden in the tray and asked us to come back.
  if (restore_message_ != 0 && message == restore_message_) {
    RestoreFromTray();
    *result = 0;
    return true;
  }
  switch (message) {
    case kTrayIconMessage: {
      // NOTIFYICON_VERSION_4: the event is in LOWORD(lparam) and the anchor
      // point in wparam.
      const UINT event = LOWORD(lparam);
      if (event == NIN_SELECT || event == NIN_KEYSELECT ||
          event == WM_LBUTTONDBLCLK) {
        RestoreFromTray();
        EmitText("trayAction", std::string("open"));
      } else if (event == WM_CONTEXTMENU) {
        ShowTrayMenu({GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam)});
      } else if (event == NIN_BALLOONUSERCLICK) {
        balloon_active_ = false;
        auto payload = std::move(balloon_payload_);
        balloon_payload_.reset();
        RestoreFromTray();
        EmitText("notificationClicked", std::move(payload));
      } else if (event == NIN_BALLOONTIMEOUT || event == NIN_BALLOONHIDE) {
        // Dismissed or expired: drop a temporary icon again.
        balloon_active_ = false;
        balloon_payload_.reset();
        RefreshIcon();
      }
      *result = 0;
      return true;
    }
    case WM_COMMAND:
      // Thumbnail toolbar clicks become media commands for the player.
      if (HIWORD(wparam) == THBN_CLICKED) {
        int kind = -1;
        switch (LOWORD(wparam)) {
          case kThumbPrevious:
            kind = static_cast<int>(MediaCommandKind::kPrevious);
            break;
          case kThumbPlayPause:
            kind = static_cast<int>(MediaCommandKind::kToggle);
            break;
          case kThumbNext:
            kind = static_cast<int>(MediaCommandKind::kNext);
            break;
        }
        if (kind >= 0 && sink_) {
          sink_(Event{"mediaCommand", std::nullopt, std::nullopt, kind});
        }
        *result = 0;
        return true;
      }
      return false;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_SESSION_LOCK || wparam == WTS_SESSION_UNLOCK) {
        if (sink_) {
          sink_(Event{"sessionLockChanged", std::nullopt,
                      wparam == WTS_SESSION_LOCK, std::nullopt});
        }
      }
      return false;
  }
  return false;
}

void DesktopShell::SetLabels(const ShellLabels& labels) {
  labels_ = labels;
  // Tooltips on thumbnail buttons are refreshed with the new text.
  ApplyThumbButtons();
}

void DesktopShell::RefreshIcon() {
  const bool wanted = tray_requested_ || hidden_to_tray_ || balloon_active_;
  NOTIFYICONDATAW data = {sizeof(NOTIFYICONDATAW)};
  data.hWnd = window_;
  data.uID = kTrayIconId;
  if (!wanted) {
    if (icon_added_) ::Shell_NotifyIconW(NIM_DELETE, &data);
    icon_added_ = false;
    return;
  }
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayIconMessage;
  data.hIcon = tray_icon_;
  CopyText(data.szTip, tooltip_);
  if (icon_added_) {
    ::Shell_NotifyIconW(NIM_MODIFY, &data);
    return;
  }
  if (::Shell_NotifyIconW(NIM_ADD, &data)) {
    // Version 4 gives NIN_SELECT/WM_CONTEXTMENU with anchor coordinates.
    data.uVersion = NOTIFYICON_VERSION_4;
    ::Shell_NotifyIconW(NIM_SETVERSION, &data);
    icon_added_ = true;
  }
}

void DesktopShell::ShowTray(const std::wstring& tooltip) {
  if (!tooltip.empty()) tooltip_ = tooltip;
  tray_requested_ = true;
  RefreshIcon();
}

void DesktopShell::HideTray() {
  tray_requested_ = false;
  RefreshIcon();
}

void DesktopShell::HideToTray() {
  // Add the icon first so the app never becomes unreachable.
  hidden_to_tray_ = true;
  RefreshIcon();
  ::ShowWindow(window_, SW_HIDE);
}

void DesktopShell::RestoreFromTray() {
  hidden_to_tray_ = false;
  if (!::IsWindowVisible(window_)) ::ShowWindow(window_, SW_SHOW);
  // Only un-minimise; a maximised or fullscreen window keeps its size.
  if (::IsIconic(window_)) ::ShowWindow(window_, SW_RESTORE);
  ::SetForegroundWindow(window_);
  RefreshIcon();
}

void DesktopShell::ShowTrayMenu(POINT anchor) {
  HMENU menu = ::CreatePopupMenu();
  if (!menu) return;
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, labels_.tray_open.c_str());
  ::AppendMenuW(menu, MF_STRING, kMenuPauseAll,
                labels_.tray_pause_all.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kMenuQuit, labels_.tray_quit.c_str());
  ::SetMenuDefaultItem(menu, kMenuOpen, FALSE);
  // Required so the menu closes when the user clicks elsewhere.
  ::SetForegroundWindow(window_);
  const UINT command = static_cast<UINT>(::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON |
                (::GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN
                                                          : TPM_LEFTALIGN),
      anchor.x, anchor.y, window_, nullptr));
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  switch (command) {
    case kMenuOpen:
      RestoreFromTray();
      EmitText("trayAction", std::string("open"));
      break;
    case kMenuPauseAll:
      EmitText("trayAction", std::string("pauseAll"));
      break;
    case kMenuQuit:
      EmitText("trayAction", std::string("quit"));
      break;
  }
}

void DesktopShell::ShowNotification(const std::wstring& title,
                                    const std::wstring& body,
                                    std::optional<std::string> payload) {
  // A balloon needs an icon; keep a temporary one until it is dismissed.
  balloon_active_ = true;
  balloon_payload_ = std::move(payload);
  RefreshIcon();
  if (!icon_added_) return;
  NOTIFYICONDATAW data = {sizeof(NOTIFYICONDATAW)};
  data.hWnd = window_;
  data.uID = kTrayIconId;
  data.uFlags = NIF_INFO;
  CopyText(data.szInfoTitle, title);
  CopyText(data.szInfo, body);
  data.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON | NIIF_RESPECT_QUIET_TIME;
  data.hBalloonIcon = balloon_icon_;
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

bool DesktopShell::EnsureTaskbar() {
  if (taskbar_) return true;
  if (FAILED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
    taskbar_ = nullptr;
    return false;
  }
  if (FAILED(taskbar_->HrInit())) {
    taskbar_->Release();
    taskbar_ = nullptr;
    return false;
  }
  return true;
}

void DesktopShell::SetTaskbarProgress(int state, double fraction) {
  progress_state_ = state;
  progress_fraction_ = (std::min)(1.0, (std::max)(0.0, fraction));
  ApplyTaskbarProgress();
}

void DesktopShell::ApplyTaskbarProgress() {
  // Wait for TaskbarButtonCreated; the state is re-applied then.
  if (!taskbar_button_ready_ || !EnsureTaskbar()) return;
  TBPFLAG flag = TBPF_NOPROGRESS;
  switch (progress_state_) {
    case 1: flag = TBPF_NORMAL; break;
    case 2: flag = TBPF_PAUSED; break;
    case 3: flag = TBPF_ERROR; break;
    case 4: flag = TBPF_INDETERMINATE; break;
  }
  taskbar_->SetProgressState(window_, flag);
  // Indeterminate and none ignore the value; the others show the bar.
  if (flag == TBPF_NORMAL || flag == TBPF_PAUSED || flag == TBPF_ERROR) {
    taskbar_->SetProgressValue(
        window_, static_cast<ULONGLONG>(std::lround(progress_fraction_ * 1000)),
        1000);
  }
}

void DesktopShell::SetThumbButtons(bool visible, bool playing,
                                   bool can_previous, bool can_next) {
  thumb_visible_ = visible;
  thumb_playing_ = playing;
  thumb_can_previous_ = can_previous;
  thumb_can_next_ = can_next;
  ApplyThumbButtons();
}

void DesktopShell::ApplyThumbButtons() {
  // Nothing to hide before the first add; buttons cannot be removed, only
  // hidden, once ThumbBarAddButtons ran.
  if (!thumb_visible_ && !thumb_added_) return;
  if (!taskbar_button_ready_ || !EnsureTaskbar()) return;
  const int size = ::GetSystemMetrics(SM_CXSMICON);
  if (!icon_previous_) icon_previous_ = MakeGlyphIcon(Glyph::kPrevious, size);
  if (!icon_play_) icon_play_ = MakeGlyphIcon(Glyph::kPlay, size);
  if (!icon_pause_) icon_pause_ = MakeGlyphIcon(Glyph::kPause, size);
  if (!icon_next_) icon_next_ = MakeGlyphIcon(Glyph::kNext, size);
  THUMBBUTTON buttons[3] = {};
  const DWORD hidden = thumb_visible_ ? 0 : THBF_HIDDEN;
  buttons[0].iId = kThumbPrevious;
  buttons[0].hIcon = icon_previous_;
  CopyText(buttons[0].szTip, labels_.thumb_previous);
  buttons[0].dwFlags = static_cast<THUMBBUTTONFLAGS>(
      (thumb_can_previous_ ? THBF_ENABLED : THBF_DISABLED) | hidden);
  buttons[1].iId = kThumbPlayPause;
  buttons[1].hIcon = thumb_playing_ ? icon_pause_ : icon_play_;
  CopyText(buttons[1].szTip,
           thumb_playing_ ? labels_.thumb_pause : labels_.thumb_play);
  buttons[1].dwFlags = static_cast<THUMBBUTTONFLAGS>(THBF_ENABLED | hidden);
  buttons[2].iId = kThumbNext;
  buttons[2].hIcon = icon_next_;
  CopyText(buttons[2].szTip, labels_.thumb_next);
  buttons[2].dwFlags = static_cast<THUMBBUTTONFLAGS>(
      (thumb_can_next_ ? THBF_ENABLED : THBF_DISABLED) | hidden);
  for (auto& button : buttons) {
    button.dwMask = static_cast<THUMBBUTTONMASK>(THB_ICON | THB_TOOLTIP |
                                                 THB_FLAGS);
  }
  if (!thumb_added_) {
    thumb_added_ =
        SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons));
  } else {
    taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
  }
}
