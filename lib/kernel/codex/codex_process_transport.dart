import 'codex_process_transport_stub.dart'
    if (dart.library.io) 'codex_process_transport_io.dart';
export 'codex_process_transport_stub.dart'
    if (dart.library.io) 'codex_process_transport_io.dart';

/// Ends every codex process the app started, and waits for them: for when
/// the app quits.
Future<void> stopCodexProcesses() => CodexProcessTransport.stopAll();

/// Ends the codex processes an earlier run of the app left running (a
/// crash, a force quit, a hot restart); none on the web.
Future<void> reapCodexProcesses() => CodexProcessTransport.reapLeftovers();
