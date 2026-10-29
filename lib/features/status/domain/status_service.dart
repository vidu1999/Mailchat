import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/features/status/domain/user_status.dart';

class StatusService {
  StatusService();

  final SupabaseClient _supabase = SupabaseClient.instance;

  static const String bucket = 'status-media';
  static const int maxBytes = 10 * 1024 * 1024;

  Future<List<StatusParticipant>> list({required String viewerId}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await _supabase.select(
      'user_statuses',
      filter: {'gt': 'expires_at,$now'},
      order: 'created_at.desc',
      limit: 100,
    );
    if (rows.isEmpty) return const [];

    final ids = rows.map((row) => row['id'] as String).toList();
    final authorIds = rows.map((row) => row['user_id'] as String).toSet();
    final profiles = await _supabase.select(
      'profiles',
      select: 'id,username,display_name,avatar_path',
      filter: {'id': 'in.(${authorIds.join(',')})'},
    );
    final profileMap = {for (final row in profiles) row['id'] as String: row};
    final views = await _supabase.select(
      'user_status_views',
      select: 'status_id,viewer_id',
      filter: {'status_id': 'in.(${ids.join(',')})'},
    );
    final viewersByStatus = <String, Set<String>>{};
    for (final view in views) {
      final statusId = view['status_id'] as String;
      viewersByStatus.putIfAbsent(statusId, () => <String>{})
        ..add(view['viewer_id'] as String);
    }

    final statuses = rows.map((row) {
      final viewers = viewersByStatus[row['id'] as String] ?? const <String>{};
      return UserStatus.fromJson(
        row,
        viewerCount: viewers.length,
        viewedByMe: viewers.contains(viewerId),
      );
    }).toList();
    final byAuthor = <String, List<UserStatus>>{};
    for (final status in statuses) {
      byAuthor.putIfAbsent(status.userId, () => []).add(status);
    }

    final participants = <StatusParticipant>[];
    for (final entry in byAuthor.entries) {
      final profile = profileMap[entry.key];
      if (profile == null) continue;
      participants.add(
        StatusParticipant(
          userId: entry.key,
          displayName: profile['display_name'] as String? ?? '',
          username: profile['username'] as String? ?? '',
          avatarPath: profile['avatar_path'] as String?,
          statuses: entry.value,
        ),
      );
    }
    participants.sort((a, b) {
      if (a.userId == viewerId) return -1;
      if (b.userId == viewerId) return 1;
      final aUnseen = a.statuses.any((status) => !status.viewedByMe);
      final bUnseen = b.statuses.any((status) => !status.viewedByMe);
      if (aUnseen != bUnseen) return aUnseen ? -1 : 1;
      return b.statuses.first.createdAt.compareTo(a.statuses.first.createdAt);
    });
    return participants;
  }

  Future<UserStatus> createText({
    required String userId,
    required String text,
    required int backgroundColor,
  }) async {
    final content = text.trim();
    if (content.isEmpty) throw ValidationException('Write something first.');
    if (content.length > 700)
      throw ValidationException('Status is limited to 700 characters.');
    return _insert({
      'user_id': userId,
      'status_type': 'text',
      'text': content,
      'background_color': backgroundColor,
    });
  }

  Future<UserStatus> createImage({
    required String userId,
    required XFile image,
    String? caption,
  }) async {
    final text = caption?.trim();
    if (text != null && text.length > 700) {
      throw ValidationException('Caption is limited to 700 characters.');
    }
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty) throw ValidationException('That photo is empty.');
    if (bytes.length > maxBytes)
      throw ValidationException('Choose a photo under 10 MB.');
    final extension = image.name.contains('.')
        ? image.name.split('.').last.toLowerCase()
        : '';
    final mime = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'heic' => 'image/heic',
      _ => throw ValidationException(
        'Choose a JPG, PNG, WEBP, GIF or HEIC photo.',
      ),
    };
    final id = _newId();
    final path = '$userId/$id/photo.$extension';
    await _supabase.uploadFile(
      bucket: bucket,
      path: path,
      bytes: bytes,
      contentType: mime,
    );
    final rows = await _supabase.insert(
      'user_statuses',
      data: {
        'id': id,
        'user_id': userId,
        'status_type': 'image',
        'text': text == null || text.isEmpty ? null : text,
        'media_path': path,
      },
      select: '*',
    );
    if (rows.isEmpty)
      throw AppException(
        'The photo was uploaded but the status was not saved.',
      );
    return UserStatus.fromJson(rows.first);
  }

  Future<UserStatus> _insert(Map<String, dynamic> data) async {
    final rows = await _supabase.insert(
      'user_statuses',
      data: data,
      select: '*',
    );
    if (rows.isEmpty) throw AppException('The status was not published.');
    return UserStatus.fromJson(rows.first);
  }

  Future<String> signedImageUrl(String path) =>
      _supabase.createSignedUrl(bucket: bucket, path: path, expiresIn: 300);

  Future<void> markViewed({
    required String statusId,
    required String viewerId,
  }) async {
    final existing = await _supabase.select(
      'user_status_views',
      select: 'status_id',
      filter: {'eq': 'status_id,$statusId,viewer_id,$viewerId'},
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await _supabase.insert(
      'user_status_views',
      data: {'status_id': statusId, 'viewer_id': viewerId},
    );
  }

  static String _newId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
