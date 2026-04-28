// Drift schema for the local SQLite store. Mirrors the server schema in
// shape but uses TEXT columns for JSON blobs (data, spec, background) so
// drift code-gen stays simple.
//
// Generated code: `dart run build_runner build` will produce
// notee_database.g.dart alongside this file.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'notee_database.g.dart';

@DataClassName('LocalUserRow')
class LocalUsers extends Table {
  TextColumn get id => text()();
  TextColumn get email => text().nullable()();
  TextColumn get displayName => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get title => text()();
  TextColumn get scrollAxis => text()(); // 'vertical' | 'horizontal'
  // 'any' | 'stylusOnly' — palm-rejection toggle.
  TextColumn get inputDrawMode =>
      text().withDefault(const Constant('any'))();
  TextColumn get defaultPageSpec => text()(); // JSON
  // null → root of the library; otherwise references folders.id.
  TextColumn get folderId => text().nullable()();
  IntColumn get rev => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  // Session ID of the app instance currently editing this note (null = unlocked).
  TextColumn get lockedBy => text().nullable()();
  // JSON array of tape stroke IDs currently in revealed (semi-transparent) state.
  TextColumn get revealedTapeIds =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('FolderRow')
class Folders extends Table {
  TextColumn get id => text()();
  // null = root folder.
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  IntColumn get rev => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PageRow')
class Pages extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text()();
  IntColumn get idx => integer()();
  TextColumn get spec => text()(); // JSON (PageSpec)
  IntColumn get rev => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LayerRow')
class Layers extends Table {
  TextColumn get id => text()();
  TextColumn get pageId => text()();
  IntColumn get z => integer()();
  TextColumn get name => text()();
  BoolColumn get visible => boolean().withDefault(const Constant(true))();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  RealColumn get opacity => real().withDefault(const Constant(1.0))();
  IntColumn get rev => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PageObjectRow')
class PageObjects extends Table {
  TextColumn get id => text()();
  TextColumn get pageId => text()();
  TextColumn get layerId => text()();
  TextColumn get kind => text()(); // stroke|shape|text|tape
  TextColumn get data => text()(); // JSON
  RealColumn get bboxMinX => real().nullable()();
  RealColumn get bboxMinY => real().nullable()();
  RealColumn get bboxMaxX => real().nullable()();
  RealColumn get bboxMaxY => real().nullable()();
  IntColumn get rev => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('OutboxRow')
class Outbox extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text()();
  TextColumn get objectId => text()();
  TextColumn get kind => text()();
  TextColumn get data => text()(); // JSON
  IntColumn get rev => integer()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get queuedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('UserPresetRow')
class UserPresets extends Table {
  TextColumn get userId => text()();
  IntColumn get slot => integer()();
  TextColumn get kind => text()();
  IntColumn get colorArgb => integer()();
  RealColumn get widthPt => real()();
  RealColumn get opacity => real().withDefault(const Constant(1.0))();

  @override
  Set<Column> get primaryKey => {userId, slot};
}

@DriftDatabase(tables: [
  LocalUsers,
  Folders,
  Notes,
  Pages,
  Layers,
  PageObjects,
  Outbox,
  UserPresets,
])
class NoteeDatabase extends _$NoteeDatabase {
  NoteeDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
            'ALTER TABLE notes ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
          );
          await customStatement(
            'ALTER TABLE folders ADD COLUMN color_argb INTEGER NOT NULL DEFAULT 4289773253',
          );
          await customStatement(
            "ALTER TABLE folders ADD COLUMN icon_key TEXT NOT NULL DEFAULT 'folder'",
          );
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(folders);
            await m.addColumn(notes, notes.folderId);
          }
          if (from < 3) {
            await customStatement(
              'ALTER TABLE notes ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (from < 4) {
            await customStatement(
              'ALTER TABLE folders ADD COLUMN color_argb INTEGER NOT NULL DEFAULT 4289773253',
            );
            await customStatement(
              "ALTER TABLE folders ADD COLUMN icon_key TEXT NOT NULL DEFAULT 'folder'",
            );
          }
          if (from < 5) {
            await customStatement(
              'ALTER TABLE notes ADD COLUMN locked_by TEXT',
            );
          }
          if (from < 6) {
            await customStatement(
              "ALTER TABLE notes ADD COLUMN revealed_tape_ids TEXT NOT NULL DEFAULT '[]'",
            );
          }
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'notee.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
