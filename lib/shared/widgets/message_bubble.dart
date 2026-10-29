import 'package:flutter/material.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/shared/models/reaction_summary.dart';
import 'package:mailchat/core/theme/color_alpha.dart';

/// A single message bubble in a direct chat.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool showStatus;
  final String? senderName;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;

  /// Chips for this message. Empty renders nothing, so a message with no
  /// reactions looks exactly as it did before reactions existed.
  final List<ReactionChip> reactionChips;

  /// Files carried by this message. Several images render together as one album.
  final List<MessageAttachment> attachments;

  /// Resolves the private storage object to a short-lived signed URL.
  final Future<String> Function(MessageAttachment)? attachmentUrl;

  /// Opens a selected attachment in the media viewer.
  final ValueChanged<MessageAttachment>? onAttachmentTap;

  /// One-line preview of the message this one replies to. Null for an ordinary
  /// message; when the parent is not loaded the caller passes a placeholder
  /// rather than nothing, so the reply is never silently dropped.
  final String? replyPreview;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.showStatus = false,
    this.senderName,
    this.onLongPress,
    this.onRetry,
    this.reactionChips = const [],
    this.replyPreview,
    this.attachments = const [],
    this.attachmentUrl,
    this.onAttachmentTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMyOwn = isMe;

    final alignment = isMyOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isMyOwn
        ? colorScheme.primary
        : colorScheme.surfaceContainerHighest;
    final textColor = isMyOwn ? Colors.white : colorScheme.onSurface;

    Widget content = Column(
      crossAxisAlignment: alignment,
      children: [
        if (!isMyOwn && senderName != null && senderName!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 2),
            child: Text(
              senderName!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (replyPreview != null && replyPreview!.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlphaFactor(0.14),
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(
                          color: textColor.withAlphaFactor(0.7),
                          width: 2.5,
                        ),
                      ),
                    ),
                    child: Text(
                      replyPreview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: textColor.withAlphaFactor(0.85),
                      ),
                    ),
                  ),
                if (attachments.isNotEmpty && !message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final file in attachments)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: file.isImage
                                ? InkWell(
                                    onTap: onAttachmentTap == null
                                        ? null
                                        : () {
                                            onAttachmentTap!(file);
                                          },
                                    borderRadius: BorderRadius.circular(10),
                                    child: _SignedImageAttachment(
                                      futureUrl: attachmentUrl?.call(file),
                                      width: MediaQuery.of(context).size.width * .64,
                                    ),
                                  )
                                : InkWell(
                                    onTap: onAttachmentTap == null
                                        ? null
                                        : () {
                                            onAttachmentTap!(file);
                                          },
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withAlphaFactor(0.14),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            file.isVideo
                                                ? Icons.videocam_outlined
                                                : Icons.insert_drive_file_outlined,
                                            size: 20,
                                            color: textColor,
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              file.fileName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: textColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                // Soft-deleted messages must never render their old content.
                if (!message.isDeleted &&
                    message.text != null &&
                    message.text!.isNotEmpty)
                  Text(
                    message.text!,
                    style: TextStyle(color: textColor, fontSize: 15, height: 1.4),
                  ),
                if (message.isDeleted)
                  Text(
                    'This message was deleted',
                    style: TextStyle(
                      color: textColor.withAlphaFactor(0.7),
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                if (message.isEdited)
                  const Text(
                    'edited',
                    style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                  ),
                if (reactionChips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Semantics(
                      label: ReactionSummary.describe(reactionChips),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final chip in reactionChips)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                // The user's own reaction is tinted, so a tap
                                // that did not visibly change the count still
                                // shows that it registered.
                                color: chip.mine
                                    ? colorScheme.onPrimary
                                        .withAlphaFactor(0.28)
                                    : Colors.black.withAlphaFactor(0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${chip.emoji} ${chip.count}',
                                style: TextStyle(
                                    fontSize: 12, color: textColor),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppFormatters.messageTime(message.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: textColor.withAlphaFactor(0.7),
                      ),
                    ),
                    if (isMyOwn && showStatus) ...[
                      const SizedBox(width: 6),
                      _statusIcon(message.status),
                      if (onRetry != null &&
                          message.status == AppConstants.messageStatusFailed)
                        GestureDetector(
                          onTap: onRetry,
                          child: const Icon(Icons.refresh, size: 16, color: Colors.white),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (onLongPress != null) {
      content = GestureDetector(onLongPress: onLongPress, child: content);
    }

    return content;
  }

  Widget _statusIcon(String status) {
    // Own bubbles are painted in the theme primary. A tick in that same
    // colour sits on top of itself and looks missing. Seen is a light blue
    // double tick so it stays visible on the bubble.
    const seen = Color(0xFF7DD3FC);
    final data = switch (status) {
      AppConstants.messageStatusPending =>
        const _Status(Icons.access_time, Colors.white70),
      AppConstants.messageStatusSent => const _Status(Icons.check, Colors.white70),
      AppConstants.messageStatusDelivered =>
        const _Status(Icons.done_all, Colors.white70),
      AppConstants.messageStatusRead => const _Status(Icons.done_all, seen),
      _ => const _Status(Icons.error, Colors.redAccent),
    };
    return Icon(data.icon, size: 16, color: data.color);
  }
}

class _SignedImageAttachment extends StatelessWidget {
  const _SignedImageAttachment({
    required this.futureUrl,
    required this.width,
  });
  final Future<String>? futureUrl;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: futureUrl == null
            ? ColoredBox(
                color: colors.surfaceContainerHighest,
                child: const Icon(Icons.broken_image_outlined),
              )
            : FutureBuilder<String>(
                future: futureUrl,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: const Center(
                        child: SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  return Image.network(
                    snapshot.data!,
                    width: width,
                    height: width * 9 / 16,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _Status {
  final IconData icon;
  final Color color;
  const _Status(this.icon, this.color);
}
