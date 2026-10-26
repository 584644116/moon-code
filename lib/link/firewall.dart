import 'package:flutter/foundation.dart';

import '../platform/app_platform.dart';
import 'firewall_stub.dart' if (dart.library.io) 'firewall_io.dart' as platform;

/// Whether the system's own firewall lets phones in on the port this
/// desktop listens on (Settings → Mobile).
///
/// A desktop that listens is not the same as a desktop that is reachable:
/// Windows' firewall lets an inbound connection through only where a rule
/// says so, and the rule an installer writes covers the network profile
/// the machine was on that day. Moved to another network — an office's
/// Private one, after a home's Public one — the port is listened on and
/// refused, and every path that stays inside the machine (a phone on the
/// same LAN is not one) still works, which hides it.
enum FirewallState {
  /// Not Windows, or the system would not say. Nothing is claimed.
  unknown,

  /// An inbound rule lets this app in, on the network the machine is on.
  open,

  /// Nothing does: a phone on the same LAN cannot reach this desktop.
  blocked,
}

/// What this machine's firewall says, and the one change that fixes it.
abstract final class LinkFirewall {
  /// Only Windows keeps a firewall this asks about; elsewhere the row that
  /// shows it is left out, and phones connect as they always did.
  static bool get supported => !kIsWeb && AppPlatform.isWindows;

  /// Whether [port] may be reached from another machine, now.
  static Future<FirewallState> check(int port) =>
      platform.checkFirewall(port);

  /// Adds the rules that let this app in on every profile, once the user
  /// has allowed it to an administrator's prompt. False when they did not,
  /// or the system refused: the caller says so, and offers the command.
  static Future<bool> allow(int port) => platform.allowThroughFirewall(port);

  /// The commands a user can run themselves, in an administrator's
  /// terminal, when the prompt was not theirs to answer.
  static List<String> commandsFor(int port) => [
    'netsh advfirewall firewall delete rule name="MoonCode Lab"',
    'netsh advfirewall firewall add rule name="MoonCode Lab" '
        'dir=in action=allow program="${_executable()}" '
        'enable=yes profile=domain,private,public protocol=TCP',
    'netsh advfirewall firewall add rule name="MoonCode Lab" '
        'dir=in action=allow program="${_executable()}" '
        'enable=yes profile=domain,private,public protocol=UDP',
  ];

  static String _executable() => platform.ownExecutable();
}
