# macOS text-input crash investigation

The September 11, 2026 crash in Séance 0.8.0 was symbolicated with the exact
Flutter 3.47.3 arm64 symbols (framework UUID
`4C4C44D9-5555-3144-A1F3-3CDEB2C37911`). The relevant call chain was:

```text
FlutterTextInputPlugin.setEditingState: (FlutterTextInputPlugin.mm:559)
FlutterTextField.startEditing (FlutterTextInputSemanticsObject.mm:130)
ui::AXNodeData::GetStringAttribute (ax_node_data.cc:339)
```

The failing instruction read an invalid pointer in the accessibility node's
string-attribute storage. The native text-input bridge was restoring a field's
text and selection. The report does not identify the Dart widget or the exact
interaction that invalidated the data.

## Lifetime defect and mitigation

Flutter's `AccessibilityBridge` declares `id_wrapper_map_` before `tree_`.
C++ destroys these members in reverse order. Its destructor also removes its
tree observer, so destroying the tree does not invalidate the platform
delegates. Consequently the tree is gone when the wrappers start detaching
their native `FlutterTextField` views. Detachment enters AppKit, where input
and accessibility callbacks can still reach another field whose delegate
points into the destroyed tree.

`SeanceFlutterViewController` invalidates all exposed native text fields
before disabling semantics or destroying the controller. It uses Flutter's
existing `setPlatformNode:` invalidation method, without accessing C++ object
layouts. Collection reads the view hierarchy only, before any field detaches.
Accessibility remains enabled whenever macOS requests it, and normal text
input and IME handling still use Flutter's implementation.

The override depends on Flutter's private Objective-C lifecycle selectors.
The native regression test exercises that boundary against the bundled
engine. Reassess this workaround when upgrading Flutter; remove it once the
engine invalidates its native proxies before destroying their backing tree.

## Verification and limits

Run `scripts/test-macos-accessibility.sh` after building the macOS app, or set
`FLUTTER_ROOT` to a Flutter SDK with its macOS release artifacts cached. The
test uses real Flutter native accessibility objects in an isolated process.
It does not launch Séance's Dart application or access its saved data.
The resulting "Invalid engine handle" messages come from notifying the
intentionally unstarted Dart engine; the native bridge still runs normally.

The regression checks that no exposed text field retains its platform node
when the first field detaches. Stock Flutter 3.47.3 fails this check. It
avoids reading freed node data to produce a reliable assertion instead of a
timing-dependent segmentation fault.

`scripts/test-macos-accessibility.sh --stock-engine` runs the same assertions
without the guard and is expected to fail on Flutter 3.47.3. The guarded test
also keeps a text-input connection active through the accessibility-disable
notification, verifies editor reparenting and subsequent text and selection
updates, and reuses the connection with fresh fields after re-enabling
semantics. Both semantics teardown and controller destruction must reach the
removal observer for every field, so ordering cannot pass without observation.

This demonstrates the teardown lifetime defect and the guard's ordering. It
does **not** reproduce the original user's complete interaction or establish
that teardown was the only cause of that incident. The original stack does
not contain an outer teardown frame. Other in-flight AppKit callbacks that
invalidate a node during `startEditing` are outside this guard's scope.
If the crash recurs, retain the new report and the immediately preceding
focus, dialog, and accessibility interactions for further reproduction.
