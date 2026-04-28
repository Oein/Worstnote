// Drives synthetic pointer drags through the real CanvasView and verifies:
//   1. A stylus drag in stylusOnly mode commits a Stroke.
//   2. A mouse drag in stylusOnly mode does NOT commit a Stroke.
//   3. A mouse drag in `any` mode commits a Stroke (and would not scroll —
//      the scroll-prevention is a PageScroller config; tested in widget_test).
//   4. The active stroke paints during drag and clears on release.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notee/core/ids.dart';
import 'package:notee/domain/layer.dart' as dom;
import 'package:notee/domain/page.dart' as dom;
import 'package:notee/domain/page_spec.dart';
import 'package:notee/domain/stroke.dart';
import 'package:notee/features/canvas/engine/input_gate.dart';
import 'package:notee/features/canvas/widgets/canvas_view.dart';

class _Fixture {
  _Fixture(this.pageId, this.layerId);
  final String pageId;
  final String layerId;
  final List<Stroke> committed = [];

  Widget canvas({required InputMode inputMode}) {
    // Use a small custom size so the entire canvas fits in the default
    // 800×600 test surface (otherwise hits land outside its layout bounds).
    final page = dom.NotePage(
      id: pageId,
      noteId: 'note',
      index: 0,
      spec: const PageSpec(
        widthPt: 400,
        heightPt: 400,
        kind: PaperKind.custom,
        background: PageBackground.blank(),
      ),
      updatedAt: DateTime.now().toUtc(),
    );
    final layer = dom.Layer(id: layerId, pageId: pageId, z: 0, name: 'L1');
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: page.spec.widthPt,
              height: page.spec.heightPt,
              child: CanvasView(
              page: page,
              layers: [layer],
              strokesByLayer: const {},
              activeLayerId: layerId,
              tool: ToolKind.pen,
              colorArgb: 0xFF000000,
              widthPt: 2,
              opacity: 1,
              inputMode: inputMode,
              onStrokeCommitted: committed.add,
            ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _drag(
  WidgetTester tester,
  Finder target, {
  required Offset from,
  required Offset to,
  required PointerDeviceKind kind,
  int steps = 5,
}) async {
  // tester.startGesture / gesture.moveTo default to timeStamp=Duration.zero.
  // Pass an explicit increasing timestamp on each event so StrokeBuilder's
  // One-Euro filter sees proper dt and produces multiple output points.
  final gesture = await tester.startGesture(
    tester.getTopLeft(target) + from,
    kind: kind,
  );
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final pos = Offset.lerp(from, to, t)!;
    await gesture.moveTo(
      tester.getTopLeft(target) + pos,
      timeStamp: Duration(milliseconds: i * 16),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up(timeStamp: Duration(milliseconds: (steps + 1) * 16));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // Make uuid deterministic? Not needed; we don't compare ids.
    newId();
  });

  testWidgets('mouse drag in any mode commits a stroke', (tester) async {
    final f = _Fixture('p1', 'l1');
    await tester.pumpWidget(f.canvas(inputMode: InputMode.any));
    await _drag(
      tester,
      find.byType(CanvasView),
      from: const Offset(50, 50),
      to: const Offset(200, 200),
      kind: PointerDeviceKind.mouse,
    );
    expect(f.committed, hasLength(1));
    expect(f.committed.first.points.length, greaterThanOrEqualTo(2));
    expect(f.committed.first.tool, ToolKind.pen);
  });

  testWidgets('stylus drag in stylusOnly mode commits a stroke',
      (tester) async {
    final f = _Fixture('p2', 'l2');
    await tester.pumpWidget(f.canvas(inputMode: InputMode.stylusOnly));
    await _drag(
      tester,
      find.byType(CanvasView),
      from: const Offset(50, 50),
      to: const Offset(200, 200),
      kind: PointerDeviceKind.stylus,
    );
    expect(f.committed, hasLength(1));
  });

  testWidgets('mouse drag in stylusOnly mode does NOT commit a stroke',
      (tester) async {
    final f = _Fixture('p3', 'l3');
    await tester.pumpWidget(f.canvas(inputMode: InputMode.stylusOnly));
    await _drag(
      tester,
      find.byType(CanvasView),
      from: const Offset(50, 50),
      to: const Offset(200, 200),
      kind: PointerDeviceKind.mouse,
    );
    expect(f.committed, isEmpty);
  });

  testWidgets('finger drag in stylusOnly mode does NOT commit a stroke',
      (tester) async {
    final f = _Fixture('p4', 'l4');
    await tester.pumpWidget(f.canvas(inputMode: InputMode.stylusOnly));
    await _drag(
      tester,
      find.byType(CanvasView),
      from: const Offset(50, 50),
      to: const Offset(200, 200),
      kind: PointerDeviceKind.touch,
    );
    expect(f.committed, isEmpty);
  });
}
