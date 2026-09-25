import 'package:flutter/material.dart';

/// One Settings tab's page: a centred, width-capped scrolling column.
///
/// Shared by the tabs the screen builds itself and the ones in files of
/// their own (Appearance), so every tab lines up the same.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.storageKey,
    required this.children,
  });

  /// Keys the list's scroll position, so a tab switched away from and back
  /// to is where it was.
  final PageStorageKey<String> storageKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: FocusTraversalGroup(
        child: ListView(
          key: storageKey,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: children,
        ),
      ),
    ),
  );
}

/// A section's title, with a help button when there is more to say than
/// fits beside the controls.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.title, {
    super.key,
    this.helpTitle,
    this.help,
  });

  final String title;
  final String? helpTitle;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final help = this.help;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (help != null)
            IconButton(
              tooltip: 'About $title',
              icon: const Icon(Icons.help_outline, size: 20),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(helpTitle ?? title),
                  content: SingleChildScrollView(child: Text(help)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
