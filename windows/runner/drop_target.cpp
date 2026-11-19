#include "drop_target.h"

#include <shellapi.h>
#include <shlobj.h>

#include "utils.h"

namespace {

// Browsers put links on the clipboard under this registered format.
UINT UrlFormat() {
  static const UINT format =
      ::RegisterClipboardFormatW(L"UniformResourceLocatorW");
  return format;
}

// True when |data| offers |format| as an HGLOBAL.
bool Offers(IDataObject* data, CLIPFORMAT format) {
  FORMATETC request = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  return data && data->QueryGetData(&request) == S_OK;
}

// Reads a UTF-16 string in |format| from |data| as UTF-8.
std::optional<std::string> ReadText(IDataObject* data, CLIPFORMAT format) {
  FORMATETC request = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  if (data->GetData(&request, &medium) != S_OK) return std::nullopt;
  std::optional<std::string> result;
  if (const auto* text = static_cast<const wchar_t*>(
          ::GlobalLock(medium.hGlobal))) {
    // Bound the read by the allocation size in case it lacks a NUL.
    const size_t limit = ::GlobalSize(medium.hGlobal) / sizeof(wchar_t);
    const std::wstring value(text, wcsnlen(text, limit));
    ::GlobalUnlock(medium.hGlobal);
    if (!value.empty()) result = Utf8FromUtf16(value.c_str());
  }
  ::ReleaseStgMedium(&medium);
  return result;
}

// Reads every file path from a CF_HDROP payload.
std::vector<std::string> ReadPaths(IDataObject* data) {
  std::vector<std::string> paths;
  FORMATETC request = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1,
                       TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  if (data->GetData(&request, &medium) != S_OK) return paths;
  if (auto drop = static_cast<HDROP>(::GlobalLock(medium.hGlobal))) {
    const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; ++i) {
      const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length + 1, L'\0');
      ::DragQueryFileW(drop, i, path.data(), length + 1);
      path.resize(length);
      paths.push_back(Utf8FromUtf16(path.c_str()));
    }
    ::GlobalUnlock(medium.hGlobal);
  }
  ::ReleaseStgMedium(&medium);
  return paths;
}

}  // namespace

DropTarget::DropTarget(HWND view, PositionCallback on_position,
                       DropCallback on_drop)
    : view_(view),
      on_position_(std::move(on_position)),
      on_drop_(std::move(on_drop)) {}

bool DropTarget::Register() {
  if (registered_) return true;
  registered_ = SUCCEEDED(::RegisterDragDrop(view_, this));
  return registered_;
}

void DropTarget::Revoke() {
  if (!registered_) return;
  ::RevokeDragDrop(view_);
  registered_ = false;
}

HRESULT DropTarget::QueryInterface(REFIID riid, void** object) {
  if (!object) return E_POINTER;
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG DropTarget::AddRef() { return ::InterlockedIncrement(&references_); }

ULONG DropTarget::Release() {
  const ULONG remaining = ::InterlockedDecrement(&references_);
  if (remaining == 0) delete this;
  return remaining;
}

std::pair<double, double> DropTarget::ToLogical(POINTL point) const {
  POINT client = {point.x, point.y};
  ::ScreenToClient(view_, &client);
  // Flutter's devicePixelRatio is the window DPI over 96.
  const double scale = ::GetDpiForWindow(view_) / 96.0;
  return {client.x / scale, client.y / scale};
}

DWORD DropTarget::ChooseEffect(DWORD allowed) const {
  if (!has_data_) return DROPEFFECT_NONE;
  if (allowed & DROPEFFECT_COPY) return DROPEFFECT_COPY;
  if (allowed & DROPEFFECT_LINK) return DROPEFFECT_LINK;
  return DROPEFFECT_NONE;
}

HRESULT DropTarget::DragEnter(IDataObject* data, DWORD, POINTL point,
                              DWORD* effect) {
  has_data_ = Offers(data, CF_HDROP) ||
              Offers(data, static_cast<CLIPFORMAT>(UrlFormat())) ||
              Offers(data, CF_UNICODETEXT);
  *effect = ChooseEffect(*effect);
  if (has_data_) {
    last_position_ = ToLogical(point);
    if (on_position_) on_position_(last_position_);
  }
  return S_OK;
}

HRESULT DropTarget::DragOver(DWORD, POINTL point, DWORD* effect) {
  *effect = ChooseEffect(*effect);
  if (!has_data_) return S_OK;
  // DragOver repeats while the mouse rests; only report real movement.
  const auto position = ToLogical(point);
  if (position != last_position_) {
    last_position_ = position;
    if (on_position_) on_position_(position);
  }
  return S_OK;
}

HRESULT DropTarget::DragLeave() {
  if (has_data_ && on_position_) on_position_(std::nullopt);
  has_data_ = false;
  return S_OK;
}

HRESULT DropTarget::Drop(IDataObject* data, DWORD, POINTL point,
                         DWORD* effect) {
  *effect = ChooseEffect(*effect);
  if (!has_data_) return S_OK;
  has_data_ = false;
  DropData drop;
  drop.paths = ReadPaths(data);
  // A link is more useful than its title text, so prefer the URL format.
  drop.text = ReadText(data, static_cast<CLIPFORMAT>(UrlFormat()));
  if (!drop.text) drop.text = ReadText(data, CF_UNICODETEXT);
  const auto position = ToLogical(point);
  drop.x = position.first;
  drop.y = position.second;
  if (on_position_) on_position_(std::nullopt);
  if (on_drop_) on_drop_(drop);
  return S_OK;
}
