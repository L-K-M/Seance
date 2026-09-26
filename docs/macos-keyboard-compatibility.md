# Injected Command shortcuts on macOS

Some automation tools inject key events with the aggregate Command flag
(`0x100000`) but neither device-side Command bit. Easydict's synthetic
Command+C exposed this in the sibling Poltergeist app: Flutter interpreted
the event as plain C. Quitting Easydict stopped that reproduction.

Flutter's native keyboard responder synchronizes modifier keys from the
left/right device bits. `SeanceFlutterViewController` now supplies the left
Command bit when the aggregate flag is present and both side bits are absent.
The same normalization runs before forwarding `keyDown:` and `keyUp:` to
Flutter. A subsequent event without Command releases the synthesized state.

Events that already specify either Command side, and events without Command,
retain their original object identity. This matters because Flutter uses
identity to recognize redispatched keyboard events. A normalized event keeps
its key code, text, text without modifiers, timestamp, location, window number,
repeat flag and unrelated modifiers. It also retains Flutter's runtime
key-equivalent marker so unhandled shortcuts can continue through native menu
dispatch. The normalization does not change the source event.

## Regression and limits

After `flutter build macos`, run:

```sh
scripts/test-macos-keyboard.sh
```

Alternatively, set `FLUTTER_ROOT` to an SDK with its macOS release engine
cached. The fixture compiles the production controller and uses the real
Flutter keyboard manager and both native keyboard responders. Only outbound
framework replies are supplied by the fixture. It starts no Dart application
or window and posts no input to the system.

Six scenario groups cover aggregate-only Command+C; physical left, right and
both Command keys; metadata, repeats, marker preservation and idempotence;
Shift release around an injected shortcut; unrelated modifier flags; and
controller replacement plus Command+V. Pressed-key state is checked after
key-down, repeat and key-up events. The same fixture with
`scripts/test-macos-keyboard.sh --stock-engine` fails its first assertion that
Command+C reaches Flutter with Meta pressed, proving it catches the original
engine behavior. CI and release builds run the passing application variant.

The fixture checks the native delivery boundary. It does not automate Easydict
or exercise every Dart shortcut, native menu, keyboard layout or input method.
The user-facing Easydict reproduction was in Poltergeist; Séance is covered
by the same native-engine regression and uses this controller in both main and
Settings windows. Rerun these tests when updating Flutter because the
key-equivalent selectors are runtime compatibility hooks.

## Sibling maintenance

The normalization and `scripts/test-macos-keyboard.{sh,mm}` are mirrored from
[Poltergeist's keyboard compatibility fix](https://github.com/L-K-M/Poltergeist/pull/220)
and its `PoltergeistFlutterViewController`. Keep the behavior and fixture
in step across the two repositories, adjusting only app names and surrounding
accessibility lifecycle code. The earlier accessibility guard remains covered
independently by `scripts/test-macos-accessibility.sh`.
