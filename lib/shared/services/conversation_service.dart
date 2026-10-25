import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/models/conversation.dart';
import 'package:mailchat/shared/models/profile.dart';

/// Conversation business logic: listing, direct 1:1 creation (uniqueness
/// enforced), group creation and membership management.
class ConversationService {
  ConversationService();

  final SupabaseClient _supabase = SupabaseClient.instance;
  final ProfileService _profileService = ProfileService();

  // ------------------------------------------------------------------
  // Listing
  // ------------------------------------------------------------------

  /// Returns conversations for the current user with last-message preview and
  /// unread counts, ordered by last activity.
  Future<List<ConversationListItem>> listConversations({
    int limit = AppConstants.defaultPageSize,
    int offset = 0,
  }) async {
    final userId = _supabase.userId;
    if (userId == null) throw AuthorizationException('Not authenticated');

    final data = await _supabase.select(
      'conversation_list',
      select: '*',
      filter: {'eq': 'user_id,$userId'},
      order: 'last_message_at.desc.nullslast, updated_at.desc',
      limit: limit,
      offset: offset,
      // RLS on the underlying tables ensures only authorized rows are returned.
    );
    return data.map((e) => ConversationListItem.fromJson(e)).toList();
  }

  // ------------------------------------------------------------------
  // Direct conversations
  // ------------------------------------------------------------------

  /// Finds or creates a direct conversation between [currentUserId] and
  /// [otherUserId].
  ///
  /// Duplicate direct conversations are prevented by a database-level unique
  /// partial index on the sorted member pair (see migrations) and by checking
  /// for an existing conversation before inserting.
  Future<Conversation> getOrCreateDirectConversation({
    required String currentUserId,
    required String otherUserId,
  }) async {
    if (currentUserId == otherUserId) {
      throw ValidationException('Cannot start a conversation with yourself');
    }

    final otherProfile = await _profileService.getProfile(otherUserId);
    if (otherProfile == null) {
      throw NotFoundException('User not found');
    }

    // 1. Look for an existing direct conversation shared by both users.
    final existing = await _findExistingDirectConversation(currentUserId, otherUserId);
    if (existing != null) {
      AppLogger.info(
        'direct_conversation_found',
        details: {'conversationId': existing.id, 'otherUserId': otherUserId},
      );
      return existing;
    }

    // 2. Create the conversation + both memberships.
    final memberIds = [currentUserId, otherUserId]..sort();
    final inserted = await _supabase.insert(
      'conversations',
      data: {
        'type': AppConstants.conversationTypeDirect,
        'member_user_ids': memberIds,
      },
      select: '*',
    );
    if (inserted.isEmpty) {
      throw AppException('Failed to create conversation');
    }
    final conv = Conversation.fromJson(inserted.first);

    await _supabase.insert(
      'conversation_members',
      data: {
        'conversation_id': conv.id,
        'user_id': currentUserId,
        'role': AppConstants.memberRoleMember,
      },
    );
    await _supabase.insert(
      'conversation_members',
      data: {
        'conversation_id': conv.id,
        'user_id': otherUserId,
        'role': AppConstants.memberRoleMember,
      },
    );

    AppLogger.info(
      'direct_conversation_created',
      details: {'conversationId': conv.id, 'memberIds': memberIds},
    );
    return conv;
  }

  Future<Conversation?> _findExistingDirectConversation(
    String userA,
    String userB,
  ) async {
    // Conversations where user A is a member.
    final aConvs = await _supabase.select(
      'conversation_members',
      select: 'conversation_id',
      filter: {'eq': 'user_id,$userA'},
    );
    if (aConvs.isEmpty) return null;

    final conversationIds = aConvs.map((e) => e['conversation_id'] as String).toList();

    // Among those, find direct conversations.
    final data = await _supabase.select(
      'conversations',
      select: '*',
      filter: {
        'and': '(id.in.(${conversationIds.join(',')}),type.eq.${AppConstants.conversationTypeDirect})'
      },
      limit: 50,
    );
    for (final row in data) {
      final conv = Conversation.fromJson(row);
      if (!conv.isDirect) continue;
      final members = await _supabase.select(
        'conversation_members',
        select: 'user_id',
        filter: {'eq': 'conversation_id,user_id,${conv.id},$userB'},
        limit: 1,
      );
      if (members.isNotEmpty) return conv;
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Groups
  // ------------------------------------------------------------------

  /// Creates a group conversation with the current user as owner.
  Future<Conversation> createGroup({
    required String ownerId,
    required String name,
    String? description,
    List<String> memberIds = const [],
  }) async {
    if (name.trim().isEmpty) {
      throw ValidationException('Group name is required');
    }
    if (name.length > AppConstants.maxGroupNameLength) {
      throw ValidationException(
          'Group name is too long (max ${AppConstants.maxGroupNameLength} characters)');
    }

    final inserted = await _supabase.insert(
      'conversations',
      data: {
        'type': AppConstants.conversationTypeGroup,
        'name': name.trim(),
        'description': description?.trim(),
        'created_by': ownerId,
      },
      select: '*',
    );
    if (inserted.isEmpty) throw AppException('Failed to create group');
    final conv = Conversation.fromJson(inserted.first);

    final allMembers = <String>{ownerId, ...memberIds};
    for (final userId in allMembers) {
      await _supabase.insert(
        'conversation_members',
        data: {
          'conversation_id': conv.id,
          'user_id': userId,
          'role': userId == ownerId
              ? AppConstants.memberRoleOwner
              : AppConstants.memberRoleMember,
        },
      );
    }

    AppLogger.info(
      'group_created',
      details: {'conversationId': conv.id, 'ownerId': ownerId, 'members': allMembers.length},
    );
    return conv;
  }

  /// Returns members of a conversation with their profiles.
  Future<List<Map<String, dynamic>>> getMembers(String conversationId) async {
    final members = await _supabase.select(
      'conversation_members',
      select: 'user_id, role, joined_at',
      filter: {'eq': 'conversation_id,$conversationId'},
      order: 'role.desc, joined_at.asc',
    );
    final result = <Map<String, dynamic>>[];
    for (final member in members) {
      final userId = member['user_id'] as String;
      final profile = await _profileService.getProfile(userId);
      result.add({
        'userId': userId,
        'role': member['role'] as String,
        'joinedAt': member['joined_at'] as String?,
        'profile': profile,
      });
    }
    return result;
  }

  /// Adds [userIds] to a group. Caller must be an admin/owner.
  Future<void> addMembers({
    required String conversationId,
    required String actorId,
    required List<String> userIds,
  }) async {
    await _assertMember(conversationId, actorId, requireAdmin: true);

    for (final userId in userIds) {
      final existing = await _supabase.select(
        'conversation_members',
        select: 'user_id',
        filter: {'eq': 'conversation_id,user_id,$conversationId,$userId'},
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      await _supabase.insert(
        'conversation_members',
        data: {
          'conversation_id': conversationId,
          'user_id': userId,
          'role': AppConstants.memberRoleMember,
        },
      );
    }
    AppLogger.info(
      'group_members_added',
      details: {'conversationId': conversationId, 'addedBy': actorId, 'count': userIds.length},
    );
  }

  /// Removes [userIds] from a group. Admins can remove anyone; users can
  /// remove themselves (leave).
  Future<void> removeMembers({
    required String conversationId,
    required String actorId,
    required List<String> userIds,
    bool isLeave = false,
  }) async {
    if (isLeave) {
      if (userIds.length != 1 || userIds.first != actorId) {
        throw AuthorizationException('You can only leave yourself');
      }
    } else {
      await _assertMember(conversationId, actorId, requireAdmin: true);
      if (userIds.contains(actorId)) {
        throw ValidationException('Owner cannot leave via remove; transfer ownership first');
      }
    }

    for (final userId in userIds) {
      await _supabase.delete(
        'conversation_members',
        filter: {'eq': 'conversation_id,user_id,$conversationId,$userId'},
      );
    }
    AppLogger.info(
      'group_members_removed',
      details: {'conversationId': conversationId, 'removedBy': actorId, 'count': userIds.length, 'leave': isLeave},
    );
  }

  /// Promotes or demotes a member's role. Owner only.
  Future<void> setRole({
    required String conversationId,
    required String actorId,
    required String targetUserId,
    required String role,
  }) async {
    await _assertMember(conversationId, actorId, requireOwner: true);
    if (![AppConstants.memberRoleOwner, AppConstants.memberRoleAdmin, AppConstants.memberRoleMember].contains(role)) {
      throw ValidationException('Invalid role');
    }
    await _supabase.update(
      'conversation_members',
      filter: {'eq': 'conversation_id,user_id,$conversationId,$targetUserId'},
      data: {'role': role},
    );
    AppLogger.info(
      'group_role_changed',
      details: {'conversationId': conversationId, 'target': targetUserId, 'role': role, 'by': actorId},
    );
  }

  /// Leaves a group conversation. The sole owner must transfer ownership first.
  Future<void> leaveGroup({required String conversationId, required String userId}) async {
    final members = await _supabase.select(
      'conversation_members',
      select: 'user_id, role',
      filter: {'eq': 'conversation_id,$conversationId'},
    );
    final isOwner = members.any((e) =>
        e['user_id'] == userId &&
        e['role'] == AppConstants.memberRoleOwner);
    final ownerCount = members.where((e) =>
        e['role'] == AppConstants.memberRoleOwner).length;
    if (isOwner && ownerCount == 1) {
      throw ValidationException('Transfer ownership to another member before leaving');
    }
    await removeMembers(
      conversationId: conversationId,
      actorId: userId,
      userIds: [userId],
      isLeave: true,
    );
  }

  Future<void> _assertMember(
    String conversationId,
    String userId, {
    bool requireAdmin = false,
    bool requireOwner = false,
  }) async {
    final member = await _supabase.select(
      'conversation_members',
      select: 'role',
      filter: {'eq': 'conversation_id,user_id,$conversationId,$userId'},
      limit: 1,
    );
    if (member.isEmpty) {
      throw AuthorizationException('Not a member of this conversation');
    }
    final role = member.first['role'] as String;
    if (requireOwner && role != AppConstants.memberRoleOwner) {
      throw AuthorizationException('Owner privileges required');
    }
    if (requireAdmin && ![
          AppConstants.memberRoleAdmin,
          AppConstants.memberRoleOwner,
        ].contains(role)) {
      throw AuthorizationException('Admin privileges required');
    }
  }
}
