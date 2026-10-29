class UserStatus {
  const UserStatus({
    required this.id,
    required this.userId,
    required this.type,
    required this.createdAt,
    required this.expiresAt,
    this.text,
    this.mediaPath,
    this.backgroundColor = 0xFF6366F1,
    this.viewerCount = 0,
    this.viewedByMe = false,
  });

  final String id;
  final String userId;
  final String type;
  final String? text;
  final String? mediaPath;
  final int backgroundColor;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int viewerCount;
  final bool viewedByMe;

  bool get isImage => type == 'image';

  factory UserStatus.fromJson(
    Map<String, dynamic> json, {
    int viewerCount = 0,
    bool viewedByMe = false,
  }) {
    return UserStatus(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      type: json['status_type'] as String,
      text: json['text'] as String?,
      mediaPath: json['media_path'] as String?,
      backgroundColor:
          (json['background_color'] as num?)?.toInt() ?? 0xFF6366F1,
      createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
      viewerCount: viewerCount,
      viewedByMe: viewedByMe,
    );
  }
}

class StatusParticipant {
  const StatusParticipant({
    required this.userId,
    required this.displayName,
    required this.username,
    required this.statuses,
    this.avatarPath,
  });

  final String userId;
  final String displayName;
  final String username;
  final String? avatarPath;
  final List<UserStatus> statuses;

  String get title => displayName.isNotEmpty ? displayName : username;
}
