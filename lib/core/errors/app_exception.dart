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
  ValidationException(String message, {String? code, Object? original})
      : super(message, code: code, original: original);
}

/// Thrown when the requested resource does not exist.
class NotFoundException extends AppException {
  NotFoundException(String message, {Object? original})
      : super(message, code: 'not_found', original: original);
}

/// Thrown when the caller is not authorized to perform an operation.
class AuthorizationException extends AppException {
  AuthorizationException(String message, {Object? original})
      : super(message, code: 'unauthorized', original: original);
}

/// Thrown when a network request fails or times out.
class NetworkException extends AppException {
  NetworkException(String message, {Object? original})
      : super(message, code: 'network_error', original: original);
}

/// Thrown when Supabase returns an error response.
class SupabaseException extends AppException {
  SupabaseException(String message, {int? statusCode, Object? original})
      : super(message, code: 'supabase_error', original: original);
}

/// Thrown when a file operation (upload/download/storage) fails.
class StorageException extends AppException {
  StorageException(String message, {Object? original})
      : super(message, code: 'storage_error', original: original);
}
