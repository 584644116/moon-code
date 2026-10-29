import 'package:bao_link/bao_link.dart';

import 'link_relay_stub.dart'
    if (dart.library.io) 'link_relay_io.dart'
    as platform;

/// Where this desktop's end of a relay stands.
enum RelayState {
  /// Not asked for, or no relay on this platform.
  off,

  /// Reaching out to it.
  connecting,

  /// Through to it: phones that attach are taken as they come.
  online,

  /// It could not be reached, or the connection broke. Another try follows.
  failed,
}

/// Told when the relay's state changes: the new one, and why it failed.
typedef RelayStateChanged = void Function(RelayState state, String? error);

/// This desktop's end of a relay.
///
/// A phone reaches the relay at [relayForPhones] as though the desktop were
/// there — a `wss://` address among its own — and the relay pairs it with
/// this connection. What crosses is sealed already (see [SecureChannel] for
/// where the keys come from): the relay carries it and reads none of it.
abstract interface class LinkRelayConnection {
  /// Each phone's socket, as the relay pairs it.
  Stream<LinkSocket> get sockets;

  /// Stops, and ends every channel.
  Future<void> close();
}

/// The relay's address as a phone takes it: the desktop's own, without the
/// token only the desktop holds.
///
/// `wss://example.com/relay?token=…` → `wss://example.com`, which parses as
/// a `wss://` [DirectEndpoint] on 443 — a phone dials
/// `wss://example.com/baocode-link` and the relay hands it over.
Uri relayForPhones(Uri relay) => Uri(
  scheme: relay.scheme,
  userInfo: relay.userInfo,
  host: relay.host,
  port: relay.hasPort ? relay.port : null,
);

/// The relay this desktop reaches out to, or null where there is none to
/// be had (the web).
abstract final class LinkRelay {
  /// Whether a relay can be reached from this build at all.
  static bool get supported => platform.relaySupported;

  /// Reaches out to [url] — the relay's, token and all — and keeps at it
  /// while it can. Null where there is no relay to be had.
  static LinkRelayConnection? connect(Uri url, {RelayStateChanged? onState}) =>
      platform.connectRelay(_scheme(url), onState: onState);

  /// `https://` and `http://` are written by users as they would in a
  /// browser; the socket takes `wss://` and `ws://`.
  static Uri _scheme(Uri url) => switch (url.scheme) {
    '' => url.replace(scheme: 'wss'),
    'https' => url.replace(scheme: 'wss'),
    'http' => url.replace(scheme: 'ws'),
    _ => url,
  };
}
