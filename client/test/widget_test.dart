// Smoke tests for the boot path. The home screen is the library
// (Goodnotes-style); pen-only mode lives in the editor and is covered
// by canvas_drag_test.dart.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:notee/features/library/library_state.dart';
import 'package:notee/main.dart';

class _StubLibraryController extends LibraryController {
  @override
  Future<LibraryState> build() async => const LibraryState(
        folders: [],
        notes: [],
        currentFolderId: null,
      );
}

void main() {
  testWidgets('boots and shows the library', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider
              .overrideWith(_StubLibraryController.new),
        ],
        child: const NoteeApp(),
      ),
    );
    // Drain the async-build microtask.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NoteeApp), findsOneWidget);
    expect(find.text('Notee'), findsOneWidget);
    // Empty-state message (no folders / no notebooks yet).
    expect(find.textContaining('empty'), findsOneWidget);
  });
}
