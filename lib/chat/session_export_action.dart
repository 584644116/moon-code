import '../search/session_export.dart';
import '../workspace/window_controls.dart';

/// Asks where to save the session [sessionId] — its transcript, its
/// subagents' and the files kept beside it, as a ZIP — and writes it
/// there. The path saved to, or null when it was cancelled or could not be
/// found.
Future<String?> exportSessionWithPanel({
  required String sessionId,
  required String title,
}) async {
  if (!WindowControls.canPickFiles) return null;
  final export = await exportSession(sessionId: sessionId);
  if (export == null) return null;
  final name = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '-')
      .trim();
  final path = await WindowControls.pickSaveFile(
    name: '${name.isEmpty ? sessionId : name}.zip',
  );
  if (path == null) return null;
  await writeSessionExport(export, path);
  return path;
}
