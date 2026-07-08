import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/middle_ellipsis_text.dart';

Widget _host(double width, String text) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: MiddleEllipsisText(text)),
        ),
      ),
    );

String _shown(WidgetTester tester) => tester
    .widget<Text>(find.descendant(
        of: find.byType(MiddleEllipsisText), matching: find.byType(Text)))
    .data!;

void main() {
  testWidgets('shows the full name when it fits', (tester) async {
    await tester.pumpWidget(_host(1000, 'short-name'));
    expect(_shown(tester), 'short-name');
  });

  testWidgets('truncates in the middle, keeping both ends', (tester) async {
    const long = 'prod-web-server-01.eu-west-1.example.internal';
    await tester.pumpWidget(_host(90, long));
    final shown = _shown(tester);
    expect(shown, contains('…'));
    expect(shown.length, lessThan(long.length));
    final head = shown.split('…').first;
    final tail = shown.split('…').last;
    expect(long.startsWith(head), isTrue);
    expect(long.endsWith(tail), isTrue);
    // A middle ellipsis preserves the distinguishing tail, unlike end-ellipsis.
    expect(tail.isNotEmpty, isTrue);
  });
}
