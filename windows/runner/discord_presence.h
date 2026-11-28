#ifndef RUNNER_DISCORD_PRESENCE_H_
#define RUNNER_DISCORD_PRESENCE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Discord status through Discord's own SDK, on the same method channel the
// phone app uses (zangetsu/discord_presence). Everything runs on the platform
// thread; only the first load of the SDK file happens on a worker thread.
// The SDK is not connected to anything until Dart calls start.
class DiscordPresence {
 public:
  explicit DiscordPresence(flutter::BinaryMessenger* messenger);
  ~DiscordPresence();

  DiscordPresence(const DiscordPresence&) = delete;
  DiscordPresence& operator=(const DiscordPresence&) = delete;

 private:
  using Value = flutter::EncodableValue;
  using Result = std::unique_ptr<flutter::MethodResult<Value>>;

  // A start that arrived while the SDK file was still loading.
  struct PendingStart {
    uint64_t application_id;
    std::string token;
    Result result;
  };

  void Handle(const flutter::MethodCall<Value>& call, Result result);
  // Loads the SDK file once, in the background. Never opens a connection.
  void BeginLoad();
  // |reason| is "ok", or a short word on why the SDK cannot be used.
  void OnLoaded(const std::string& reason);
  void Start(uint64_t application_id, const std::string& token, Result result);
  // Answers a waiting start with an error and forgets its token.
  void DropPendingStart(const char* message);
  void Pump();
  static DWORD WINAPI LoadThread(LPVOID window);
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  // Hidden message-only window: owns the pump timer and the load result.
  HWND window_ = nullptr;
  enum class Sdk { kUnknown, kLoading, kMissing, kReady } sdk_ = Sdk::kUnknown;
  // What isAvailable answers once the load has finished.
  std::string reason_;
  // isAvailable calls waiting for the load.
  std::vector<Result> waiting_;
  std::optional<PendingStart> pending_start_;
  bool running_ = false;
};

#endif  // RUNNER_DISCORD_PRESENCE_H_
