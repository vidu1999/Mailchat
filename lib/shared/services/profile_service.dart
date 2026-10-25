import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/models/profile.dart';


/// Profile business logic: lookup, creation, updates, username availability.
class ProfileService {
  ProfileService();

  final SupabaseClient _supabase = SupabaseClient.instance;

  /// Returns the profile for [userId], or null if it does not exist.
  Future<Profile?> getProfile(String userId) async {
    final data = await _supabase.select(
      'profiles',
      select: 'id, username, display_name, avatar_path, bio, created_at, updated_at',
      filter: {'eq': 'id,$userId'},
      limit: 1,
    );
    if (data.isEmpty) return null;
    return Profile.fromJson(data.first);
  }

  /// Returns the profile for a [username] (case-insensitive lookup).
  Future<Profile?> getProfileByUsername(String username) async {
    final data = await _supabase.select(
      'profiles',
      select: 'id, username, display_name, avatar_path, bio, created_at, updated_at',
      filter: {'ilike': 'username,$username'},
      limit: 1,
    );
    if (data.isEmpty) return null;
    return Profile.fromJson(data.first);
  }

  /// Searches profiles by username or display name.
  ///
  /// Never exposes whether an email belongs to a user.
  Future<List<Profile>> searchProfiles(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final data = await _supabase.select(
      'profiles',
      select: 'id, username, display_name, avatar_path, bio, created_at, updated_at',
      filter: {
        'or': '(username.ilike.%${query.trim()}%,display_name.ilike.%${query.trim()}%)'
      },
      limit: limit,
    );
    return data.map((e) => Profile.fromJson(e)).toList();
  }

  /// Checks whether [username] is available (case-insensitive).
  Future<UsernameCheckResult> checkUsername(String username) async {
    final trimmed = username.trim().toLowerCase();
    final existing = await getProfileByUsername(trimmed);
    if (existing != null) {
      return const UsernameCheckResult.unavailable('Username is already taken');
    }
    return UsernameCheckResult.available();
  }

  /// Creates — or, if the signup trigger already did, completes — the profile
  /// row for a newly registered user.
  ///
  /// The `handle_new_user` database trigger inserts a profile row as soon as
  /// the auth user exists, so a blind INSERT here would fail with a duplicate
  /// key. Upsert semantics keep both paths working.
  Future<Profile> createProfile({
    required String userId,
    required String username,
    required String displayName,
  }) async {
    final byName = await getProfileByUsername(username);
    if (byName != null && byName.id != userId) {
      throw ValidationException('Username is already taken');
    }

    final existing = await getProfile(userId);
    if (existing != null) {
      final updated = await _supabase.update(
        'profiles',
        filter: {'eq': 'id,$userId'},
        data: {
          'username': username,
          'display_name': displayName,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
      if (updated.isEmpty) {
        throw AppException('Failed to complete profile');
      }
      AppLogger.info('profile_completed',
          details: {'userId': userId, 'username': username});
      return Profile.fromJson(updated.first);
    }

    final inserted = await _supabase.insert(
      'profiles',
      data: {
        'id': userId,
        'username': username,
        'display_name': displayName,
      },
      select: '*',
    );
    if (inserted.isEmpty) {
      throw AppException('Failed to create profile');
    }
    AppLogger.info('profile_created',
        details: {'userId': userId, 'username': username});
    return Profile.fromJson(inserted.first);
  }

  /// Updates the current user's profile. Only fields explicitly provided are
  /// changed; [userId] is enforced server-side by RLS.
  Future<Profile> updateProfile({
    required String userId,
    String? displayName,
    String? bio,
    String? avatarPath,
  }) async {
    final updates = <String, dynamic>{};
    if (displayName != null) updates['display_name'] = displayName.trim();
    if (bio != null) updates['bio'] = bio.trim();
    if (avatarPath != null) updates['avatar_path'] = avatarPath;
    updates['updated_at'] = DateTime.now().toIso8601String();

    if (updates.length <= 1) {
      throw ValidationException('Nothing to update');
    }

    final updated = await _supabase.update(
      'profiles',
      filter: {'eq': 'id,$userId'},
      data: updates,
    );
    if (updated.isEmpty) {
      throw NotFoundException('Profile not found');
    }
    AppLogger.info('profile_updated', details: {'userId': userId});
    return Profile.fromJson(updated.first);
  }

  /// Marks the user's avatar as uploaded and stores its path.
  Future<Profile> setAvatarPath(String userId, String path) async {
    return updateProfile(userId: userId, avatarPath: path);
  }
}


