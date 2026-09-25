#include "settings_window.h"

#include <cstring>

#include "window_title.h"

namespace {

constexpr char kControlChannel[] = "seance/settings_window";
constexpr char kLinkChannel[] = "seance/settings_link";

// What the settings engine's Dart entrypoint looks for to run the Settings
// screen instead of the app (settingsWindowArgument in Dart).
constexpr char kWindowArgument[] = "--seance-settings-window";

constexpr char kWindowTitle[] = "Séance Settings";
constexpr int kDefaultWidth = 760;
constexpr int kDefaultHeight = 640;
constexpr int kMinimumWidth = 520;
constexpr int kMinimumHeight = 420;

struct SettingsWindowHost {
  GtkApplication* application;  // Not owned.
  GtkWindow* main_window;       // Not owned; owns this host.
  FlBinaryMessenger* main_messenger;
  FlMethodChannel* control;

  // The open settings window and its engine's messenger, or null.
  GtkWindow* window;
  FlBinaryMessenger* window_messenger;
};

// A message in flight from one engine to the other: where its reply goes.
struct PendingReply {
  FlBinaryMessenger* origin;
  FlBinaryMessengerResponseHandle* handle;
};

void reply_ready(GObject* source, GAsyncResult* result, gpointer user_data) {
  PendingReply* pending = static_cast<PendingReply*>(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GBytes) reply = fl_binary_messenger_send_on_channel_finish(
      FL_BINARY_MESSENGER(source), result, &error);
  // A destination that failed or went away answers nothing, which the sender
  // reads as "no handler" — the same as a window that was never opened.
  fl_binary_messenger_send_response(pending->origin, pending->handle, reply,
                                    nullptr);
  g_object_unref(pending->origin);
  g_object_unref(pending->handle);
  g_free(pending);
}

void forward(FlBinaryMessenger* origin, FlBinaryMessenger* destination,
             GBytes* message, FlBinaryMessengerResponseHandle* handle) {
  if (destination == nullptr) {
    fl_binary_messenger_send_response(origin, handle, nullptr, nullptr);
    return;
  }
  PendingReply* pending = g_new(PendingReply, 1);
  pending->origin = FL_BINARY_MESSENGER(g_object_ref(origin));
  pending->handle = FL_BINARY_MESSENGER_RESPONSE_HANDLE(g_object_ref(handle));
  fl_binary_messenger_send_on_channel(destination, kLinkChannel, message,
                                      nullptr, reply_ready, pending);
}

void main_link_cb(FlBinaryMessenger* messenger, const gchar* channel,
                  GBytes* message, FlBinaryMessengerResponseHandle* handle,
                  gpointer user_data) {
  auto* host = static_cast<SettingsWindowHost*>(user_data);
  forward(messenger, host->window_messenger, message, handle);
}

void window_link_cb(FlBinaryMessenger* messenger, const gchar* channel,
                    GBytes* message, FlBinaryMessengerResponseHandle* handle,
                    gpointer user_data) {
  auto* host = static_cast<SettingsWindowHost*>(user_data);
  forward(messenger, host->main_messenger, message, handle);
}

// Closing hides the window rather than destroying it, and only this window.
//
// Hidden, because destroying it disposes its engine, and Flutter's Linux
// embedder terminates the EGL display — which every engine in the process
// shares — when an engine is disposed: the app's window then dies with an X
// error (BadAccess from GLX). Kept, it also reopens at once; the Dart side
// drops its screen while hidden.
//
// Only this window, because the view hooks its window's delete-event too, to
// ask Dart whether the whole application should quit — right for the app's
// window, and for this one it quit the app. Connected before the view
// exists, this handler runs first and stops the event.
gboolean window_delete_cb(GtkWidget* widget, GdkEvent* event,
                          gpointer user_data) {
  auto* host = static_cast<SettingsWindowHost*>(user_data);
  gtk_widget_hide(widget);
  fl_method_channel_invoke_method(host->control, "closed", nullptr, nullptr,
                                  nullptr, nullptr);
  return TRUE;
}

// Destroyed only with the app's window, as the app quits.
void window_destroyed_cb(GtkWidget* widget, gpointer user_data) {
  auto* host = static_cast<SettingsWindowHost*>(user_data);
  host->window = nullptr;
  g_clear_object(&host->window_messenger);
}

// Shown on its first frame, like the main window, so it never flashes the
// view's background before Flutter has drawn.
void first_frame_cb(FlView* view, gpointer user_data) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

void open_window(SettingsWindowHost* host) {
  if (host->window != nullptr) {
    // Shows it again if it was closed, and raises it either way.
    gtk_window_present(host->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(host->application));
  window_title_apply(window, kWindowTitle);
  gtk_window_set_default_size(window, kDefaultWidth, kDefaultHeight);
  gtk_window_set_transient_for(window, host->main_window);
  gtk_window_set_destroy_with_parent(window, TRUE);
  gtk_window_set_position(window, GTK_WIN_POS_CENTER_ON_PARENT);
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb), host);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  char* arguments[] = {const_cast<char*>(kWindowArgument), nullptr};
  fl_dart_project_set_dart_entrypoint_arguments(project, arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_set_size_request(GTK_WIDGET(view), kMinimumWidth, kMinimumHeight);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  host->window = window;
  host->window_messenger = FL_BINARY_MESSENGER(
      g_object_ref(fl_engine_get_binary_messenger(fl_view_get_engine(view))));
  // Before the engine starts: the window's Dart side says hello first thing.
  fl_binary_messenger_set_message_handler_on_channel(
      host->window_messenger, kLinkChannel, window_link_cb, host, nullptr);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed_cb), host);

  g_signal_connect(view, "first-frame", G_CALLBACK(first_frame_cb), nullptr);
  gtk_widget_realize(GTK_WIDGET(view));
  // No plugins: everything the Settings screen does runs in the app's engine,
  // reached over the link.
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

void control_cb(FlMethodChannel* channel, FlMethodCall* call,
                gpointer user_data) {
  auto* host = static_cast<SettingsWindowHost*>(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(fl_method_call_get_name(call), "open") == 0) {
    open_window(host);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

void host_free(gpointer data) {
  auto* host = static_cast<SettingsWindowHost*>(data);
  if (host->window != nullptr) {
    g_signal_handlers_disconnect_by_data(host->window, host);
    gtk_widget_destroy(GTK_WIDGET(host->window));
  }
  g_clear_object(&host->window_messenger);
  g_clear_object(&host->control);
  // The link's handler on the app's messenger went with its engine: the view
  // is disposed before the window that owns this host.
  g_clear_object(&host->main_messenger);
  g_free(host);
}

}  // namespace

void settings_window_install(GtkApplication* application,
                             GtkWindow* main_window,
                             FlView* main_view) {
  auto* host = g_new0(SettingsWindowHost, 1);
  host->application = application;
  host->main_window = main_window;
  host->main_messenger = FL_BINARY_MESSENGER(g_object_ref(
      fl_engine_get_binary_messenger(fl_view_get_engine(main_view))));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  host->control = fl_method_channel_new(host->main_messenger, kControlChannel,
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(host->control, control_cb, host,
                                            nullptr);
  fl_binary_messenger_set_message_handler_on_channel(
      host->main_messenger, kLinkChannel, main_link_cb, host, nullptr);

  g_object_set_data_full(G_OBJECT(main_window), "seance-settings-window",
                         host, host_free);
}
