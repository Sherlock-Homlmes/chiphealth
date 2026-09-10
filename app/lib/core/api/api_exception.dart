/// One zod issue from the API's `details.issues`.
class ApiIssue {
  const ApiIssue({required this.path, required this.message});

  final String path;
  final String message;

  factory ApiIssue.fromJson(Map<String, dynamic> json) {
    final path = (json['path'] as List?)?.map((e) => '$e').join('.') ?? '';
    return ApiIssue(
        path: path, message: json['message'] as String? ?? 'invalid');
  }
}

/// Mirrors the API envelope `{ error: { code, message, details } }`.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.issues = const [],
  });

  final int statusCode;
  final String code;
  final String message;
  final List<ApiIssue> issues;

  bool get isUnauthenticated => statusCode == 401 || code == 'UNAUTHENTICATED';
  bool get isForbidden => statusCode == 403 || code == 'FORBIDDEN';
  bool get isValidation => code == 'VALIDATION_ERROR';

  /// True when the scanned barcode is simply not in the admin database yet —
  /// the app shows "chưa có dữ liệu" rather than an error.
  bool get isUnknownBarcode => code == 'BARCODE_NOT_FOUND';

  /// `{ field: message }` so a form can put the message under the right input.
  Map<String, String> get fieldErrors {
    final out = <String, String>{};
    for (final issue in issues) {
      if (issue.path.isEmpty) continue;
      out.putIfAbsent(issue.path, () => issue.message);
    }
    return out;
  }

  @override
  String toString() => message;
}
