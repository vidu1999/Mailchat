import 'package:flutter/material.dart';

import 'package:mailchat/core/logging/app_logger.dart';

/// Attachment preview before upload.
///
/// Picking a file requires a platform picker plugin and uploading requires the
/// Supabase Storage bucket plus signed-URL support. Neither is wired in this
/// build, so this screen renders the composition UI and reports that upload is
/// unavailable rather than faking a successful send.
class AttachmentPreviewScreen extends StatefulWidget {
  final Map<String, dynamic>? arguments;

  const AttachmentPreviewScreen({super.key, this.arguments});

  @override
  State<AttachmentPreviewScreen> createState() =>
      _AttachmentPreviewScreenState();
}

class _AttachmentPreviewScreenState extends State<AttachmentPreviewScreen> {
  final _captionController = TextEditingController();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  void _pickFile() {
    _notConfigured();
  }

  void _send() {
    _notConfigured();
  }

  void _notConfigured() {
    AppLogger.info('attachment_upload_unavailable');
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Attachments not available yet'),
        content: const Text(
          'File sending needs a platform file picker and a Supabase Storage '
          'bucket with signed URLs. These are not configured in this build, '
          'so nothing will be uploaded. See docs/attachments.md.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Attachment')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: InkWell(
                onTap: _pickFile,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.upload_file_outlined,
                          size: 56, color: colors.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text(
                        'Choose a file',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Images, video, audio and documents',
                        style: TextStyle(
                            fontSize: 12.5, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              decoration: InputDecoration(
                hintText: 'Add a caption',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _send,
                child: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
