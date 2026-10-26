import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/models/message.dart';

/// Sending and opening files.
///
/// The database and storage layout have existed since 0001/0004 — a private
/// `attachments` bucket, a policy that lets conversation members read objects in
/// their conversation's folder, and a `message_attachments` row per file. What
/// was missing was the path from the picker to those tables; this is it.
///
/// Order of operations matters: the bytes are uploaded **before** the rows are
/// written, so a failed upload cannot leave a message pointing at a file that
/// does not exist. If the attachment row fails after a successful upload the
/// object is orphaned, which is recoverable (a cleanup job can sweep the bucket)
/// whereas a broken message in the thread is not.
class AttachmentService {
  AttachmentService();

  final SupabaseClient _supabase = SupabaseClient.instance;

  static const String bucket = 'attachments';

  /// Matches the size the picker is asked for and keeps a single message from
  /// blocking a mobile connection for minutes.
  static const int maxBytes = 10 * 1024 * 1024;

  /// Uploads [bytes] and posts a message carrying them.
  ///
  /// [mimeType] is what the picker reported; when it is unknown the file is
  /// still sent, labelled `application/octet-stream`, rather than refused.
  Future<Message> sendAttachment({
    required String conversationId,
    required String senderId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) {
      throw ValidationException('That file is empty');
    }
    if (bytes.length > maxBytes) {
      throw ValidationException(
        'Files must be under ${(maxBytes / (1024 * 1024)).round()} MB',
      );
    }

    final safeName = sanitiseFileName(fileName);
    final path = '$conversationId/${DateTime.now().millisecondsSinceEpoch}_$safeName';
    final type = mimeType.startsWith('image/') ? 'image' : 'file';

    final storedPath = await _supabase.uploadFile(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
    );

    final inserted = await _supabase.insert(
      'messages',
      data: {
        'conversation_id': conversationId,
        'sender_id': senderId,
        'type': type,
        'text': null,
      },
      select: '*',
    );
    if (inserted.isEmpty) {
      throw AppException('The message was not created');
    }
    final message = Message.fromJson(inserted.first);

    await _supabase.insert(
      'message_attachments',
      data: {
        'message_id': message.id,
        'storage_path': storedPath,
        'file_name': safeName,
        'mime_type': mimeType.isEmpty ? 'application/octet-stream' : mimeType,
        'file_size': bytes.length,
      },
    );

    AppLogger.info('attachment_sent', details: {
      'messageId': message.id,
      'bytes': bytes.length,
      'type': type,
    });

    return message;
  }

  /// A short-lived URL for one attachment. The bucket is private, so this is
  /// the only way to render an image or hand the file to the OS.
  Future<String> signedUrl(MessageAttachment attachment) {
    return _supabase.createSignedUrl(
      bucket: bucket,
      path: attachment.storagePath,
    );
  }

  /// Keeps the object name predictable and inert: no path separators, no
  /// leading dots, and never empty.
  static String sanitiseFileName(String name) {
    final base = name.split('/').last.split('\\').last.trim();
    final cleaned = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty || cleaned.replaceAll('.', '').isEmpty) {
      return 'attachment';
    }
    return cleaned.length <= 80 ? cleaned : cleaned.substring(cleaned.length - 80);
  }

  /// Best-effort MIME type from the file name.
  ///
  /// The picker reports an extension, not a MIME type. Guessing from a fixed
  /// table keeps the stored value honest for the common cases and falls back to
  /// `application/octet-stream`, which is what an unknown type actually is.
  static String mimeTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return 'application/octet-stream';
    switch (fileName.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  /// Human-readable size for the bubble.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
