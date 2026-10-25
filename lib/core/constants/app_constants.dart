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

  // File limits (bytes)
  static const int maxAttachmentSize = 100 * 1024 * 1024; // 100 MB
  static const int maxImageSize = 20 * 1024 * 1024; // 20 MB
  static const int maxVideoSize = 100 * 1024 * 1024; // 100 MB

  // Presence / typing
  static const Duration onlineThreshold = Duration(minutes: 5);
  static const Duration typingDebounce = Duration(milliseconds: 600);
  static const Duration typingDisplay = Duration(seconds: 5);

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
