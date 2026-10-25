import 'package:flutter/material.dart';

/// Primary button following MailChat's design system.
class AppButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isLoading;
  final AppButtonVariant variant;

  const AppButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isLoading = false,
    this.variant = AppButtonVariant.primary,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    final theme = Theme.of(context);

    Widget child = Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    );
    if (isLoading) {
      child = SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(
            variant == AppButtonVariant.primary ? Colors.white : theme.colorScheme.primary,
          ),
        ),
      );
    }

    switch (variant) {
      case AppButtonVariant.primary:
        return SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: enabled ? onPressed : null,
            child: child,
          ),
        );
      case AppButtonVariant.outlined:
        return SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: enabled ? onPressed : null,
            child: child,
          ),
        );
      case AppButtonVariant.text:
        return TextButton(
          onPressed: enabled ? onPressed : null,
          child: child,
        );
    }
  }
}

enum AppButtonVariant { primary, outlined, text }

/// Secondary action button (e.g. "Cancel", "Back").
class AppTextButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;

  const AppTextButton({super.key, required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      child: Text(text, style: const TextStyle(fontSize: 14)),
    );
  }
}
