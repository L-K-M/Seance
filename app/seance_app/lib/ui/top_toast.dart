import 'package:flutter/material.dart';

/// Show a transient toast anchored to the TOP of the window. Used instead of a
/// SnackBar for "inserted into the prompt" notices: those insert text at the
/// terminal prompt (bottom of the screen), and a bottom SnackBar would sit
/// right on top of it. Tap to dismiss; auto-dismisses after [duration].
///
/// Pass the root [OverlayState] (capture it with `Overlay.of(context,
/// rootOverlay: true)` before closing any dialog) so the toast outlives the
/// widget that triggered it.
void showTopToast(
  OverlayState overlay, {
  required String message,
  Color? background,
  Duration duration = const Duration(seconds: 4),
}) {
  var removed = false;
  late OverlayEntry entry;
  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) => _TopToast(
      message: message,
      background: background,
      onDismiss: remove,
    ),
  );
  overlay.insert(entry);
  Future.delayed(duration, remove);
}

class _TopToast extends StatefulWidget {
  final String message;
  final Color? background;
  final VoidCallback onDismiss;
  const _TopToast(
      {required this.message, this.background, required this.onDismiss});

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = widget.background ?? scheme.inverseSurface;
    final fg =
        widget.background != null ? Colors.white : scheme.onInverseSurface;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // Only the card itself intercepts taps; the surrounding strip is
      // transparent, so the terminal below stays interactive.
      child: SafeArea(
        bottom: false,
        child: FadeTransition(
          opacity: _anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, -0.25), end: Offset.zero)
                .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Material(
                  color: bg,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: widget.onDismiss,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Text(widget.message, style: TextStyle(color: fg)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
