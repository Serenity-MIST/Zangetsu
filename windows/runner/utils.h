#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <windows.h>

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// True for the custom URL schemes this app may claim: the shared tracker
// scheme "zangetsu" and Discord's per-application "discord-<digits>" scheme.
// Anything else is refused so the runner can never hijack another handler.
bool IsAllowedUrlScheme(const std::wstring& scheme);

// Points HKCU\Software\Classes\<scheme> at this executable so browser
// sign-in redirects relaunch the app with the URI as its only argument (the
// single-instance guard in main.cpp then forwards it to app_links). Per-user,
// no elevation; returns ERROR_SUCCESS or the failing registry status.
LSTATUS RegisterUrlProtocol(const std::wstring& scheme);

#endif  // RUNNER_UTILS_H_
