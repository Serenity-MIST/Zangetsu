#ifndef RUNNER_DESKTOP_REGISTRY_H_
#define RUNNER_DESKTOP_REGISTRY_H_

#include <windows.h>

// Per-user registry helpers for the Windows shell features: window placement
// memory (HKCU\Software\Zangetsu\Window) and launch at sign-in
// (HKCU\Software\Microsoft\Windows\CurrentVersion\Run). Nothing here needs
// elevation and every failure is silently treated as "use the default".

// Where and how the main window opens on launch, in physical screen pixels.
struct InitialWindowRect {
  RECT frame;
  bool maximized;
};

// True when the window should reopen where it was closed (DWORD Remember,
// default 1 when the value has never been written).
bool IsRememberWindowPlacementEnabled();

// Stores the Remember flag that the settings page toggles.
void SetRememberWindowPlacementEnabled(bool enabled);

// Saved placement when Remember is on and the saved frame still touches a
// connected monitor; otherwise a frame centred on the monitor under the
// cursor at about 80% of its work area.
InitialWindowRect ComputeInitialWindowRect();

// Writes |placement| (from GetWindowPlacement) when Remember is on.
void SaveWindowPlacement(const WINDOWPLACEMENT& placement);

// True when the Run value named "Zangetsu" exists for this user.
bool IsLaunchAtSignInEnabled();

// Adds ("<exe>" --autostart) or removes the Run value. Returns success.
bool SetLaunchAtSignIn(bool enabled);

// True when this process was started by the Run value (--autostart flag).
bool WasLaunchedAtSignIn();

// Starts a fresh copy of this executable with the same command line. Used
// by "restart" after the single-instance mutex has been released.
bool RelaunchCurrentProcess();

#endif  // RUNNER_DESKTOP_REGISTRY_H_
