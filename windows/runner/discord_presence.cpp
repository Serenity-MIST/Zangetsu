#include "discord_presence.h"

// The SDK's C functions come from its DLL (its header would mark them as
// exported by us).
#define DISCORD_API __declspec(dllimport)
#define DISCORDPP_IMPLEMENTATION
#include <discordpp.h>

#include <delayimp.h>
#include <flutter/standard_method_codec.h>

#include <cstdlib>
#include <deque>
#include <utility>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kDll[] = "discord_partner_sdk.dll";
constexpr wchar_t kDllWide[] = L"discord_partner_sdk.dll";
constexpr wchar_t kWindowClass[] = L"ZANGETSU_DISCORD_PUMP";
constexpr UINT kLoadedMessage = WM_APP + 1;
constexpr UINT_PTR kPumpTimer = 1;
constexpr UINT kPumpMs = 100;
// How long quitting may wait for the removed status to reach Discord.
constexpr ULONGLONG kQuitFlushMs = 300;
constexpr DWORD kQuitPumpMs = 10;

constexpr char kUnavailable[] = "DISCORD_SDK_UNAVAILABLE";
constexpr char kError[] = "DISCORD_SDK_ERROR";

// What the load thread found, sent with kLoadedMessage (the Windows error
// number goes with it).
enum class Load : WPARAM { kOk, kFile, kImports };

struct SdkState {
  std::unique_ptr<discordpp::Client> client;
  std::optional<discordpp::Activity> activity;
  discordpp::StatusType status = discordpp::StatusType::Online;
  std::deque<std::string> events;
  // Goes up with every start and close, so late answers of an older client
  // are ignored.
  uint64_t generation = 0;
  bool ready = false;
  bool has_pending = false;
};

// Never freed on purpose: if the process ends without a normal quit, nothing
// may call into the SDK while Windows is already unloading it.
SdkState& S() {
  static SdkState* const state = new SdkState();
  return *state;
}

// The delay-load helper raises a Windows exception when the DLL or one of
// its functions is missing, so no C++ objects may live in this function.
bool LoadSdkImports() {
  __try {
    return SUCCEEDED(__HrLoadAllImportsForDll(kDll));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// Only ever the copy next to the app, never one found on PATH. The file stays
// loaded until the process ends: the SDK keeps threads of its own.
Load LoadSdk(DWORD* error) {
  wchar_t path[MAX_PATH * 4];
  ::SetLastError(ERROR_SUCCESS);
  const DWORD length = ::GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
  if (length == 0 || length >= ARRAYSIZE(path)) {
    *error = ::GetLastError();
    return Load::kFile;
  }
  std::wstring file(path, length);
  file.resize(file.find_last_of(L'\\') + 1);
  file += kDllWide;
  if (!::LoadLibraryExW(file.c_str(), nullptr,
                        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                            LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    *error = ::GetLastError();
    return Load::kFile;
  }
  return LoadSdkImports() ? Load::kOk : Load::kImports;
}

// Only state names and numbers are ever queued: no tokens, titles or texts
// from the SDK.
void Event(std::string value) {
  auto& events = S().events;
  if (events.size() == 32) events.pop_front();
  events.push_back(std::move(value));
}

void Report(const discordpp::ClientResult& result, const char* what) {
  if (result.Successful()) {
    Event(std::string(what) + ":ok");
    return;
  }
  if (result.Status() == discordpp::HttpStatusCode::Unauthorized) {
    Event("authFailed");
  }
  Event(std::string(what) +
        ":error=" + std::to_string(static_cast<int>(result.Type())) +
        ":http=" + std::to_string(static_cast<int>(result.Status())) +
        ":code=" + std::to_string(result.ErrorCode()));
}

// Sends the wanted status, once the SDK is connected.
void Publish() {
  auto& s = S();
  if (!s.client || !s.ready || !s.has_pending) return;
  const auto current = s.generation;
  s.client->SetOnlineStatus(
      s.status, [current](discordpp::ClientResult result) {
        if (current == S().generation) Report(result, "onlineStatus");
      });
  if (!s.activity) {
    s.client->ClearRichPresence();
    Event("cleared");
    return;
  }
  s.client->UpdateRichPresence(
      *s.activity, [current](discordpp::ClientResult result) {
        if (current == S().generation) Report(result, "published");
      });
}

void StartClient(uint64_t application_id, const std::string& token) {
  auto& s = S();
  const auto current = ++s.generation;
  s.ready = false;
  s.client.reset();
  s.client = std::make_unique<discordpp::Client>();
  s.client->SetApplicationId(application_id);
  s.client->SetStatusChangedCallback(
      [current](discordpp::Client::Status status,
                discordpp::Client::Error error, int32_t detail) {
        auto& state = S();
        if (current != state.generation || !state.client) return;
        state.ready = status == discordpp::Client::Status::Ready;
        Event(std::string("connection:") +
              discordpp::Client::StatusToString(status) +
              ":error=" + std::to_string(static_cast<int>(error)) +
              ":detail=" + std::to_string(detail));
        if (state.ready) Publish();
        if (detail == 4004) Event("authFailed");
      });
  s.client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, token,
                        [current](discordpp::ClientResult result) {
                          auto& state = S();
                          if (current != state.generation || !state.client) {
                            return;
                          }
                          Report(result, "token");
                          if (result.Successful()) state.client->Connect();
                        });
}

void CloseClient() {
  auto& s = S();
  ++s.generation;
  s.ready = false;
  s.has_pending = false;
  s.activity.reset();
  if (s.client) {
    s.client->ClearRichPresence();
    s.client->Disconnect();
    s.client.reset();
  }
  s.events.clear();
}

// Quitting: take the status off the profile and give the SDK a short moment
// to send that, then close. Nothing is told to Dart any more.
void FlushAndCloseClient() {
  auto& s = S();
  s.has_pending = false;
  if (s.client && s.ready) {
    s.client->ClearRichPresence();
    const ULONGLONG end = ::GetTickCount64() + kQuitFlushMs;
    while (s.ready && ::GetTickCount64() < end) {
      discordpp::RunCallbacks();
      ::Sleep(kQuitPumpMs);
    }
  }
  CloseClient();
}

const EncodableValue* Field(const EncodableMap* map, const char* key) {
  if (!map) return nullptr;
  const auto found = map->find(EncodableValue(std::string(key)));
  return found == map->end() ? nullptr : &found->second;
}

const EncodableMap* MapField(const EncodableMap* map, const char* key) {
  const auto* value = Field(map, key);
  return value ? std::get_if<EncodableMap>(value) : nullptr;
}

std::optional<std::string> TextField(const EncodableMap* map, const char* key) {
  const auto* value = Field(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? std::optional<std::string>(*text) : std::nullopt;
}

// Dart ints arrive as int32 or int64 depending on their size.
int64_t IntField(const EncodableMap* map, const char* key) {
  const auto* value = Field(map, key);
  if (!value) return 0;
  if (const auto* i = std::get_if<int32_t>(value)) return *i;
  if (const auto* l = std::get_if<int64_t>(value)) return *l;
  return 0;
}

std::vector<std::string> TextList(const EncodableMap* map, const char* key) {
  std::vector<std::string> out;
  const auto* value = Field(map, key);
  const auto* list = value ? std::get_if<EncodableList>(value) : nullptr;
  if (!list) return out;
  for (const auto& item : *list) {
    if (const auto* text = std::get_if<std::string>(&item)) out.push_back(*text);
  }
  return out;
}

discordpp::StatusType StatusFor(const std::optional<std::string>& status) {
  const std::string name = status.value_or("online");
  if (name == "idle") return discordpp::StatusType::Idle;
  if (name == "dnd") return discordpp::StatusType::Dnd;
  if (name == "invisible") return discordpp::StatusType::Invisible;
  return discordpp::StatusType::Online;
}

discordpp::Activity BuildActivity(const EncodableMap* map) {
  discordpp::Activity activity;
  activity.SetName(TextField(map, "name").value_or("Zangetsu"));
  activity.SetType(static_cast<discordpp::ActivityTypes>(IntField(map, "type")));
  activity.SetDetails(TextField(map, "details"));
  activity.SetState(TextField(map, "state"));
  const auto* images = MapField(map, "assets");
  discordpp::ActivityAssets assets;
  assets.SetLargeImage(TextField(images, "large_image"));
  assets.SetLargeText(TextField(images, "large_text"));
  assets.SetSmallImage(TextField(images, "small_image"));
  assets.SetSmallText(TextField(images, "small_text"));
  activity.SetAssets(assets);
  const auto* times = MapField(map, "timestamps");
  const int64_t start = IntField(times, "start");
  const int64_t end = IntField(times, "end");
  if (start > 0 || end > 0) {
    discordpp::ActivityTimestamps timestamps;
    if (start > 0) timestamps.SetStart(static_cast<uint64_t>(start));
    if (end > 0) timestamps.SetEnd(static_cast<uint64_t>(end));
    activity.SetTimestamps(timestamps);
  }
  const auto labels = TextList(map, "buttons");
  const auto urls = TextList(MapField(map, "metadata"), "button_urls");
  for (size_t i = 0; i < labels.size() && i < urls.size() && i < 2; ++i) {
    discordpp::ActivityButton button;
    button.SetLabel(labels[i]);
    button.SetUrl(urls[i]);
    activity.AddButton(button);
  }
  return activity;
}

}  // namespace

DiscordPresence::DiscordPresence(flutter::BinaryMessenger* messenger) {
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = &DiscordPresence::WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassW(&window_class);
  window_ = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                              nullptr, window_class.hInstance, nullptr);
  if (window_) {
    ::SetWindowLongPtrW(window_, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
  } else {
    // Without it the SDK could never be pumped; Dart uses its own connection.
    OnLoaded("window");
  }
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "zangetsu/discord_presence",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
}

DiscordPresence::~DiscordPresence() {
  if (window_) ::KillTimer(window_, kPumpTimer);
  if (running_) {
    running_ = false;
    FlushAndCloseClient();
  }
  channel_->SetMethodCallHandler(nullptr);
  DropPendingStart("The app is closing");
  auto waiting = std::move(waiting_);
  waiting_.clear();
  for (auto& result : waiting) result->Error(kError, "The app is closing");
  if (window_) {
    // A load still running posts to a window that is gone, which is harmless.
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
}

void DiscordPresence::Handle(const flutter::MethodCall<Value>& call,
                             Result result) {
  const auto* args =
      call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
  const std::string& method = call.method_name();
  if (method == "isAvailable") {
    if (sdk_ == Sdk::kReady || sdk_ == Sdk::kMissing) {
      result->Success(Value(reason_));
      return;
    }
    waiting_.push_back(std::move(result));
    BeginLoad();
    return;
  }
  if (method == "start") {
    if (sdk_ == Sdk::kMissing) {
      result->Error(kUnavailable, "Discord SDK is not loaded");
      return;
    }
    const auto token = TextField(args, "token");
    const auto id = TextField(args, "applicationId");
    const uint64_t app = id ? std::strtoull(id->c_str(), nullptr, 10) : 0;
    if (!token || token->empty() || app == 0) {
      result->Error(kError, "Token or application id missing");
      return;
    }
    if (sdk_ == Sdk::kReady) {
      Start(app, *token, std::move(result));
      return;
    }
    // Still loading: answered by OnLoaded, and only the latest start counts.
    DropPendingStart("Replaced by a newer start");
    pending_start_ = PendingStart{app, *token, std::move(result)};
    BeginLoad();
    return;
  }
  if (method == "update") {
    const auto* activity = MapField(args, "activity");
    if (!running_ || !activity) {
      result->Error(kError, running_ ? "Activity missing"
                                     : "Discord SDK is not started");
      return;
    }
    auto& s = S();
    s.status = StatusFor(TextField(args, "status"));
    s.activity = BuildActivity(activity);
    s.has_pending = true;
    Publish();
    result->Success();
    return;
  }
  if (method == "clear") {
    if (running_) {
      auto& s = S();
      s.status = StatusFor(TextField(args, "status"));
      s.activity.reset();
      s.has_pending = true;
      Publish();
    }
    result->Success();
    return;
  }
  if (method == "close") {
    DropPendingStart("Closed before it started");
    if (running_) {
      running_ = false;
      ::KillTimer(window_, kPumpTimer);
      CloseClient();
    }
    result->Success();
    return;
  }
  result->NotImplemented();
}

void DiscordPresence::BeginLoad() {
  if (sdk_ != Sdk::kUnknown) return;
  sdk_ = Sdk::kLoading;
  const HANDLE thread = ::CreateThread(
      nullptr, 0, &DiscordPresence::LoadThread, window_, 0, nullptr);
  if (!thread) {
    OnLoaded("load=" + std::to_string(::GetLastError()));
    return;
  }
  ::CloseHandle(thread);
}

DWORD WINAPI DiscordPresence::LoadThread(LPVOID window) {
  DWORD error = ERROR_SUCCESS;
  const Load load = LoadSdk(&error);
  ::PostMessageW(static_cast<HWND>(window), kLoadedMessage,
                 static_cast<WPARAM>(load), static_cast<LPARAM>(error));
  return 0;
}

void DiscordPresence::OnLoaded(const std::string& reason) {
  reason_ = reason;
  sdk_ = reason == "ok" ? Sdk::kReady : Sdk::kMissing;
  auto waiting = std::move(waiting_);
  waiting_.clear();
  for (auto& result : waiting) result->Success(Value(reason_));
  if (!pending_start_) return;
  PendingStart start = std::move(*pending_start_);
  pending_start_.reset();
  if (sdk_ == Sdk::kReady) {
    Start(start.application_id, start.token, std::move(start.result));
  } else {
    start.result->Error(kUnavailable, "Discord SDK is not loaded");
  }
}

void DiscordPresence::Start(uint64_t application_id, const std::string& token,
                            Result result) {
  // The timer first: a client nobody pumps would never get anywhere.
  if (!::SetTimer(window_, kPumpTimer, kPumpMs, nullptr)) {
    result->Error(kUnavailable, "Discord SDK timer could not be started");
    return;
  }
  StartClient(application_id, token);
  running_ = true;
  result->Success();
}

void DiscordPresence::DropPendingStart(const char* message) {
  if (!pending_start_) return;
  PendingStart start = std::move(*pending_start_);
  pending_start_.reset();
  // Not "unavailable": the SDK itself is fine, this call is just out of date.
  start.result->Error(kError, message);
}

void DiscordPresence::Pump() {
  if (!running_) return;
  discordpp::RunCallbacks();
  // Told to Dart only after the SDK is done with its callbacks.
  auto& events = S().events;
  while (running_ && !events.empty()) {
    std::string event = std::move(events.front());
    events.pop_front();
    channel_->InvokeMethod(event == "authFailed" ? "authFailed" : "status",
                           std::make_unique<Value>(event));
  }
}

LRESULT CALLBACK DiscordPresence::WindowProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<DiscordPresence*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (self && message == WM_TIMER && wparam == kPumpTimer) {
    self->Pump();
    return 0;
  }
  if (self && message == kLoadedMessage) {
    switch (static_cast<Load>(wparam)) {
      case Load::kOk:
        self->OnLoaded("ok");
        break;
      case Load::kFile:
        self->OnLoaded("load=" + std::to_string(static_cast<DWORD>(lparam)));
        break;
      case Load::kImports:
        self->OnLoaded("imports");
        break;
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
