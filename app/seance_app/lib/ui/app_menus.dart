import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import 'settings_screen.dart';

bool _settingsRouteOpen = false;

/// Open Settings as a route on the root navigator. Safe to call from menu
/// callbacks and shortcuts (needs no [BuildContext]); guards against stacking
/// duplicate Settings routes when triggered repeatedly.
void openSettings() {
  if (_settingsRouteOpen) return;
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  _settingsRouteOpen = true;
  nav
      .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
      .whenComplete(() => _settingsRouteOpen = false);
}

/// Wraps the app with the native macOS menu bar (Settings lives under the app
/// menu, ⌘,) plus a cross-platform ⌘/Ctrl+, shortcut for Linux/Windows. The
/// menu bar is a no-op on platforms without a system menu.
class AppMenus extends StatelessWidget {
  final Widget child;
  const AppMenus({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'Séance',
          menus: [
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.about),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Settings…',
                  shortcut: const SingleActivator(LogicalKeyboardKey.comma,
                      meta: true),
                  onSelected: openSettings,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.servicesSubmenu),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.hide),
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.hideOtherApplications),
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.showAllApplications),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.quit),
              ],
            ),
          ],
        ),
      ],
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.comma, meta: true):
              openSettings,
          const SingleActivator(LogicalKeyboardKey.comma, control: true):
              openSettings,
        },
        child: child,
      ),
    );
  }
}
