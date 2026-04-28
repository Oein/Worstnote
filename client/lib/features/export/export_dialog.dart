// ExportDialog — modal that lets the user pick between PDF, images ZIP,
// and .notee file export before running the appropriate exporter.

import 'package:flutter/material.dart';

import '../notebook/notebook_state.dart';
import 'images_zip_exporter.dart';
import 'notee_exporter.dart';
import 'pdf_exporter.dart';

enum _ExportType { pdf, imagesZip, noteeFile }

class ExportDialog {
  /// Shows the export-type picker, then runs the chosen exporter.
  /// Returns the saved file path, or null if cancelled.
  static Future<String?> show(
    BuildContext context,
    NotebookState state, {
    String? suggestedName,
  }) async {
    final type = await showDialog<_ExportType>(
      context: context,
      builder: (_) => const _ExportPickerDialog(),
    );
    if (type == null || !context.mounted) return null;

    switch (type) {
      case _ExportType.pdf:
        return PdfExporter.exportNoteWithProgress(
          context, state,
          suggestedName: suggestedName,
        );
      case _ExportType.imagesZip:
        return ImagesZipExporter.exportNoteWithProgress(
          context, state,
          suggestedName: suggestedName,
        );
      case _ExportType.noteeFile:
        return NoteeExporter.exportNoteWithProgress(
          context, state,
          suggestedName: suggestedName,
        );
    }
  }
}

class _ExportPickerDialog extends StatelessWidget {
  const _ExportPickerDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('내보내기'),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          _Tile(
            icon: Icons.picture_as_pdf_outlined,
            label: 'PDF',
            subtitle: '벡터 + 래스터 렌더링',
            value: _ExportType.pdf,
          ),
          _Tile(
            icon: Icons.photo_library_outlined,
            label: '이미지 ZIP',
            subtitle: '페이지당 PNG 이미지',
            value: _ExportType.imagesZip,
          ),
          _Tile(
            icon: Icons.save_outlined,
            label: 'Worstnote 파일',
            subtitle: '.worstnote — 재가져오기 가능',
            value: _ExportType.noteeFile,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final _ExportType value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(subtitle),
      onTap: () => Navigator.of(context).pop(value),
    );
  }
}
