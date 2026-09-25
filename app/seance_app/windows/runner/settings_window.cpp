#include "settings_window.h"

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <functional>
#include <optional>
#include <string>
#include <utility>

#include "win32_window.h"

namespace {

constexpr char kControlChannel[] = "seance/settings_window";
constexpr char kLinkChannel[] = "seance/settings_link";

// What the settings engine's Dart entrypoint looks for to run the Settings
// screen instead of the app (settingsWindowArgument in Dart).
constexpr char kWindowArgument[] = "--seance-settings-window";

// Spelled with an escape so the source stays ASCII for MSVC, like main.cpp.
constexpr wchar_t kWindowTitle[] = L"S\u00e9ance Settings";
constexpr unsigned int kDefaultWidth = 760;
constexpr unsigned int kDefaultHeight = 640;

// Forwards a message one engine sent on the link to the other, and the
// reply back. No destination, no answer: the sender reads an empty reply as
// "no handler", the same as a window that was never opened.
void Forward(flutter::BinaryMessenger* destination, const uint8_t* message,
             size_t message_size, flutter::BinaryReply reply) {
  if (destination == nullptr) {
    reply(nullptr, 0);
    return;
  }
  destination->Send(kLinkChannel, message, message_size, std::move(reply));
}

}  // namespace

// A window hosting the settings engine: the runner's FlutterWindow without
// the plugins (everything the Settings screen does runs in the app's engine,
// reached over the link) and with the link's settings end.
class SettingsFlutterWindow : public Win32Window {
 public:
  SettingsFlutterWindow(flutter::BinaryMessenger* main_messenger,
                        std::function<void()> on_hidden)
      : project_(L"data"),
        main_messenger_(main_messenger),
        on_hidden_(std::move(on_hidden)) {
    project_.set_dart_entrypoint_arguments({kWindowArgument});
  }

  // The settings engine's messenger, or null once the window is destroyed.
  flutter::BinaryMessenger* messenger() const {
    return controller_ ? controller_->engine()->messenger() : nullptr;
  }

 protected:
  bool OnCreate() override {
    if (!Win32Window::OnCreate()) {
      return false;
    }
    RECT frame = GetClientArea();
    controller_ = std::make_unique<flutter::FlutterViewController>(
        frame.right - frame.left, frame.bottom - frame.top, project_);
    if (!controller_->engine() || !controller_->view()) {
      return false;
    }
    // Before the message loop runs again: that is when the window's Dart
    // side is heard, and its first act is to say hello over the link.
    flutter::BinaryMessenger* main = main_messenger_;
    controller_->engine()->messenger()->SetMessageHandler(
        kLinkChannel, [main](const uint8_t* message, size_t message_size,
                             flutter::BinaryReply reply) {
          Forward(main, message, message_size, std::move(reply));
        });
    SetChildContent(controller_->view()->GetNativeWindow());
    // Shown on its first frame, like the app's window, so it never flashes
    // an empty frame before Flutter has drawn.
    controller_->engine()->SetNextFrameCallback([this]() { Show(); });
    controller_->ForceRedraw();
    return true;
  }

  void OnDestroy() override {
    controller_ = nullptr;
    Win32Window::OnDestroy();
  }

  LRESULT MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override {
    // Closing hides the window instead of destroying it, before Flutter sees
    // the message: the window and its engine are kept until the app's
    // window goes, as on the other desktops, where tearing a second engine
    // down is not safe (lib/services/settings_window.dart). It also reopens
    // at once; the Dart side drops its screen while hidden.
    if (message == WM_CLOSE) {
      ShowWindow(hwnd, SW_HIDE);
      on_hidden_();
      return 0;
    }
    if (controller_) {
      std::optional<LRESULT> result =
          controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
      if (result) {
        return *result;
      }
    }
    if (message == WM_FONTCHANGE && controller_) {
      controller_->engine()->ReloadSystemFonts();
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

 private:
  flutter::DartProject project_;
  flutter::BinaryMessenger* main_messenger_;
  std::function<void()> on_hidden_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
};

SettingsWindowHost::SettingsWindowHost(HWND main_window,
                                       flutter::BinaryMessenger* main_messenger)
    : main_window_(main_window), main_messenger_(main_messenger) {
  control_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      main_messenger_, kControlChannel,
      &flutter::StandardMethodCodec::GetInstance());
  control_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "open") {
          result->NotImplemented();
          return;
        }
        Open();
        result->Success();
      });
  main_messenger_->SetMessageHandler(
      kLinkChannel, [this](const uint8_t* message, size_t message_size,
                           flutter::BinaryReply reply) {
        Forward(window_ ? window_->messenger() : nullptr, message,
                message_size, std::move(reply));
      });
}

SettingsWindowHost::~SettingsWindowHost() {
  main_messenger_->SetMessageHandler(kLinkChannel, nullptr);
  control_->SetMethodCallHandler(nullptr);
  // Destroyed here if still open, before the engines it relays between, and
  // through DestroyWindow so its own OnDestroy runs: from its destructor only
  // the base class's would.
  if (window_ && window_->GetHandle() != nullptr) {
    DestroyWindow(window_->GetHandle());
  }
  window_ = nullptr;
}

void SettingsWindowHost::Open() {
  if (window_ && window_->GetHandle() != nullptr) {
    // Shows it again if it was closed, and brings it forward either way.
    HWND handle = window_->GetHandle();
    ShowWindow(handle, IsIconic(handle) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(handle);
    return;
  }

  window_ = std::make_unique<SettingsFlutterWindow>(
      main_messenger_, [this]() { OnWindowHidden(); });
  // Near the app's window, on its monitor: Create takes the origin in
  // logical pixels and picks the monitor from it.
  RECT main_frame;
  GetWindowRect(main_window_, &main_frame);
  HMONITOR monitor = MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST);
  double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  LONG x = (main_frame.left + main_frame.right) / 2 -
           static_cast<LONG>(kDefaultWidth * scale / 2);
  LONG y = (main_frame.top + main_frame.bottom) / 2 -
           static_cast<LONG>(kDefaultHeight * scale / 2);
  Win32Window::Point origin(static_cast<unsigned int>((x > 0 ? x : 0) / scale),
                            static_cast<unsigned int>((y > 0 ? y : 0) / scale));
  if (!window_->Create(kWindowTitle, origin,
                       Win32Window::Size(kDefaultWidth, kDefaultHeight))) {
    window_ = nullptr;
    return;
  }
  // The owner: the settings window stays above the app's window and is
  // destroyed with it. Set after creation, the documented way to give an
  // overlapped window an owner.
  SetWindowLongPtr(window_->GetHandle(), GWLP_HWNDPARENT,
                   reinterpret_cast<LONG_PTR>(main_window_));
}

void SettingsWindowHost::OnWindowHidden() {
  control_->InvokeMethod("closed", nullptr);
}
