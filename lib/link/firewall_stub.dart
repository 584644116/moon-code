import 'firewall.dart';

/// The web's, and every platform without a firewall this asks about:
/// nothing is known, nothing is changed.
Future<FirewallState> checkFirewall(int port) async => FirewallState.unknown;

Future<bool> allowThroughFirewall(int port) async => false;

String ownExecutable() => '';
