import '../util/cancel.dart';

/// One request to the Messages API: its body, and the beta features it
/// needs (`anthropic-beta`).
class ModelRequest {
  const ModelRequest(
    this.body, {
    this.betas = const [],
    this.errand = false,
    this.maxRetries,
  });

  final Map<String, Object?> body;
  final List<String> betas;

  /// A request made on the side (a summary, a title, a classifier): it is
  /// not the user waiting on an answer, so it gives up sooner.
  final bool errand;

  /// How many times it may be sent again; null takes the client's own,
  /// or the errand's shorter one.
  final int? maxRetries;

  String get model => body['model'] as String? ?? '';

  ModelRequest copyWith({
    Map<String, Object?>? body,
    List<String>? betas,
    bool? errand,
    int? maxRetries,
  }) => ModelRequest(
    body ?? this.body,
    betas: betas ?? this.betas,
    errand: errand ?? this.errand,
    maxRetries: maxRetries ?? this.maxRetries,
  );
}

/// What kind of failure an [ApiError] is: what to do about it differs.
enum ApiFailureKind {
  /// Too many requests (HTTP 429).
  rateLimit,

  /// The model is busy (HTTP 529).
  overloaded,

  /// The key is missing, wrong or not allowed.
  authentication,

  /// The conversation is longer than the model's window.
  contextTooLong,

  /// The account has no credit or its plan does not cover it.
  billing,

  /// The request itself was refused (a bad field, an unknown model).
  invalidRequest,

  /// The provider had a server error.
  server,

  /// The connection could not be made or was lost.
  network,

  /// The connection's certificate could not be verified.
  tls,

  /// The request was cancelled.
  cancelled,

  /// None of the above.
  unknown,
}

/// A request is about to be sent again after it failed.
class RetryInfo {
  const RetryInfo({
    required this.attempt,
    required this.maxRetries,
    required this.delay,
    this.status,
    this.message,
  });

  final int attempt;
  final int maxRetries;
  final Duration delay;
  final int? status;
  final String? message;
}

/// A request the API refused, or that could not reach it.
class ApiError implements Exception {
  const ApiError(
    this.message, {
    this.status,
    this.type,
    this.retryable = false,
    this.retryAfter,
    this.requestId,
  });

  final String message;
  final int? status;

  /// The API's own name for it: `overloaded_error`,
  /// `invalid_request_error`, …
  final String? type;
  final bool retryable;
  final Duration? retryAfter;
  final String? requestId;

  /// Whether the request is too long for the model's context.
  bool get promptTooLong =>
      status == 400 &&
      (message.contains('prompt is too long') ||
          message.contains('too many tokens') ||
          message.contains('context length') ||
          message.contains('context window'));

  /// Whether the key is missing, wrong or not allowed.
  bool get authentication =>
      status == 401 ||
      status == 403 ||
      type == 'authentication_error' ||
      type == 'permission_error';

  /// What kind of failure this is, in the order that changes what is to be
  /// done about it. A context overflow is not a request to fix and retry;
  /// an overload is not a key to check.
  ApiFailureKind get kind {
    if (promptTooLong) return ApiFailureKind.contextTooLong;
    if (authentication) return ApiFailureKind.authentication;
    if (status == 429 || type == 'rate_limit_error') {
      return ApiFailureKind.rateLimit;
    }
    if (status == 529 || type == 'overloaded_error') {
      return ApiFailureKind.overloaded;
    }
    if (status == 402 || type == 'billing_error') {
      return ApiFailureKind.billing;
    }
    if (status == 408 || type == 'timeout_error') {
      return ApiFailureKind.network;
    }
    if (status == 400 ||
        status == 404 ||
        status == 422 ||
        type == 'invalid_request_error' ||
        type == 'not_found_error') {
      return ApiFailureKind.invalidRequest;
    }
    if (status != null && status! >= 500) return ApiFailureKind.server;
    if (_certificate) return ApiFailureKind.tls;
    if (status == null) return ApiFailureKind.network;
    return ApiFailureKind.unknown;
  }

  /// A line saying what to do about it, for a person reading the turn's
  /// error. Empty when there is nothing useful to add.
  String get action => switch (kind) {
    ApiFailureKind.rateLimit =>
      'Wait a moment, then try again; the provider is rate limiting.',
    ApiFailureKind.overloaded =>
      'The model is overloaded: retry shortly, or use another model.',
    ApiFailureKind.authentication =>
      'Check the API key, or the provider set up in BaoCode.',
    ApiFailureKind.contextTooLong =>
      'The conversation is too long for this model: compact it or use a '
          'model with a larger context.',
    ApiFailureKind.billing =>
      'Check the account\'s credit or plan with the provider.',
    ApiFailureKind.invalidRequest =>
      'Check the model name and the request\'s settings.',
    ApiFailureKind.server => 'The provider had a server error: retry shortly.',
    ApiFailureKind.network => 'Check the network or proxy connection.',
    ApiFailureKind.tls =>
      'The connection\'s certificate could not be verified: check the proxy '
          'or the CA settings.',
    ApiFailureKind.cancelled => 'The request was cancelled.',
    ApiFailureKind.unknown => '',
  };

  bool get _certificate {
    final text = message.toLowerCase();
    return text.contains('certificate') ||
        text.contains('handshake') ||
        text.contains('certificateverifyfailed');
  }

  @override
  String toString() =>
      ['API Error', if (status != null) ' $status', ': $message'].join();
}

/// Where requests to the model go: the API, or a stand-in under test.
abstract interface class ModelClient {
  /// The events of [request]'s streamed answer, as the API sends them
  /// (`message_start`, `content_block_delta`, …). A request retried after
  /// it had begun to answer sends `{"type": "stream_restart"}` first: what
  /// came before it is void.
  Stream<Map<String, Object?>> stream(
    ModelRequest request, {
    CancelToken? cancel,
    void Function(RetryInfo info)? onRetry,
  });

  /// Whether this is Anthropic's own API (beta features are only asked of
  /// it).
  bool get firstParty;

  /// The models the API offers and what each can do (`GET /v1/models`);
  /// null when it cannot say.
  Future<List<Map<String, Object?>>?> models();
}
