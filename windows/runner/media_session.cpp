#include "media_session.h"

#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <windows.foundation.h>
#include <windows.media.h>
#include <windows.storage.streams.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include "desktop_shell.h"

// Plain WRL/ABI (header-only, no exceptions) instead of C++/WinRT: the
// runner builds with _HAS_EXCEPTIONS=0, which C++/WinRT does not support.
using ABI::Windows::Foundation::ITypedEventHandler;
using ABI::Windows::Foundation::IUriRuntimeClass;
using ABI::Windows::Foundation::IUriRuntimeClassFactory;
using ABI::Windows::Foundation::TimeSpan;
using ABI::Windows::Media::IPlaybackPositionChangeRequestedEventArgs;
using ABI::Windows::Media::ISystemMediaTransportControls;
using ABI::Windows::Media::ISystemMediaTransportControls2;
using ABI::Windows::Media::ISystemMediaTransportControlsButtonPressedEventArgs;
using ABI::Windows::Media::ISystemMediaTransportControlsDisplayUpdater;
using ABI::Windows::Media::ISystemMediaTransportControlsTimelineProperties;
using ABI::Windows::Media::IVideoDisplayProperties;
using ABI::Windows::Media::MediaPlaybackStatus;
using ABI::Windows::Media::MediaPlaybackType;
using ABI::Windows::Media::PlaybackPositionChangeRequestedEventArgs;
using ABI::Windows::Media::SystemMediaTransportControls;
using ABI::Windows::Media::SystemMediaTransportControlsButton;
using ABI::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using ABI::Windows::Storage::Streams::IRandomAccessStreamReference;
using ABI::Windows::Storage::Streams::IRandomAccessStreamReferenceStatics;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

// WinRT TimeSpan ticks are 100 ns.
TimeSpan Ticks(int64_t ms) {
  TimeSpan span;
  span.Duration = ms * 10000;
  return span;
}

// HSTRING view over a std::wstring for the duration of one call.
HStringReference Ref(const std::wstring& text) {
  return HStringReference(text.c_str(), static_cast<UINT>(text.size()));
}

}  // namespace

struct MediaSession::Impl {
  HWND window = nullptr;
  ComPtr<ISystemMediaTransportControls> controls;
  EventRegistrationToken button_token = {};
  EventRegistrationToken seek_token = {};
  std::wstring artwork_url;
  bool initialised = false;

  // Fetches the window's SMTC once and subscribes to its buttons.
  bool Initialise() {
    if (initialised) return controls != nullptr;
    initialised = true;
    ComPtr<ISystemMediaTransportControlsInterop> interop;
    if (FAILED(::RoGetActivationFactory(
            HStringReference(
                RuntimeClass_Windows_Media_SystemMediaTransportControls)
                .Get(),
            IID_PPV_ARGS(&interop)))) {
      return false;
    }
    if (FAILED(interop->GetForWindow(window, IID_PPV_ARGS(&controls)))) {
      controls = nullptr;
      return false;
    }
    const HWND target = window;
    // Runs on a WinRT worker thread: only post to the UI thread here.
    auto on_button = Callback<ITypedEventHandler<
        SystemMediaTransportControls*,
        SystemMediaTransportControlsButtonPressedEventArgs*>>(
        [target](ISystemMediaTransportControls*,
                 ISystemMediaTransportControlsButtonPressedEventArgs* args)
            -> HRESULT {
          SystemMediaTransportControlsButton button;
          if (FAILED(args->get_Button(&button))) return S_OK;
          int kind = -1;
          switch (button) {
            case SystemMediaTransportControlsButton::
                SystemMediaTransportControlsButton_Play:
              kind = static_cast<int>(MediaCommandKind::kPlay);
              break;
            case SystemMediaTransportControlsButton::
                SystemMediaTransportControlsButton_Pause:
              kind = static_cast<int>(MediaCommandKind::kPause);
              break;
            case SystemMediaTransportControlsButton::
                SystemMediaTransportControlsButton_Stop:
              kind = static_cast<int>(MediaCommandKind::kStop);
              break;
            case SystemMediaTransportControlsButton::
                SystemMediaTransportControlsButton_Next:
              kind = static_cast<int>(MediaCommandKind::kNext);
              break;
            case SystemMediaTransportControlsButton::
                SystemMediaTransportControlsButton_Previous:
              kind = static_cast<int>(MediaCommandKind::kPrevious);
              break;
            default:
              break;
          }
          if (kind >= 0) {
            ::PostMessageW(target, kMediaCommandMessage,
                           static_cast<WPARAM>(kind), -1);
          }
          return S_OK;
        });
    if (on_button) controls->add_ButtonPressed(on_button.Get(), &button_token);
    // Seeking from the flyout's timeline (Windows 10 1607+).
    ComPtr<ISystemMediaTransportControls2> controls2;
    if (SUCCEEDED(controls.As(&controls2))) {
      auto on_seek = Callback<ITypedEventHandler<
          SystemMediaTransportControls*,
          PlaybackPositionChangeRequestedEventArgs*>>(
          [target](ISystemMediaTransportControls*,
                   IPlaybackPositionChangeRequestedEventArgs* args)
              -> HRESULT {
            TimeSpan position;
            if (SUCCEEDED(args->get_RequestedPlaybackPosition(&position))) {
              ::PostMessageW(target, kMediaCommandMessage,
                             static_cast<WPARAM>(MediaCommandKind::kSeek),
                             static_cast<LPARAM>(position.Duration / 10000));
            }
            return S_OK;
          });
      if (on_seek) {
        controls2->add_PlaybackPositionChangeRequested(on_seek.Get(),
                                                       &seek_token);
      }
    }
    return true;
  }

  // Applies an http(s) artwork URL as the flyout thumbnail (cached by URL).
  void ApplyArtwork(ISystemMediaTransportControlsDisplayUpdater* updater,
                    const std::wstring& url) {
    if (url == artwork_url) return;
    artwork_url = url;
    if (url.rfind(L"http://", 0) != 0 && url.rfind(L"https://", 0) != 0) {
      updater->put_Thumbnail(nullptr);
      return;
    }
    ComPtr<IUriRuntimeClassFactory> uri_factory;
    ComPtr<IUriRuntimeClass> uri;
    ComPtr<IRandomAccessStreamReferenceStatics> streams;
    ComPtr<IRandomAccessStreamReference> thumbnail;
    if (FAILED(::RoGetActivationFactory(
            HStringReference(RuntimeClass_Windows_Foundation_Uri).Get(),
            IID_PPV_ARGS(&uri_factory))) ||
        FAILED(uri_factory->CreateUri(Ref(url).Get(), &uri)) ||
        FAILED(::RoGetActivationFactory(
            HStringReference(
                RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference)
                .Get(),
            IID_PPV_ARGS(&streams))) ||
        FAILED(streams->CreateFromUri(uri.Get(), &thumbnail))) {
      return;
    }
    updater->put_Thumbnail(thumbnail.Get());
  }
};

MediaSession::MediaSession(HWND window) : impl_(std::make_unique<Impl>()) {
  impl_->window = window;
}

MediaSession::~MediaSession() {
  if (impl_->controls) {
    impl_->controls->remove_ButtonPressed(impl_->button_token);
    ComPtr<ISystemMediaTransportControls2> controls2;
    if (SUCCEEDED(impl_->controls.As(&controls2))) {
      controls2->remove_PlaybackPositionChangeRequested(impl_->seek_token);
    }
  }
}

bool MediaSession::Update(const MediaSessionInfo& info) {
  if (!impl_->Initialise()) return false;
  auto& controls = impl_->controls;
  controls->put_IsEnabled(true);
  controls->put_IsPlayEnabled(true);
  controls->put_IsPauseEnabled(true);
  controls->put_IsStopEnabled(true);
  controls->put_IsNextEnabled(info.can_next);
  controls->put_IsPreviousEnabled(info.can_previous);
  controls->put_PlaybackStatus(
      info.playing ? MediaPlaybackStatus::MediaPlaybackStatus_Playing
                   : MediaPlaybackStatus::MediaPlaybackStatus_Paused);
  ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
  if (SUCCEEDED(controls->get_DisplayUpdater(&updater))) {
    updater->put_Type(MediaPlaybackType::MediaPlaybackType_Video);
    ComPtr<IVideoDisplayProperties> video;
    if (SUCCEEDED(updater->get_VideoProperties(&video))) {
      video->put_Title(Ref(info.title).Get());
      video->put_Subtitle(Ref(info.subtitle).Get());
    }
    impl_->ApplyArtwork(updater.Get(), info.artwork_url);
    updater->Update();
  }
  // Timeline lets the flyout show progress and offer seeking.
  ComPtr<ISystemMediaTransportControls2> controls2;
  if (info.duration_ms > 0 && SUCCEEDED(controls.As(&controls2))) {
    ComPtr<IInspectable> instance;
    ComPtr<ISystemMediaTransportControlsTimelineProperties> timeline;
    if (SUCCEEDED(::RoActivateInstance(
            HStringReference(
                RuntimeClass_Windows_Media_SystemMediaTransportControlsTimelineProperties)
                .Get(),
            &instance)) &&
        SUCCEEDED(instance.As(&timeline))) {
      const int64_t position = info.position_ms < 0 ? 0 : info.position_ms;
      timeline->put_StartTime(Ticks(0));
      timeline->put_MinSeekTime(Ticks(0));
      timeline->put_EndTime(Ticks(info.duration_ms));
      timeline->put_MaxSeekTime(Ticks(info.duration_ms));
      timeline->put_Position(Ticks(position));
      controls2->UpdateTimelineProperties(timeline.Get());
    }
  }
  active_ = true;
  return true;
}

void MediaSession::Clear() {
  active_ = false;
  if (!impl_->controls) return;
  impl_->controls->put_PlaybackStatus(
      MediaPlaybackStatus::MediaPlaybackStatus_Closed);
  ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
  if (SUCCEEDED(impl_->controls->get_DisplayUpdater(&updater))) {
    updater->ClearAll();
    updater->Update();
  }
  impl_->artwork_url.clear();
  impl_->controls->put_IsEnabled(false);
}
