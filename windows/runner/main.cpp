#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "desktop_registry.h"
#include "desktop_shell.h"
#include "flutter_window.h"
#include "utils.h"
#include "app_links/app_links_plugin_c_api.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Hive's files are shared by every copy of the app. Keep one instance per
  // Windows session so a second launch cannot contend for the database locks.
  HANDLE app_mutex = ::CreateMutexW(nullptr, FALSE, L"Local\\com.spyou.Zangetsu");
  if (app_mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Zangetsu");
    if (existing) {
      // OAuth launches a second process with the callback URI. Forward it to
      // app_links before exiting, so the in-memory PKCE verifier stays usable.
      SendAppLink(existing);
      if (!::IsWindowVisible(existing)) {
        // Hidden in the tray: let the window restore itself so its tray
        // state stays consistent.
        ::PostMessageW(existing,
                       ::RegisterWindowMessageW(kRestoreWindowMessageName), 0,
                       0);
      } else if (::IsIconic(existing)) {
        // Only un-minimise. SW_RESTORE on a maximised or fullscreen window
        // would shrink it, which every tracker sign-in used to do.
        ::ShowWindow(existing, SW_RESTORE);
      }
      // Allow the existing process to take focus, then bring it forward
      // without touching its size.
      DWORD existing_process = 0;
      ::GetWindowThreadProcessId(existing, &existing_process);
      ::AllowSetForegroundWindow(existing_process);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(app_mutex);
    return EXIT_SUCCESS;
  }
  // Claim zangetsu:// for this user on every primary launch, so tracker
  // sign-in redirects and website "open in app" links reach this executable
  // even before any account was connected (and after the app was moved).
  // Best effort: account connect re-registers and reports a failure itself.
  RegisterUrlProtocol(L"zangetsu");
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM as a single-threaded apartment explicitly (WebView2, used
  // for Cloudflare verification and the browser replay, requires an STA on
  // this thread), then OLE, which the drag-and-drop target on the Flutter
  // view needs. Each successful call holds its own reference, so a stray
  // uninitialize elsewhere cannot leave the platform thread without COM.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const HRESULT ole_result = ::OleInitialize(nullptr);
  if (FAILED(com_result) || FAILED(ole_result)) {
    wchar_t message[160];
    ::swprintf_s(message, L"Zangetsu: COM init failed (CoInitializeEx=0x%08lx, "
                          L"OleInitialize=0x%08lx)\n",
                 static_cast<unsigned long>(com_result),
                 static_cast<unsigned long>(ole_result));
    ::OutputDebugStringW(message);
  }

  flutter::DartProject project(L"data");

  // Draw with Flutter's Skia renderer. Measured on an Intel UHD 620 laptop
  // (same build, same Home scroll): about 5 ms per frame and 300 MB of memory,
  // against 25 ms and 900 MB with the newer Impeller renderer, which made
  // every page feel laggy. Starting the app with ZANGETSU_RENDERER=impeller
  // brings Impeller back, so a later Flutter can be compared again. Flutter
  // may remove this switch in a later version.
  wchar_t renderer[16] = {};
  const DWORD renderer_length = ::GetEnvironmentVariableW(
      L"ZANGETSU_RENDERER", renderer, ARRAYSIZE(renderer));
  const bool use_impeller = renderer_length > 0 &&
                            renderer_length < ARRAYSIZE(renderer) &&
                            ::_wcsicmp(renderer, L"impeller") == 0;
  if (!use_impeller) {
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Reopen where the window was last closed (when remembered and that
  // monitor still exists), else centred at ~80% of the cursor's monitor.
  const InitialWindowRect initial = ComputeInitialWindowRect();
  if (!window.CreateAt(L"Zangetsu", initial.frame, initial.maximized)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Release in reverse order, only what actually succeeded.
  if (SUCCEEDED(ole_result)) ::OleUninitialize();
  if (SUCCEEDED(com_result)) ::CoUninitialize();
  if (app_mutex) ::CloseHandle(app_mutex);
  // "Restart" from Dart: start the new copy only after the single-instance
  // mutex is released, otherwise it would just hand over to this process.
  if (window.restart_requested()) RelaunchCurrentProcess();
  return EXIT_SUCCESS;
}
