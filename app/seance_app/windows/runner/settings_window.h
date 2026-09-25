#ifndef RUNNER_SETTINGS_WINDOW_H_
#define RUNNER_SETTINGS_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class SettingsFlutterWindow;

// The Settings window: a second Win32 window on a second Flutter engine,
// whose Dart side runs the Settings screen instead of the app (see
// lib/services/settings_window.dart).
//
// Dart opens it, or brings it forward, with "open" on the app engine's
// "seance/settings_window" channel, and hears "closed" there when the user
// closes it. Closing hides it: the window and its engine are created once
// and kept until the app's window goes. Every message either engine sends on
// "seance/settings_link" is forwarded to the other engine, and its reply
// back: the two engines share nothing else, so this is how the window
// reaches the app's state.
//
// The settings window is owned by [main_window] in the Win32 sense: it stays
// above it, minimizes with it, and is destroyed with it, so closing the app's
// window still quits the app. Destroy this host before the engine behind
// [main_messenger].
class SettingsWindowHost {
 public:
  SettingsWindowHost(HWND main_window, flutter::BinaryMessenger* main_messenger);
  ~SettingsWindowHost();

  SettingsWindowHost(const SettingsWindowHost&) = delete;
  SettingsWindowHost& operator=(const SettingsWindowHost&) = delete;

 private:
  void Open();
  void OnWindowHidden();

  HWND main_window_;
  flutter::BinaryMessenger* main_messenger_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> control_;

  // The settings window, once opened: closing only hides it.
  std::unique_ptr<SettingsFlutterWindow> window_;
};

#endif  // RUNNER_SETTINGS_WINDOW_H_
