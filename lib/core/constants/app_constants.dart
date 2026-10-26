/// Central constants for MailChat.
///
/// Keeps magic strings/numbers in one place so the design system and
/// business rules stay consistent and easy to change.
class AppConstants {
  AppConstants._();

  // ------------------------------------------------------------------
  // Limits / validation
  // ------------------------------------------------------------------
  static const int minUsernameLength = 3;
  static const int maxUsernameLength = 30;
  static const int minPasswordLength = 8;
  static const int maxMessageLength = 4000;
  static const int maxBioLength = 500;
  static const int maxGroupNameLength = 100;
  static const int maxGroupDescriptionLength = 500;
  static const int maxReportDescriptionLength = 2000;

  static const int defaultPageSize = 20;
  static const int messagesPageSize = 50;

  // File limits and presence windows are deliberately NOT duplicated here.
  // They used to be, and the copies disagreed with the code that enforces them
  // (100 MB here vs 10 MB in AttachmentService, a 5-minute online threshold
  // here vs 75 seconds in get_presence). A single source of truth each:
  //   * attachment size  -> AttachmentService.maxBytes
  //   * online window    -> PresenceService.onlineWindow (mirrors the SQL)
  //   * heartbeat period -> PresenceService.heartbeatInterval
  //   * typing expiry    -> PresenceService.typingTtl

  // ------------------------------------------------------------------
  // Usernames: case-insensitive unique, 3-30 chars,
  // lowercase letters, digits, underscore and dot only,
  // must start with a letter or digit.
  // ------------------------------------------------------------------
  static const String usernamePattern = r'^[a-z0-9][a-z0-9_.]{2,29}$';

  // ------------------------------------------------------------------
  // Storage paths
  // ------------------------------------------------------------------
  static String avatarPath(String userId) => 'avatars/$userId/profile.jpg';
  static String attachmentPath(String conversationId, String fileName) =>
      'attachments/$conversationId/$fileName';

  // ------------------------------------------------------------------
  // Message lifecycle states (client-side tracking)
  // ------------------------------------------------------------------
  static const String messageStatusPending = 'pending';
  static const String messageStatusSent = 'sent';
  static const String messageStatusDelivered = 'delivered';
  static const String messageStatusRead = 'read';
  static const String messageStatusFailed = 'failed';

  // ------------------------------------------------------------------
  // Conversation types
  // ------------------------------------------------------------------
  static const String conversationTypeDirect = 'direct';
  static const String conversationTypeGroup = 'group';

  // ------------------------------------------------------------------
  // Member roles
  // ------------------------------------------------------------------
  static const String memberRoleMember = 'member';
  static const String memberRoleAdmin = 'admin';
  static const String memberRoleOwner = 'owner';

  // ------------------------------------------------------------------
  // Report statuses
  // ------------------------------------------------------------------
  static const String reportStatusOpen = 'open';
  static const String reportStatusReviewed = 'reviewed';
  static const String reportStatusClosed = 'closed';
  static const String reportStatusDismissed = 'dismissed';
}
