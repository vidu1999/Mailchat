/// Base exception for all application-layer errors.
///
/// Carries a user-facing message and an optional machine-readable code so the
/// UI can render appropriate error states without inspecting message text.
class AppException implements Exception {
  final String message;
  final String? code;
  final Object? original;

  AppException(this.message, {this.code, this.original});

  @override
  String toString() => 'AppException(code: $code, message: $message)';
}

/// Thrown when validation of user input fails.
class ValidationException extends AppException {
  ValidationException(super.message, {super.code, super.original});
}

/// Thrown when the requested resource does not exist.
class NotFoundException extends AppException {
  NotFoundException(super.message, {super.original}) : super(code: 'not_found');
}

/// Thrown when the caller is not authorized to perform an operation.
class AuthorizationException extends AppException {
  AuthorizationException(super.message, {super.original})
      : super(code: 'unauthorized');
}

/// Thrown when a network request fails or times out.
class NetworkException extends AppException {
  NetworkException(super.message, {super.original})
      : super(code: 'network_error');
}

/// Thrown when Supabase returns an error response.
class SupabaseException extends AppException {
  // `statusCode` is kept for call-site compatibility but is already embedded in
  // the message; it is not stored separately.
  SupabaseException(super.message, {int? statusCode, super.original})
      : super(code: 'supabase_error');
}

/// Thrown when a file operation (upload/download/storage) fails.
class StorageException extends AppException {
  StorageException(super.message, {super.original}) : super(code: 'storage_error');
}
