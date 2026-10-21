import 'session_export_model.dart';

/// No kept sessions on the web: nothing to export.
Future<SessionExport?> exportSession({
  required String sessionId,
  String? configDir,
  bool attachments = true,
  int maxFileBytes = sessionExportMaxFileBytes,
  int maxBytes = sessionExportMaxBytes,
}) async => null;

/// Writes [export] at [path]; nothing where there are no files (the web).
Future<void> writeSessionExport(SessionExport export, String path) async {}
