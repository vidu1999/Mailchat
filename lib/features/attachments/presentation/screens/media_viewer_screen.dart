import 'package:flutter/material.dart';

import 'package:mailchat/shared/services/attachment_service.dart';

/// Full-screen viewer for one attachment.
///
/// The `attachments` bucket is private, so the caller supplies a short-lived
/// signed URL rather than a public one. Images render inline; anything else is
/// described, because opening a PDF or a Word file needs an OS hand-off this
/// build does not implement yet. Saying so is better than a button that
/// silently does nothing.
class MediaViewerScreen extends StatelessWidget {
  final Map<String, dynamic>? arguments;

  const MediaViewerScreen({super.key, this.arguments});

  @override
  Widget build(BuildContext context) {
    final args = arguments ?? const <String, dynamic>{};
    final fileName = args['fileName'] as String? ?? 'Media';
    final url = args['url'] as String?;
    final mimeType = args['mimeType'] as String? ?? '';
    final fileSize = args['fileSize'] as int?;
    final isImage = mimeType.startsWith('image/');

    final Widget body;
    if (isImage && url != null) {
      body = InteractiveViewer(
        maxScale: 4,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) =>
              _message(const ['That image could not be loaded.']),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const CircularProgressIndicator(color: Colors.white);
          },
        ),
      );
    } else if (url == null) {
      body = _message(const ['This attachment has no link to open.']);
    } else {
      body = _message([
        'Preview is not available for this file type yet.',
        mimeType.isEmpty ? 'Unknown type' : mimeType,
        if (fileSize != null) AttachmentService.formatSize(fileSize),
      ]);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(fileName, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(child: body),
    );
  }

  Widget _message(List<String> rows) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                row,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
