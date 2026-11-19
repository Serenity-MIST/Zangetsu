#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <ole2.h>
#include <windows.h>

#include <functional>
#include <optional>
#include <string>
#include <vector>

// OLE drop target for the Flutter view: accepts files (CF_HDROP) and text
// or links (UniformResourceLocatorW / CF_UNICODETEXT) dragged in from
// Explorer or a browser. Positions are logical pixels relative to the view
// so Dart can hit-test them against its own widgets.
class DropTarget : public IDropTarget {
 public:
  struct DropData {
    std::vector<std::string> paths;  // UTF-8
    std::optional<std::string> text;  // UTF-8
    double x = 0;
    double y = 0;
  };
  // |position| is called on enter/move (x, y) and with nullopt on leave.
  using PositionCallback =
      std::function<void(std::optional<std::pair<double, double>>)>;
  using DropCallback = std::function<void(const DropData&)>;

  DropTarget(HWND view, PositionCallback on_position, DropCallback on_drop);
  virtual ~DropTarget() = default;

  // Registers with OLE (needs OleInitialize on this thread); false on error.
  bool Register();
  // Unregisters; safe to call more than once.
  void Revoke();

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override;

 private:
  // Screen point -> logical view coordinates.
  std::pair<double, double> ToLogical(POINTL point) const;
  // Picks copy (or link) when the data has something we understand.
  DWORD ChooseEffect(DWORD allowed) const;

  LONG references_ = 1;
  HWND view_;
  PositionCallback on_position_;
  DropCallback on_drop_;
  bool registered_ = false;
  bool has_data_ = false;
  std::pair<double, double> last_position_ = {-1, -1};
};

#endif  // RUNNER_DROP_TARGET_H_
