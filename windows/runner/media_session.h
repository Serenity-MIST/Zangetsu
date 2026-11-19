#ifndef RUNNER_MEDIA_SESSION_H_
#define RUNNER_MEDIA_SESSION_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

// What the player is showing, for the Windows media overlay / lock screen.
struct MediaSessionInfo {
  std::wstring title;
  std::wstring subtitle;
  std::wstring artwork_url;  // http(s) only; empty keeps no thumbnail
  bool playing = false;
  int64_t position_ms = -1;  // -1 when unknown
  int64_t duration_ms = -1;  // -1 when unknown
  bool can_next = false;
  bool can_previous = false;
};

// System Media Transport Controls (the Windows media flyout, lock screen
// and hardware media keys) for the main window, through the documented
// ISystemMediaTransportControlsInterop. Button presses arrive on a worker
// thread and are posted back to |window| as kMediaCommandMessage with the
// MediaCommandKind in wparam and a seek position (ms) in lparam.
class MediaSession {
 public:
  explicit MediaSession(HWND window);
  ~MediaSession();

  MediaSession(const MediaSession&) = delete;
  MediaSession& operator=(const MediaSession&) = delete;

  // Shows / refreshes the overlay. Returns false when Windows has no SMTC.
  bool Update(const MediaSessionInfo& info);
  // Hides the overlay until the next Update.
  void Clear();
  // True between Update and Clear; media keys are then routed by Windows
  // to SMTC, so WM_APPCOMMAND must not report them a second time.
  bool active() const { return active_; }

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  bool active_ = false;
};

#endif  // RUNNER_MEDIA_SESSION_H_
