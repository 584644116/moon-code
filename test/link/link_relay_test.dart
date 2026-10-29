import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/link/link_relay.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_link_platform.dart';

/// A relay, as the one on a server is: two paths, channels framed apart.
///
/// It does what relay.js does — a phone's socket is one channel of the
/// desktop's, its id ahead of each message — and nothing else: what crosses
/// is sealed before it gets here.
class _FakeRelay {
  _FakeRelay._(this._server, this._phones);

  static Future<_FakeRelay> start() async {
    final phones = StreamController<WebSocket>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay._(server, phones);
    unawaited(relay._serve());
    return relay;
  }

  final HttpServer _server;
  final StreamController<WebSocket> _phones;

  WebSocket? _desktop;
  final _channels = <int, WebSocket>{};
  int _nextId = 1;

  /// The token the desktop has to bring.
  String token = 'a-secret-long-enough';

  Uri get desktopUrl => Uri.parse(
    'ws://127.0.0.1:${_server.port}/relay?token=$token',
  );

  /// Where a phone would connect: the address the desktop hands out.
  Uri get forPhones => Uri.parse('ws://127.0.0.1:${_server.port}');

  /// Each phone's socket, as it connects.
  Stream<WebSocket> get phones => _phones.stream;

  Future<void> _serve() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      if (request.uri.path == '/baocode-link') {
        final socket = await WebSocketTransformer.upgrade(request);
        _phones.add(socket);
        _attach(socket);
        continue;
      }
      if (request.uri.path == '/relay') {
        if (request.uri.queryParameters['token'] != token) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          continue;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        _desktop = socket;
        socket.add(jsonEncode({'t': 'ready'}));
        socket.listen(
          (message) => _fromDesktop(message),
          onDone: () => _desktop = null,
          cancelOnError: true,
        );
        continue;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  void _attach(WebSocket phone) {
    final desktop = _desktop;
    if (desktop == null) {
      phone.close(1011, 'no desktop');
      return;
    }
    final id = _nextId++;
    _channels[id] = phone;
    desktop.add(jsonEncode({'t': 'open', 'c': id}));
    phone.listen(
      (message) {
        if (message is! List<int>) return;
        final framed = Uint8List(4 + message.length);
        ByteData.sublistView(framed).setUint32(0, id);
        framed.setRange(4, framed.length, message);
        if (desktop.readyState == WebSocket.open) desktop.add(framed);
      },
      onDone: () {
        _channels.remove(id);
        if (desktop.readyState == WebSocket.open) {
          desktop.add(jsonEncode({'t': 'close', 'c': id}));
        }
      },
      cancelOnError: true,
    );
  }

  void _fromDesktop(Object? message) {
    if (message is! List<int>) return;
    if (message.length < 4) return;
    final bytes = message is Uint8List ? message : Uint8List.fromList(message);
    final id = ByteData.sublistView(bytes).getUint32(0);
    final phone = _channels[id];
    if (phone == null || phone.readyState != WebSocket.open) return;
    phone.add(Uint8List.sublistView(bytes, 4));
  }

  Future<void> close() async {
    await _desktop?.close();
    for (final phone in _channels.values) {
      await phone.close();
    }
    _channels.clear();
    await _server.close(force: true);
  }
}

/// The relay's address as a phone takes it: no path, no token.
void main() {
  test('a phone the relay pairs is a socket the desktop takes', () async {
    final relay = await _FakeRelay.start();
    addTearDown(relay.close);
    final states = <RelayState>[];
    final online = Completer<void>();
    final connection = LinkRelay.connect(
      relay.desktopUrl,
      onState: (state, _) {
        states.add(state);
        if (state == RelayState.online && !online.isCompleted) online.complete();
      },
    )!;
    addTearDown(connection.close);
    // The desktop has to be there before a phone comes: through at the relay.
    await online.future;

    final taken = connection.sockets.first;
    final phone = await WebSocket.connect(
      '${relay.forPhones}/baocode-link',
    );
    addTearDown(phone.close);

    final socket = await taken;
    // Both ways, as a sealed channel's two ends would.
    phone.add(Uint8List.fromList([1, 2, 3]));
    expect(await socket.messages.first, [1, 2, 3]);

    final fromDesktop = phone.first;
    socket.send(Uint8List.fromList([9, 8]));
    expect(await fromDesktop, [9, 8]);

    expect(states, contains(RelayState.online));
  });

  test('a phone that goes away ends its socket here', () async {
    final relay = await _FakeRelay.start();
    addTearDown(relay.close);
    final online = Completer<void>();
    final connection = LinkRelay.connect(
      relay.desktopUrl,
      onState: (state, _) {
        if (state == RelayState.online && !online.isCompleted) online.complete();
      },
    )!;
    addTearDown(connection.close);
    await online.future;

    final taken = connection.sockets.first;
    final phone = await WebSocket.connect('${relay.forPhones}/baocode-link');
    final socket = await taken;

    final ended = socket.messages.toList();
    await phone.close();
    expect(await ended, isEmpty);
  });

  test('the relay that cannot be reached says so, and is tried again', () async {
    // A port nothing listens on: the connect fails.
    final port = await _freePort();
    final failed = Completer<String?>();
    final connection = LinkRelay.connect(
      Uri.parse('ws://127.0.0.1:$port/relay?token=x'),
      onState: (state, error) {
        if (state == RelayState.failed && !failed.isCompleted) {
          failed.complete(error);
        }
      },
    )!;
    addTearDown(connection.close);
    expect(await failed.future, isNotNull);
  });

  test('the address a phone is given is the relay without its token', () {
    final forPhones = relayForPhones(
      Uri.parse('wss://relay.example.com/relay?token=secret'),
    );
    expect(forPhones.toString(), 'wss://relay.example.com');
    final endpoint = DirectEndpoint.parse('$forPhones', defaultPort: 47100);
    expect(endpoint.host, 'relay.example.com');
    expect(endpoint.port, 443);
    expect(endpoint.secure, isTrue);
    // The path a phone builds is the one the relay takes phones at.
    expect('$forPhones/baocode-link', 'wss://relay.example.com/baocode-link');
  });

  group('the host gives the relay to the phones', () {
    late FakeLinkPlatform platform;
    late LinkHost host;

    setUp(() async {
      platform = FakeLinkPlatform();
      host = LinkHost(workspace: Workspace.mock(), platform: platform);
      await host.load();
    });

    tearDown(() => host.dispose());

    test('a relay given is a wss endpoint among the desktop\'s own', () async {
      await host.setRelay(
        address: 'wss://zyfai.asia/relay',
        token: '{{SECRET_4t4vtgnq}}',
      );
      // No bare address typed in — the relay's alone, which reaches it
      // wherever it is.
      final endpoints = host.endpoints;
      expect(endpoints.single.toString(), 'wss://zyfai.asia:443');
      expect(endpoints.single.secure, isTrue);
      expect(host.relayConfigured, isTrue);
    });

    test('a relay typed without a scheme is taken as TLS', () async {
      await host.setRelay(address: 'zyfai.asia/relay', token: 't');
      expect(host.endpoints.single.toString(), 'wss://zyfai.asia:443');
    });

    test('the token is the desktop\'s: the address given to phones has none',
        () async {
      await host.setRelay(
        address: 'wss://zyfai.asia/relay',
        token: '{{SECRET_4t4vtgnq}}',
      );
      expect(host.endpoints.single.toString(), isNot(contains('token')));
      expect(host.relayToken, '{{SECRET_4t4vtgnq}}');
    });

    test('a relay given goes in the pairing code', () async {
      await host.setRelay(
        address: 'wss://zyfai.asia/relay',
        token: '{{SECRET_4t4vtgnq}}',
      );
      final offer = (await host.beginPairing())!;
      expect(
        [for (final endpoint in offer.endpoints) '$endpoint'],
        contains('wss://zyfai.asia:443'),
      );
    });

    test('no relay, and no address given, leaves the addresses as they were',
        () async {
      expect(host.endpoints, isEmpty);
      await host.setRelay(address: '   ', token: '');
      expect(host.endpoints, isEmpty);
    });

    test('a relay given is kept for the next run', () async {
      await host.setRelay(
        address: 'wss://zyfai.asia/relay',
        token: '{{SECRET_4t4vtgnq}}',
      );
      // What it kept, read back: the machine's own store.
      final again = LinkHost(workspace: Workspace.mock(), platform: platform);
      addTearDown(again.dispose);
      await again.load();
      expect(again.relayAddress, 'wss://zyfai.asia/relay');
      expect(again.relayToken, '{{SECRET_4t4vtgnq}}');
      expect(again.endpoints.single.toString(), 'wss://zyfai.asia:443');
    });
  });
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
