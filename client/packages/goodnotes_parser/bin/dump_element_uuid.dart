import 'dart:io';
import 'package:goodnotes_parser/src/protobuf.dart';
import 'package:goodnotes_parser/src/parsers.dart';

void main(List<String> args) {
  final data = File(args[0]).readAsBytesSync();
  final page = parseNotePage(pageId: 'x', data: data);
  // Print id for specific index
  final idx = int.parse(args[1]);
  print(page.elements[idx].id);
}
