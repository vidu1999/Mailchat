import 'package:mailchat/core/constants/app_constants.dart';

/// Validation rules for user input.
///
/// All rules are pure functions so they are easy to unit test.
class Validators {
  Validators._();

  static const String _usernamePattern = r'^[a-z0-9][a-z0-9_.]{2,29}$';

  /// Validates an email address (basic RFC-5322 subset).
  static String? email(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email is required';
    }
    final trimmed = value.trim();
    // Double-quoted raw string: the character class contains an apostrophe,
    // which a single-quoted raw string cannot hold.
    final emailRegex = RegExp(
      r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*$",
    );
    if (!emailRegex.hasMatch(trimmed)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  /// Validates a password against minimum strength rules.
  static String? password(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < AppConstants.minPasswordLength) {
      return 'Password must be at least ${AppConstants.minPasswordLength} characters';
    }
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return 'Password must contain an uppercase letter';
    }
    if (!RegExp(r'[a-z]').hasMatch(value)) {
      return 'Password must contain a lowercase letter';
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return 'Password must contain a number';
    }
    return null;
  }

  /// Validates a username: lowercase alphanumerics, underscores and dots,
  /// 3-30 characters, starting with a letter or digit.
  static String? username(String? value) {
    if (value == null || value.isEmpty) {
      return 'Username is required';
    }
    final trimmed = value.trim();
    if (trimmed.length < AppConstants.minUsernameLength) {
      return 'Username must be at least ${AppConstants.minUsernameLength} characters';
    }
    if (trimmed.length > AppConstants.maxUsernameLength) {
      return 'Username must be at most ${AppConstants.maxUsernameLength} characters';
    }
    final regex = RegExp(_usernamePattern);
    if (!regex.hasMatch(trimmed)) {
      return 'Use lowercase letters, numbers, underscores or dots only, '
          'and start with a letter or number';
    }
    return null;
  }

  /// Validates a display name (optional, 1-100 chars).
  static String? displayName(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    if (value.trim().isEmpty) {
      return 'Display name cannot be empty';
    }
    if (value.length > 100) {
      return 'Display name is too long';
    }
    return null;
  }

  /// Validates that a message body is non-empty and within limits.
  static String? message(String? value) {
    if (value == null || value.isEmpty) {
      return 'Message cannot be empty';
    }
    if (value.trim().isEmpty) {
      return 'Message cannot be empty';
    }
    if (value.length > AppConstants.maxMessageLength) {
      return 'Message is too long (max ${AppConstants.maxMessageLength} characters)';
    }
    return null;
  }

  /// Validates a required non-empty field.
  static String? required(String? value, String field) {
    if (value == null || value.trim().isEmpty) {
      return '$field is required';
    }
    return null;
  }
}
