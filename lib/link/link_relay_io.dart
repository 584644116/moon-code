import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';

import 'link_relay.dart';

bool get relaySupported => true;

LinkRelayConnection? connectRelay(Uri url, {RelayStateChanged? onState}) =>
    _RelayConnection(url, onState: onState);

/// How many bytes a channel's id takes ahead of each message it carries.
const _header = 4;

/// A channel the relay keeps: one phone, from its socket to this desktop's.
///
/// Its [messages] end when the relay says the channel is gone, or the
/// desktop's own connection to the relay breaks — both leave the phone
/// nothing to be reached through.
class _RelaySocket implements LinkSocket {
  _RelaySocket(this._id, this._send, this._onClose) {
    _incoming = StreamController<Uint8List>();
  }

  final int _id;
  final void Function(int id, Uint8List message) _send;
  final void Function(_RelaySocket socket) _onClose;

  late final StreamController<Uint8List> _incoming;
  bool _closed = false;

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  void send(Uint8List message) {
    if (_closed) return;
    _send(_id, message);
  }

  /// What came from the phone.
  void _receive(Uint8List message) {
    if (!_closed) _incoming.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) await _incoming.close();
    _onClose(this);
  }
}

/// This desktop at a relay: one WebSocket out, each phone a channel on it.
///
/// The relay says, as JSON text, that the desktop is the one (`ready`), and
/// of each phone that attaches (`open`) or leaves (`close`); data goes as
/// binary, a channel's id ahead of what the phone said. Nothing here reads
/// what it carries: the two ends sealed it (see [SecureChannel]).
class _RelayConnection implements LinkRelayConnection {
  _RelayConnection(this._url, {RelayStateChanged? onState})
    // ignore: prefer_initializing_formals
    : _onState = onState {
    unawaited(_run());
  }

  final Uri _url;
  final RelayStateChanged? _onState;

  final _sockets = StreamController<LinkSocket>.broadcast();
  final Map<int, _RelaySocket> _channels = {};

  WebSocket? _socket;
  bool _closed = false;
  int _attempt = 0;
  Timer? _retryTimer;

  @override
  Stream<LinkSocket> get sockets => _sockets.stream;

  void _state(RelayState state, [String? error]) => _onState?.call(state, error);

  Future<void> _run() async {
    if (_closed) return;
    _state(RelayState.connecting);
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        _url.toString(),
      ).timeout(const Duration(seconds: 15));
    } on Object catch (error) {
      _state(RelayState.failed, '$error');
      _retry();
      return;
    }
    if (_closed) {
      unawaited(socket.close());
      return;
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 15);
    // A half-open connection under NAT looks open forever: a ping that is
    // not answered is what ends it, and the retry that follows.
    socket.listen(
      _receive,
      onError: (Object error) => _lost('$error'),
      onDone: () => _lost('the relay closed the connection'),
      cancelOnError: true,
    );
  }

  void _receive(Object? message) {
    if (message is List<int>) {
      final bytes = message is Uint8List
          ? message
          : Uint8List.fromList(message);
      if (bytes.length < _header) return;
      final id = ByteData.sublistView(bytes).getUint32(0);
      _channels[id]?._receive(
        Uint8List.sublistView(bytes, _header),
      );
      return;
    }
    if (message is! String) return;
    final Object? json;
    try {
      json = jsonDecode(message);
    } on FormatException {
      return;
    }
    switch (json) {
      case {'t': 'ready'}:
        _attempt = 0;
        _state(RelayState.online);
      case {'t': 'open', 'c': final int id}:
        // A phone attached: its socket here is the desktop's to take.
        if (_closed || _channels.containsKey(id)) return;
        final relayed = _RelaySocket(id, _sendData, _forget);
        _channels[id] = relayed;
        if (!_sockets.isClosed) _sockets.add(relayed);
      case {'t': 'close', 'c': final int id}:
        unawaited(_channels.remove(id)?.close());
    }
  }

  void _sendData(int id, Uint8List message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    final framed = Uint8List(_header + message.length);
    ByteData.sublistView(framed).setUint32(0, id);
    framed.setRange(_header, framed.length, message);
    socket.add(framed);
  }

  /// A channel is done with: the desktop closed it, not the relay. One the
  /// relay closed itself is already out of [_channels], and is not told
  /// back what it said.
  void _forget(_RelaySocket socket) {
    if (_channels.remove(socket._id) == null) return;
    final open = _socket;
    if (open == null || open.readyState != WebSocket.open) return;
    open.add(jsonEncode({'t': 'close', 'c': socket._id}));
  }

  /// The connection to the relay broke: every channel goes with it, and
  /// another try follows.
  void _lost(String why) {
    if (_closed) return;
    _socket = null;
    final channels = [..._channels.values];
    _channels.clear();
    for (final channel in channels) {
      unawaited(channel.close());
    }
    _state(RelayState.failed, why);
    _retry();
  }

  /// Another try, further away each time it fails: the relay being down is
  /// not this desktop's to fix, and asking again every second only adds to
  /// what it has to answer.
  void _retry() {
    if (_closed) return;
    _retryTimer?.cancel();
    final seconds = switch (_attempt) {
      <= 0 => 2,
      1 => 5,
      2 => 10,
      3 => 20,
      _ => 30,
    };
    _attempt++;
    _retryTimer = Timer(Duration(seconds: seconds), () => unawaited(_run()));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    final channels = [..._channels.values];
    _channels.clear();
    for (final channel in channels) {
      unawaited(channel.close());
    }
    if (!_sockets.isClosed) await _sockets.close();
    final socket = _socket;
    _socket = null;
    if (socket != null) await socket.close().catchError((Object _) => null);
    _state(RelayState.off);
  }
}
