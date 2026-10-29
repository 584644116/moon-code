import 'link_relay.dart';

/// The web's: no relay, and nothing asks for one.
bool get relaySupported => false;

LinkRelayConnection? connectRelay(Uri url, {RelayStateChanged? onState}) =>
    null;
