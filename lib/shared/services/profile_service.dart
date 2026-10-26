import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/models/profile.dart';
import 'package:mailchat/shared/models/profile_search.dart';


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

  /// Searches for people by username, display name, or exact email address.
  ///
  /// Runs `public.search_users` (migration 0005) rather than a plain select on
  /// `profiles`, for two reasons that a select cannot satisfy:
  ///
  ///  * **Email lives in `auth.users`.** `profiles` is readable by every
  ///    authenticated user, so an email column there would publish every
  ///    address in the project to every account. The function reads
  ///    `auth.users` as its definer, matches on the address, and returns only
  ///    profile fields — the address is an input, never an output.
  ///  * **Discoverability and blocking are server decisions.** Both flags and
  ///    the block list are applied inside the function, so a modified client
  ///    cannot widen the search.
  ///
  /// Address matching is exact and case-insensitive: a partial address matches
  /// nobody, which keeps the endpoint from being usable to enumerate accounts
  /// from fragments.
  Future<List<Profile>> searchProfiles(String query, {int limit = 20}) async {
    final typed = SearchQuery(query).normalised();
    if (!typed.isSearchable) return [];

    final data = await _supabase.rpc(
      'search_users',
      params: {'p_query': typed.text, 'p_limit': limit},
    );

    // PostgREST returns an array of rows for a set-returning function. A
    // scalar-shaped reply would mean the function signature changed, so treat
    // anything else as an empty result rather than throwing on the cast.
    if (data is! List) {
      AppLogger.warning(
        'search_users_unexpected_shape',
        details: {'type': data.runtimeType.toString()},
      );
      return const [];
    }
    return data
        .whereType<Map>()
        .map((row) => Profile.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  /// Reads the discoverability flags for [userId] so Privacy settings can show
  /// the stored values rather than assuming defaults.
  Future<Profile?> getDiscoverability(String userId) async {
    final data = await _supabase.select(
      'profiles',
      select: 'id, username, display_name, avatar_path, bio, created_at, '
          'updated_at, discoverable_by_email, discoverable_by_username',
      filter: {'eq': 'id,$userId'},
      limit: 1,
    );
    if (data.isEmpty) return null;
    return Profile.fromJson(data.first);
  }

  /// Updates the caller's discoverability flags.
  ///
  /// Both are opt-out and enforced in `public.search_users`, so turning one off
  /// removes the user from that kind of search immediately. RLS already limits
  /// this update to the caller's own row.
  Future<void> setDiscoverability(
    String userId, {
    bool? byEmail,
    bool? byUsername,
  }) async {
    final updates = <String, dynamic>{
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (byEmail != null) updates['discoverable_by_email'] = byEmail;
    if (byUsername != null) updates['discoverable_by_username'] = byUsername;
    if (updates.length == 1) return;

    await _supabase.update(
      'profiles',
      filter: {'eq': 'id,$userId'},
      data: updates,
    );
    AppLogger.info('discoverability_updated', details: {
      'userId': userId,
      if (byEmail != null) 'byEmail': byEmail,
      if (byUsername != null) 'byUsername': byUsername,
    });
  }

  /// Checks whether [username] is available (case-insensitive).
  Future<UsernameCheckResult> checkUsername(String username) async {
    final trimmed = username.trim().toLowerCase();
    final existing = await getProfileByUsername(trimmed);
    if (existing != null) {
      return UsernameCheckResult.unavailable('Username is already taken');
    }
    return UsernameCheckResult.available();
  }

  /// Creates — or, if the signup trigger already did, completes — the profile
  /// row for a newly registered user.
  ///
  /// Normally unnecessary: the `handle_new_user` trigger inserts the row from
  /// the signup metadata. Kept as a repair path for the case where the trigger
  /// is missing (e.g. migrations applied out of order) or a profile row was
  /// deleted. Requires an authenticated session.
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


