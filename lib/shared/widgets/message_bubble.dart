import 'package:flutter/material.dart';
import 'package:mailchat/core/utils/formatters.dart';
import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/shared/models/message.dart';
import 'package:mailchat/core/theme/color_alpha.dart';

/// A single message bubble in a direct chat.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final bool showStatus;
  final String? senderName;
  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    this.showStatus = false,
    this.senderName,
    this.onLongPress,
    this.onRetry,
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
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      AppFormatters.chatTimestamp(message.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: textColor.withAlphaFactor(0.7),
                      ),
                    ),
                    if (isMyOwn && showStatus) ...[
                      const SizedBox(width: 6),
                      _statusIcon(message.status, colorScheme),
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

  Widget _statusIcon(String status, ColorScheme colorScheme) {
    final data = switch (status) {
      AppConstants.messageStatusPending => _Status(Icons.access_time, colorScheme.onSurfaceVariant),
      AppConstants.messageStatusSent => _Status(Icons.check, colorScheme.onSurfaceVariant),
      AppConstants.messageStatusDelivered => _Status(Icons.check, colorScheme.onSurface),
      AppConstants.messageStatusRead => _Status(Icons.done_all, colorScheme.primary),
      _ => _Status(Icons.error, Colors.redAccent),
    };
    return Icon(data.icon, size: 16, color: data.color);
  }
}

class _Status {
  final IconData icon;
  final Color color;
  _Status(this.icon, this.color);
}
