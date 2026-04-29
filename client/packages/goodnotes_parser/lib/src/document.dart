import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'model.dart';
import 'parsers.dart';

/// Top-level handle to a parsed GoodNotes package.
class GoodNotesDocument {
  /// Document title (extracted from the events log if available).
  final String? title;
  /// Schema version from `schema.pb` (24, 25 or 31 observed).
  final int schemaVersion;
  /// Pages in display order.
  final List<Page> pages;
  /// All attachments keyed by their attachment-id (UUID from
  /// `index.attachments.pb`).
  final Map<String, Attachment> attachments;
  /// All search indices keyed by their target id.
  final Map<String, SearchIndex> searchIndices;
  /// Cover thumbnail bytes (JPEG), or `null` if missing.
  final Uint8List? thumbnail;
  /// Raw extracted files — useful when callers need fields we didn't model.
  final Map<String, Uint8List> rawFiles;

  GoodNotesDocument._({
    required this.title,
    required this.schemaVersion,
    required this.pages,
    required this.attachments,
    required this.searchIndices,
    required this.thumbnail,
    required this.rawFiles,
  });

  /// Open a `.goodnotes` (zipped) file from disk.
  static Future<GoodNotesDocument> openFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return openBytes(bytes);
  }

  /// Open a `.goodnotes` archive from raw bytes.
  static GoodNotesDocument openBytes(Uint8List bytes) {
    final files = _readArchive(bytes);
    return _build(files);
  }

  /// Open an already-extracted directory (the format on disk after the user
  /// has unzipped the package). Useful while debugging.
  static Future<GoodNotesDocument> openDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    final files = <String, Uint8List>{};
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final rel = entity.path
            .substring(dir.path.length)
            .replaceAll(RegExp(r'^/+'), '');
        files[rel] = await entity.readAsBytes();
      }
    }
    return _build(files);
  }

  // ---- internals ----

  static Map<String, Uint8List> _readArchive(Uint8List zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final files = <String, Uint8List>{};
    String? topPrefix;
    // Detect a single top-level directory wrapper (e.g. "Foo.pdf/...") and
    // strip it so paths look like "schema.pb", "notes/<UUID>" etc.
    final topNames = <String>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final i = f.name.indexOf('/');
      if (i > 0) topNames.add(f.name.substring(0, i));
    }
    if (topNames.length == 1) topPrefix = '${topNames.first}/';
    for (final f in archive.files) {
      if (!f.isFile) continue;
      var name = f.name;
      // skip Apple resource fork / metadata
      if (name.contains('__MACOSX/')) continue;
      if (name.endsWith('/.DS_Store')) continue;
      if (topPrefix != null && name.startsWith(topPrefix)) {
        name = name.substring(topPrefix.length);
      }
      if (name.isEmpty) continue;
      final content = f.content;
      files[name] = content is Uint8List
          ? content
          : Uint8List.fromList(content as List<int>);
    }
    return files;
  }

  static GoodNotesDocument _build(Map<String, Uint8List> files) {
    final schema = files['schema.pb'];
    final schemaVersion =
        schema == null ? 0 : parseSchemaVersion(schema);

    // Attachments
    final attachIndex = files['index.attachments.pb'];
    final attachments = <String, Attachment>{};
    if (attachIndex != null) {
      for (final e in parseIndex(attachIndex)) {
        final bytes = files[e.path];
        if (bytes == null) continue;
        // disk uuid is the basename of `path`
        final slash = e.path.lastIndexOf('/');
        final disk = slash >= 0 ? e.path.substring(slash + 1) : e.path;
        attachments[e.uuid] = Attachment(
          id: e.uuid, diskUuid: disk, bytes: bytes,
        );
      }
    }

    // Search indices
    final searchIndex = files['index.search.pb'];
    final indices = <String, SearchIndex>{};
    if (searchIndex != null) {
      for (final e in parseIndex(searchIndex)) {
        final bytes = files[e.path];
        if (bytes == null) continue;
        indices[e.uuid] = parseSearchIndex(
          targetId: e.uuid,
          forAttachment: e.flag == 1,
          data: bytes,
        );
      }
    }

    // Page-create events provide background attachment ids in creation
    // order — pair them with notes-index entries that look like real pages.
    final events = files['index.events.pb'];
    final pageBackgrounds = events == null
        ? const <String>[]
        : extractPageBackgroundAttachments(events);
    String? title;
    if (events != null) {
      title = extractTitleFromEvents(events);
    }

    // Pages
    final notesIndex = files['index.notes.pb'];
    final pages = <Page>[];
    if (notesIndex != null) {
      var bgIdx = 0;
      for (final e in parseIndex(notesIndex)) {
        final bytes = files[e.path];
        if (bytes == null || bytes.isEmpty) {
          pages.add(Page(
            id: e.uuid, elements: const [],
            schemaVersion: schemaVersion,
          ));
          continue;
        }
        var page = parseNotePage(pageId: e.uuid, data: bytes);
        // events.pb's PageCreate is authoritative for the page background.
        // For pages without a PageCreate-bg event (e.g. user added a
        // blank page and pasted an image on top), DO NOT fall back to a
        // per-element ref — that would falsely promote the inserted
        // image to a full-page background. Leave bg null; the renderer
        // will draw a blank A4 canvas under the elements.
        final String? bgFromEvents =
            bgIdx < pageBackgrounds.length ? pageBackgrounds[bgIdx] : null;
        bgIdx++;
        page = Page(
          id: page.id,
          backgroundAttachmentId: bgFromEvents,
          elements: page.elements,
          schemaVersion: page.schemaVersion,
        );
        pages.add(page);
      }
    }

    return GoodNotesDocument._(
      title: title,
      schemaVersion: schemaVersion,
      pages: pages,
      attachments: attachments,
      searchIndices: indices,
      thumbnail: files['thumbnail.jpg'],
      rawFiles: files,
    );
  }

  Attachment? backgroundOf(Page page) =>
      page.backgroundAttachmentId == null
          ? null
          : attachments[page.backgroundAttachmentId];

  @override
  String toString() => 'GoodNotesDocument("$title", v$schemaVersion, '
      '${pages.length} pages, ${attachments.length} attachments)';
}
