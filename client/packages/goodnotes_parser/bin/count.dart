import 'package:goodnotes_parser/goodnotes_parser.dart';
import 'package:goodnotes_parser/src/model.dart';

Future<void> main(List<String> args) async {
  final doc = args[0].endsWith('.goodnotes')
      ? await GoodNotesDocument.openFile(args[0])
      : await GoodNotesDocument.openDirectory(args[0]);
  for (var pi = 0; pi < doc.pages.length; pi++) {
    final p = doc.pages[pi];
    final c = <String, int>{};
    for (final e in p.elements) {
      final k = e.runtimeType.toString();
      c[k] = (c[k] ?? 0) + 1;
    }
    final colors = <String, int>{};
    for (final s in p.elements.whereType<StrokeElement>()) {
      final cl = s.color;
      final k = '${(cl.r*255).round()},${(cl.g*255).round()},${(cl.b*255).round()}';
      colors[k] = (colors[k] ?? 0) + 1;
    }
    print('Page ${pi+1}: $c');
    print('  stroke colors: $colors');
  }
}
