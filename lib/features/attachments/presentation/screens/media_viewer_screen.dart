import 'package:flutter/material.dart';

/// Full-screen media viewer.
///
/// Attachments live in a private bucket and must be fetched through a signed
/// URL. Since Storage is not configured for this build, the viewer shows its
/// empty state instead of loading a remote URL it cannot authenticate.
class MediaViewerScreen extends StatelessWidget {
  final Map<String, dynamic>? arguments;

  const MediaViewerScreen({super.key, this.arguments});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = arguments?['fileName'] as String? ?? 'Media';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_not_supported_outlined,
                  size: 64, color: colors.onSurfaceVariant),
              const SizedBox(height: 16),
              const Text(
                'Media unavailable',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This attachment requires Supabase Storage signed URLs, which '
                'are not configured in this build.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: colors.onSurfaceVariant, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
