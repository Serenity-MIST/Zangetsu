#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_COM_APARTMENT_UTIL_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_COM_APARTMENT_UTIL_H_

// Zangetsu patch: WebView2 refuses to start (CO_E_NOTINITIALIZED, "CoInitialize
// has not been called.") when the platform thread is not a COM single-threaded
// apartment at the moment an environment or controller is created. On Windows
// this blocked every Cloudflare verification window and the headless browser
// replay. These helpers make sure the calling thread is an STA right before
// WebView2 is touched, whatever happened to the apartment earlier.

#include <objbase.h>
#include <windows.h>

#include <atomic>
#include <string>

namespace flutter_inappwebview_plugin
{
  // Bumped every time ensureComApartment() had to (re)initialize COM on the
  // calling thread. Shared WinRT/composition objects created under an older
  // generation belong to an apartment that was torn down and must be rebuilt.
  inline std::atomic<unsigned int> comApartmentGeneration{ 0 };

  // Makes sure the calling thread is a COM STA. Returns S_OK when the thread
  // is (now) usable for WebView2, or the failing HRESULT otherwise (for
  // example RPC_E_CHANGED_MODE when some code made it multithreaded).
  inline HRESULT ensureComApartment()
  {
    const HRESULT hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (hr == S_FALSE) {
      // Already an STA: drop the extra reference this probe just took so the
      // runner's own init/uninit stays balanced.
      ::CoUninitialize();
      return S_OK;
    }
    if (hr == S_OK) {
      // COM was not initialized here (torn down by someone, or only the
      // implicit MTA). Keep this reference for the rest of the thread's life
      // on purpose: the platform thread lives until the process exits.
      comApartmentGeneration.fetch_add(1);
      ::OutputDebugStringW(
        L"\nflutter_inappwebview_windows: COM was not initialized on the "
        L"platform thread; re-initialized it as an STA.\n");
      return S_OK;
    }
    return hr;
  }

  // Short text describing the calling thread's apartment, appended to
  // environment errors so a remaining failure is diagnosable from app logs.
  inline std::string describeComApartment()
  {
    APTTYPE type = APTTYPE_CURRENT;
    APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
    const HRESULT hr = ::CoGetApartmentType(&type, &qualifier);
    if (hr == CO_E_NOTINITIALIZED) {
      return "apartment=none";
    }
    if (FAILED(hr)) {
      return "apartment=unknown(hr=" + std::to_string(static_cast<long>(hr)) + ")";
    }
    std::string name;
    switch (type) {
    case APTTYPE_STA: name = "sta"; break;
    case APTTYPE_MAINSTA: name = "main-sta"; break;
    case APTTYPE_MTA: name = "mta"; break;
    case APTTYPE_NA: name = "neutral"; break;
    default: name = std::to_string(static_cast<int>(type)); break;
    }
    return "apartment=" + name + " qualifier=" + std::to_string(static_cast<int>(qualifier)) +
      " thread=" + std::to_string(static_cast<unsigned long>(::GetCurrentThreadId()));
  }
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_COM_APARTMENT_UTIL_H_
