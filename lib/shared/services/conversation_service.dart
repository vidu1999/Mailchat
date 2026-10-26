import 'package:mailchat/core/constants/app_constants.dart';
import 'package:mailchat/core/errors/app_exception.dart';
import 'package:mailchat/core/logging/app_logger.dart';
import 'package:mailchat/core/network/rpc_payload.dart';
import 'package:mailchat/core/network/supabase_client.dart';
import 'package:mailchat/shared/models/conversation.dart';
import 'package:mailchat/shared/services/profile_service.dart';

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
    final items = data.map((e) => ConversationListItem.fromJson(e)).toList();
    return _fillMissingPreviews(items);
  }

  /// Fills in a preview for conversations the view reported as empty.
  ///
  /// `conversation_list` builds `last_message_text` from a lateral join over
  /// `messages`. When that comes back null for a conversation that does have
  /// messages — a stale view definition is the usual cause, since the view is
  /// applied by hand — the list showed "No messages yet" under a chat the user
  /// had just been talking in. Rather than display something untrue, ask the
  /// table directly for the conversations that need it.
  ///
  /// Logged as a warning because it means the view and the data disagree, which
  /// is worth fixing rather than papering over forever.
  Future<List<ConversationListItem>> _fillMissingPreviews(
    List<ConversationListItem> items,
  ) async {
    final missing = items
        .where((item) => item.lastMessageText == null ||
            item.lastMessageText!.trim().isEmpty)
        .map((item) => item.conversation.id)
        .toList();
    if (missing.isEmpty) return items;

    AppLogger.warning('conversation_preview_missing', details: {
      'count': missing.length,
      'conversationIds': missing,
    });

    final previews = <String, Map<String, dynamic>>{};
    for (final conversationId in missing) {
      try {
        final rows = await _supabase.select(
          'messages',
          select: 'text, created_at, sender_id, deleted_at',
          filter: {'eq': 'conversation_id,$conversationId'},
          order: 'created_at.desc',
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final row = rows.first;
        // A soft-deleted last message is not "No messages yet" either.
        final text = row['deleted_at'] != null
            ? 'This message was deleted'
            : (row['text'] as String?);
        if (text == null || text.trim().isEmpty) continue;
        previews[conversationId] = row;
      } catch (e, st) {
        AppLogger.error(e, st, {
          'where': 'chat_list_preview',
          'conversationId': conversationId,
        });
      }
    }
    if (previews.isEmpty) return items;

    return items.map((item) {
      final row = previews[item.conversation.id];
      if (row == null) return item;
      final deleted = row['deleted_at'] != null;
      return ConversationListItem(
        conversation: item.conversation,
        otherParticipant: item.otherParticipant,
        lastMessageText: deleted ? 'This message was deleted' : row['text'] as String?,
        lastMessageAt: DateTime.tryParse('${row['created_at']}'),
        lastMessageSenderId: row['sender_id'] as String?,
        unreadCount: item.unreadCount,
        isMuted: item.isMuted,
      );
    }).toList();
  }

  /// Records that the current user has read up to [messageId].
  ///
  /// The chat list's `unread_count` counts messages newer than
  /// `conversation_members.last_read_message_id`, so this single column is what
  /// clears the badge. RLS limits the row to the caller's own membership
  /// (`conversation_members_update_own`), so no user id is needed here.
  Future<void> markRead({
    required String conversationId,
    required String messageId,
  }) async {
    final userId = _supabase.userId;
    if (userId == null) return;
    await _supabase.update(
      'conversation_members',
      filter: {'eq': 'conversation_id,$conversationId,user_id,$userId'},
      data: {'last_read_message_id': messageId},
    );
  }

  // ------------------------------------------------------------------
  // Direct conversations
  // ------------------------------------------------------------------

  /// Finds or creates a direct conversation between [currentUserId] and
  /// [otherUserId].
  ///
  /// Returns the 1:1 conversation between [currentUserId] and [otherUserId],
  /// creating it if it does not exist.
  ///
  /// Delegates to the `get_or_create_direct_conversation` SECURITY DEFINER
  /// function. Doing this client-side would fail under RLS: creating the
  /// conversation requires `created_by = auth.uid()`, but inserting the *other*
  /// user's membership row is not permitted to a plain client. The function
  /// runs with elevated rights, verifies the caller is authenticated, and
  /// takes an advisory lock so two devices cannot create duplicates.
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

    final raw = await _supabase.rpc(
      'get_or_create_direct_conversation',
      params: {'other_user_id': otherUserId},
    );

    // PostgREST returns a bare uuid string for a scalar return type; the shape
    // is read by RpcPayload rather than assumed here.
    final conversationId = RpcPayload.scalar(raw);
    if (conversationId == null) {
      AppLogger.error(
        'direct_conversation_bad_payload',
        StackTrace.current,
        {'function': 'get_or_create_direct_conversation',
         'payloadType': raw.runtimeType.toString()},
      );
      throw AppException('Failed to open the conversation');
    }

    final rows = await _supabase.select(
      'conversations',
      filter: {'eq': 'id,$conversationId'},
      limit: 1,
    );
    if (rows.isEmpty) {
      throw NotFoundException('Conversation not found');
    }
    AppLogger.info('direct_conversation_ready', details: {
      'conversationId': conversationId,
      'otherUserId': otherUserId,
    });
    return Conversation.fromJson(rows.first);
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

    // The `conversations_ensure_owner` trigger already inserted the owner's
    // membership row; re-inserting it would violate the primary key.
    final otherMembers = memberIds.where((id) => id != ownerId).toSet();
    for (final userId in otherMembers) {
      await _supabase.insert(
        'conversation_members',
        data: {
          'conversation_id': conv.id,
          'user_id': userId,
          'role': AppConstants.memberRoleMember,
        },
      );
    }
    final allMembers = <String>{ownerId, ...otherMembers};

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
        'user_id': userId,
        'username': profile?.username,
        'display_name': profile?.displayName,
        'avatar_path': profile?.avatarPath,
        'role': member['role'] as String,
        'joined_at': member['joined_at'] as String?,
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
