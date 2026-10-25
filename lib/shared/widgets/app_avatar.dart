import 'package:flutter/material.dart';
import 'package:mailchat/shared/models/profile.dart';

/// Circular avatar showing either a network image or the user's initials.
///
/// Falls back to initials automatically if the image fails to load.
class AppAvatar extends StatefulWidget {
  final Profile? profile;
  final String? username;
  final String? displayName;
  final double radius;
  final double borderWidth;
  final Color? borderColor;
  final bool online;
  final Widget? child;

  const AppAvatar({
    super.key,
    this.profile,
    this.username,
    this.displayName,
    this.radius = 24,
    this.borderWidth = 0,
    this.borderColor,
    this.online = false,
    this.child,
  });

  @override
  State<AppAvatar> createState() => _AppAvatarState();
}

class _AppAvatarState extends State<AppAvatar> {
  bool _imageFailed = false;

  String? get _avatarPath => widget.profile?.avatarPath;

  String get _label {
    final name = widget.displayName ??
        (widget.profile?.displayName ??
            widget.username ??
            widget.profile?.username ??
            '');
    if (name.isNotEmpty) return name;
    return '?';
  }

  String get _initials {
    final name = _label.trim();
    if (name.isEmpty) return '?';
    final parts = name.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget avatar;
    if (_avatarPath != null && _avatarPath!.isNotEmpty && !_imageFailed) {
      avatar = CircleAvatar(
        radius: widget.radius,
        backgroundImage: NetworkImage(_avatarPath!),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        // Without this the documented initials fallback never triggers: a
        // failed load silently renders an empty circle.
        onBackgroundImageError: (_, __) {
          if (mounted) setState(() => _imageFailed = true);
        },
        child: widget.child ?? const SizedBox.shrink(),
      );
    } else {
      avatar = _initialsAvatar(theme);
    }

    Widget result = avatar;
    if (widget.borderWidth > 0) {
      result = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: widget.borderColor ?? theme.colorScheme.primary,
            width: widget.borderWidth,
          ),
        ),
        child: result,
      );
    }
    if (widget.online) {
      result = Stack(
        children: [
          result,
          Positioned(
            bottom: 0,
            right: 0,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return result;
  }

  Widget _initialsAvatar(ThemeData theme) {
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        _initials,
        style: TextStyle(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: widget.radius * 0.55,
        ),
      ),
    );
  }
}
