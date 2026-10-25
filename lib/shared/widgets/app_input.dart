import 'package:flutter/material.dart';
import 'package:mailchat/core/constants/app_constants.dart';

/// Text field following MailChat's design system.
class AppInput extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final int maxLines;
  final int? maxLength;
  final bool readOnly;
  final VoidCallback? onTap;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final String? Function(String?)? validator;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final bool autoFocus;
  final bool enabled;

  const AppInput({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.done,
    this.maxLines = 1,
    this.maxLength,
    this.readOnly = false,
    this.onTap,
    this.onChanged,
    this.onEditingComplete,
    this.validator,
    this.prefixIcon,
    this.suffixIcon,
    this.autoFocus = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          maxLines: maxLines,
          maxLength: maxLength,
          readOnly: readOnly,
          enabled: enabled,
          autofocus: autoFocus,
          onTap: onTap,
          onChanged: onChanged,
          onEditingComplete: onEditingComplete,
          validator: validator,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            prefixIcon: prefixIcon,
            suffixIcon: suffixIcon,
            counterText: maxLength != null ? null : '',
          ),
        ),
      ],
    );
  }
}

/// Validates and returns a trimmed username, or throws [ValidationException].
String validateUsernameInput(String? value) {
  final trimmed = (value ?? '').trim();
  if (trimmed.isEmpty) {
    return 'Username is required';
  }
  if (trimmed.length < AppConstants.minUsernameLength) {
    return 'Username must be at least ${AppConstants.minUsernameLength} characters';
  }
  if (trimmed.length > AppConstants.maxUsernameLength) {
    return 'Username must be at most ${AppConstants.maxUsernameLength} characters';
  }
  final regex = RegExp(AppConstants.usernamePattern);
  if (!regex.hasMatch(trimmed)) {
    return 'Use lowercase letters, numbers, underscores or dots only, '
        'and start with a letter or number';
  }
  return trimmed;
}
