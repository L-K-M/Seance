#ifndef RUNNER_SETTINGS_WINDOW_H_
#define RUNNER_SETTINGS_WINDOW_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The Settings window: a second GTK window on a second Flutter engine, whose
// Dart side runs the Settings screen instead of the app (see
// lib/services/settings_window.dart).
//
// Dart opens it, or brings it forward, with "open" on the app engine's
// "seance/settings_window" channel, and hears "closed" there when the user
// closes it. Closing hides it: the window and its engine are created once
// and kept until the app quits (settings_window.cc says why). Every message
// either engine sends on "seance/settings_link" is forwarded to the other
// engine, and its reply back: the two engines share nothing else, so this is
// how the window reaches the app's state.
//
// Owned by [main_window], which the settings window stays above and is
// destroyed with, so closing the app's window still quits the app.
void settings_window_install(GtkApplication* application,
                             GtkWindow* main_window,
                             FlView* main_view);

#endif  // RUNNER_SETTINGS_WINDOW_H_
