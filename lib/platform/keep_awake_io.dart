import 'dart:ffi';
import 'dart:io';

/// Windows: `SetThreadExecutionState`, which tells the system that this
/// thread has work, so the machine does not idle into sleep while an agent
/// runs. The screen may still turn off, which is what a long turn wants.
///
/// The state is held by the calling thread: Flutter's main isolate stays
/// on one, so the call that clears it finds it again. Elsewhere (macOS,
/// Linux) nothing is held; the setting says so where it cannot.
void setKeepAwake(bool keepAwake) {
  if (!Platform.isWindows) return;
  final setState = _setThreadExecutionState;
  if (setState == null) return;
  setState(_esContinuous | (keepAwake ? _esSystemRequired : 0));
}

/// `SetThreadExecutionState`, looked up once; null where the DLL or the
/// function is not there.
final int Function(int)? _setThreadExecutionState = () {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    return kernel32.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
      'SetThreadExecutionState',
    );
  } on Object {
    return null;
  }
}();

/// The state stays until it is cleared: without this a call would only ask
/// for the time given it.
const _esContinuous = 0x80000000;

/// The system itself, not only the screen.
const _esSystemRequired = 0x00000001;
