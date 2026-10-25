/// Codex is not on this machine, and what would put it there: said where a
/// session would start one, and to the history listing no sessions.
class CodexNotInstalled implements Exception {
  const CodexNotInstalled(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// Codex's side of the adapter (the Adaptee): JSON-RPC 2.0 with
/// `codex app-server` over stdio, one message per line.
abstract interface class CodexTransport {
  /// Responses (`id` + `result`), notifications (`method` + `params`) and
  /// server requests (`id` + `method` + `params`, e.g. approvals).
  Stream<Map<String, Object?>> get messages;

  /// Writes a request, or the response to a server request.
  void write(Map<String, Object?> message);

  void close();
}
