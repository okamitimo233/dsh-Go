// Desktop composition budget for the chat screen. The visual tier stays on
// (blur and fluid motion are product defaults); this test only stops a future
// change from multiplying blur filters or custom paint work per visible page.

import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/common/ui_trace.dart' show uiTraceNoBlur;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';

const _blurBudget = 8;
const _groupBudget = 3;
const _glassBudget = 10;
const _clipBudget = 20;
const _painterBudget = 45;

typedef _Composition = ({int blur, int groups, int glass, int clips, int painters, int rowLayers});

Future<void> _pump(WidgetTester tester, ChatHarness harness) async {
  // A desktop-sized window, not the phone view most chat tests use.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.padding = const FakeViewPadding();
  tester.view.viewPadding = const FakeViewPadding();
  addTearDown(tester.view.reset);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 10);
}

_Composition _measure(WidgetTester tester) {
  final rowLayers = find
      .descendant(
        of: find.byType(ChatList),
        matching: find.byWidgetPredicate(
          (widget) => widget is KeyedSubtree && widget.key is ValueKey<String> && widget.child is RepaintBoundary,
        ),
      )
      .evaluate()
      .length;
  return (
    blur: find.byType(BackdropFilter).evaluate().length,
    groups: find.byType(BackdropGroup).evaluate().length,
    glass: find.byType(GlassSurface).evaluate().length,
    clips:
        find.byType(ClipRRect).evaluate().length +
        find.byType(ClipOval).evaluate().length +
        find.byType(ClipRect).evaluate().length +
        find.byType(ClipRSuperellipse).evaluate().length,
    painters: find.byType(CustomPaint).evaluate().length,
    rowLayers: rowLayers,
  );
}

void _expectWithinBudget(_Composition c) {
  expect(c.blur, lessThanOrEqualTo(_blurBudget), reason: 'BackdropFilter count');
  expect(c.groups, lessThanOrEqualTo(_groupBudget), reason: 'BackdropGroup count');
  expect(c.glass, lessThanOrEqualTo(_glassBudget), reason: 'GlassSurface count');
  expect(c.clips, lessThanOrEqualTo(_clipBudget), reason: 'clip count');
  expect(c.painters, lessThanOrEqualTo(_painterBudget), reason: 'CustomPaint count');
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a populated desktop conversation stays within its composition budget', (tester) async {
    await _pump(tester, ChatHarness(session: 's1', states: {'s1': conversationState()}));
    expect(tester.takeException(), isNull);

    final composition = _measure(tester);
    expect(composition.rowLayers, greaterThan(0), reason: 'every visible chat row owns a repaint layer');
    _expectWithinBudget(composition);
    if (uiTraceNoBlur) expect(composition.blur, 0, reason: 'the A/B build must take the opaque fallback');
  });

  testWidgets('a streaming conversation does not exceed the same composition budget', (tester) async {
    await _pump(tester, ChatHarness(session: 's1', states: {'s1': streamingState()}));
    expect(tester.takeException(), isNull);

    final composition = _measure(tester);
    expect(composition.rowLayers, greaterThan(0));
    _expectWithinBudget(composition);
    if (uiTraceNoBlur) expect(composition.blur, 0);
  });
}
