// ToolbarShell hosts the floating / dockable toolbar around a canvas.
//
// MVP scope (P6): four-edge dock + free-floating, draggable, with a presets
// row (color/thickness slots). For P0 this is a structural skeleton — the
// actual prefs persistence and drag-snap UX come later.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ToolbarDock { top, right, bottom, left, floating }

/// Persists the user's preferred toolbar dock position. Lives here so any
/// toolbar widget can read the dock without depending on main.dart.
final toolbarDockProvider =
    StateProvider<ToolbarDock>((ref) => ToolbarDock.top);

class ToolbarController extends ChangeNotifier {
  ToolbarController({
    this.dock = ToolbarDock.left,
    this.floatingOffset = const Offset(24, 24),
  });

  ToolbarDock dock;
  Offset floatingOffset;

  void setDock(ToolbarDock d) {
    if (dock != d) {
      dock = d;
      notifyListeners();
    }
  }

  void setFloatingOffset(Offset o) {
    floatingOffset = o;
    notifyListeners();
  }
}

class ToolbarShell extends StatelessWidget {
  const ToolbarShell({
    super.key,
    required this.controller,
    required this.toolbar,
    required this.child,
  });

  final ToolbarController controller;
  final Widget toolbar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: _padding(),
                child: child,
              ),
            ),
            _placeToolbar(context),
          ],
        );
      },
    );
  }

  static const double _dockHorizontalHeight = 96;
  static const double _dockVerticalWidth = 240;

  EdgeInsets _padding() {
    switch (controller.dock) {
      case ToolbarDock.top:
        return const EdgeInsets.only(top: _dockHorizontalHeight);
      case ToolbarDock.bottom:
        return const EdgeInsets.only(bottom: _dockHorizontalHeight);
      case ToolbarDock.left:
        return const EdgeInsets.only(left: _dockVerticalWidth);
      case ToolbarDock.right:
        return const EdgeInsets.only(right: _dockVerticalWidth);
      case ToolbarDock.floating:
        return EdgeInsets.zero;
    }
  }

  Widget _placeToolbar(BuildContext context) {
    final dock = controller.dock;
    if (dock == ToolbarDock.floating) {
      return Positioned(
        left: controller.floatingOffset.dx,
        top: controller.floatingOffset.dy,
        child: Draggable(
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.85, child: toolbar),
          ),
          childWhenDragging: const SizedBox.shrink(),
          onDragEnd: (d) {
            controller.setFloatingOffset(d.offset);
          },
          child: toolbar,
        ),
      );
    }
    final isHorizontal =
        dock == ToolbarDock.top || dock == ToolbarDock.bottom;

    final positioned = isHorizontal
        ? Positioned(
            top: dock == ToolbarDock.top ? 0 : null,
            bottom: dock == ToolbarDock.bottom ? 0 : null,
            left: 0,
            right: 0,
            child: SizedBox(height: _dockHorizontalHeight, child: toolbar),
          )
        : Positioned(
            left: dock == ToolbarDock.left ? 0 : null,
            right: dock == ToolbarDock.right ? 0 : null,
            top: 0,
            bottom: 0,
            child: SizedBox(width: _dockVerticalWidth, child: toolbar),
          );
    return positioned;
  }
}
