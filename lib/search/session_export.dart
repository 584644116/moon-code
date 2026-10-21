// A session as a ZIP to keep or send (see session_export_io.dart): its
// transcript, its subagents' and, when asked, the files kept beside it.

export 'session_export_model.dart';
export 'session_export_stub.dart'
    if (dart.library.io) 'session_export_io.dart';
