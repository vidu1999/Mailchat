import 'package:mailchat/core/constants/app_constants.dart';

/// Public profile of a user. Authentication identity lives in
/// `auth.users`; this table only holds profile data.
class Profile {
  final String id; // auth.users id
  final String username;
  final String displayName;
  final String? avatarPath;
  final String? bio;
  final DateTime createdAt;
  final DateTime updatedAt;

  Profile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarPath,
    this.bio,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Display name used in the UI: falls back to username.
  String get displayNameOrUsername => displayName.isNotEmpty ? displayName : username;

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      avatarPath: json['avatar_path'] as String?,
      bio: json['bio'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'display_name': displayName,
      'avatar_path': avatarPath,
      'bio': bio,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Profile copyWith({
    String? id,
    String? username,
    String? displayName,
    String? avatarPath,
    String? bio,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Profile(
      id: id ?? this.id,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      avatarPath: avatarPath ?? this.avatarPath,
      bio: bio ?? this.bio,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Result of a username availability check.
class UsernameCheckResult {
  final bool available;
  final String? error;

  UsernameCheckResult.available() : available = true, error = null;
  UsernameCheckResult.unavailable(this.error) : available = false;
}
