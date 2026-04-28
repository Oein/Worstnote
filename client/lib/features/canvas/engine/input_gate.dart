// Decides whether a given PointerEvent should be treated as a drawing input.
//
// Used to implement "pen-only drawing" (a.k.a. palm rejection / Apple Pencil
// only / S-Pen only). When [InputMode.stylusOnly] is active, finger touches
// and mouse drags fall through to the underlying scroll/select widgets
// instead of producing strokes.

import 'package:flutter/gestures.dart';

enum InputMode {
  /// Anything that can carry a pointer (stylus, finger, mouse, trackpad)
  /// can draw. Default for desktop mouse-driven workflows.
  any,

  /// Only stylus input draws. Finger and mouse are ignored by the canvas
  /// (the gesture is not consumed, so they remain usable for scroll/zoom).
  stylusOnly,
}

class InputGate {
  const InputGate(this.mode);
  final InputMode mode;

  /// Returns true if [event] should be treated as a drawing event.
  bool acceptsForDrawing(PointerEvent event) {
    switch (mode) {
      case InputMode.any:
        return true;
      case InputMode.stylusOnly:
        // Stylus is unambiguous; "invertedStylus" (the eraser end of an
        // Apple Pencil) is also a stylus and should still draw (the canvas
        // can map it to the eraser tool elsewhere).
        return event.kind == PointerDeviceKind.stylus ||
            event.kind == PointerDeviceKind.invertedStylus;
    }
  }
}
