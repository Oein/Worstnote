// Platform-specific file save helper.
//
// Android: file_selector's getSaveLocation is unimplemented on Android.
//          We invoke ACTION_CREATE_DOCUMENT via a native method channel
//          so the system "Save to…" picker is shown and bytes are written
//          directly to the user-chosen content URI.
//
// Other platforms: uses the OS save dialog via file_selector.

import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

const _saver = MethodChannel('notee/file_saver');

String _mimeFor(String ext) => switch (ext) {
      'pdf'       => 'application/pdf',
      'zip'       => 'application/zip',
      'notee'     => 'application/zip',
      'worstnote' => 'application/zip',
      _           => 'application/octet-stream',
    };

/// Shows the OS save dialog and writes [bytes] to the chosen location.
/// Returns the saved file path (or filename on Android), or null if cancelled.
Future<String?> platformSaveBytes(
  Uint8List bytes, {
  required String suggestedName,
  required String extension,
  required String typeLabel,
}) async {
  if (Platform.isAndroid) {
    final fileName = '$suggestedName.$extension';
    try {
      final saved = await _saver.invokeMethod<bool>('saveFile', {
        'bytes':    bytes,
        'fileName': fileName,
        'mimeType': _mimeFor(extension),
      });
      return (saved == true) ? fileName : null;
    } on PlatformException {
      return null;
    }
  }

  final location = await getSaveLocation(
    acceptedTypeGroups: [XTypeGroup(label: typeLabel, extensions: [extension])],
    suggestedName: '$suggestedName.$extension',
  );
  if (location == null) return null;
  await File(location.path).writeAsBytes(bytes, flush: true);
  return location.path;
}
