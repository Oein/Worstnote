// Verifies the pen-only-drawing gate accepts the right pointer kinds.

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notee/features/canvas/engine/input_gate.dart';

PointerDownEvent _down(PointerDeviceKind kind) =>
    PointerDownEvent(position: Offset.zero, kind: kind);

void main() {
  group('InputMode.any', () {
    const gate = InputGate(InputMode.any);
    test('accepts touch', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.touch)), isTrue);
    });
    test('accepts mouse', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.mouse)), isTrue);
    });
    test('accepts stylus', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.stylus)), isTrue);
    });
  });

  group('InputMode.stylusOnly', () {
    const gate = InputGate(InputMode.stylusOnly);
    test('rejects touch (finger)', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.touch)), isFalse);
    });
    test('rejects mouse', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.mouse)), isFalse);
    });
    // Trackpad pointer events use PointerPanZoom*Event, not PointerDownEvent;
    // Flutter asserts kind != trackpad on PointerDownEvent, so we don't need
    // a unit test for that path — the gate's `default → stylus check` covers it.
    test('accepts stylus', () {
      expect(gate.acceptsForDrawing(_down(PointerDeviceKind.stylus)), isTrue);
    });
    test('accepts inverted stylus (eraser end of Apple Pencil)', () {
      expect(
          gate.acceptsForDrawing(_down(PointerDeviceKind.invertedStylus)),
          isTrue);
    });
  });
}
