import 'package:mailchat/core/constants/app_constants.dart';

/// A device registered for push notifications.
class UserDevice {
  final String id;
  final String userId;
  final String deviceId;
  final String platform; // ios | android | web
  final String? pushToken;
  final DateTime? lastActiveAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  UserDevice({
    required this.id,
    required this.userId,
    required this.deviceId,
    required this.platform,
    this.pushToken,
    this.lastActiveAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UserDevice.fromJson(Map<String, dynamic> json) {
    return UserDevice(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      platform: json['platform'] as String,
      pushToken: json['push_token'] as String?,
      lastActiveAt: json['last_active_at'] != null
          ? DateTime.tryParse(json['last_active_at'] as String)
          : null,
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
      'user_id': userId,
      'device_id': deviceId,
      'platform': platform,
      'push_token': pushToken,
      'last_active_at': lastActiveAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

/// A block relationship: [blockerId] blocked [blockedUserId].
class UserBlock {
  final String id;
  final String blockerId;
  final String blockedUserId;
  final DateTime createdAt;

  UserBlock({
    required this.id,
    required this.blockerId,
    required this.blockedUserId,
    required this.createdAt,
  });

  factory UserBlock.fromJson(Map<String, dynamic> json) {
    return UserBlock(
      id: json['id'] as String,
      blockerId: json['blocker_id'] as String,
      blockedUserId: json['blocked_user_id'] as String,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'blocker_id': blockerId,
      'blocked_user_id': blockedUserId,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
