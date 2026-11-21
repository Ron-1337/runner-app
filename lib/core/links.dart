/// Links into the app: `runner-remote://<action>?<parameters>`.
///
/// They arrive from other apps and web pages through the URL scheme; a tapped
/// notification will carry the same kind of link, so everything the app can be
/// asked to show from outside goes through [AppLink.parse].
///
/// | Link | Does |
/// | --- | --- |
/// | `runner-remote://add?server=https://runner.example.com` | Signs in to another account, the server filled in |
/// | `runner-remote://open?server=…[&user=<name>]` | Shows the computer list |
/// | `runner-remote://open?server=…&computer=<id>[&session=<id>][&user=<name>]` | Opens a computer, and a session on it |
library;

const linkScheme = 'runner-remote';

/// An HTTPS or HTTP server address; HTTP is allowed after a warning (see
/// [isPlainHttp]).
String? validateOrigin(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.host.isEmpty) {
    return '请输入完整地址，例如 https://runner.example.com';
  }
  if (uri.scheme == 'https' || uri.scheme == 'http') return null;
  return '只支持 HTTPS 或 HTTP 地址';
}

/// Whether [origin] is unencrypted HTTP, which the person confirms first.
bool isPlainHttp(String origin) =>
    Uri.tryParse(origin.trim())?.scheme == 'http';

sealed class AppLink {
  const AppLink();

  /// The link [uri] stands for, or null when it is not one this app knows.
  static AppLink? parse(Uri uri) {
    if (uri.scheme.toLowerCase() != linkScheme) return null;
    // `runner-remote://add` puts the action in the host; also accept `runner-remote:/add`.
    final action = uri.host.isNotEmpty
        ? uri.host.toLowerCase()
        : uri.pathSegments.firstOrNull?.toLowerCase();
    final query = uri.queryParameters;
    final server = _nonEmpty(query['server']);
    switch (action) {
      case 'add':
        return AddAccountLink(server: server);
      case 'open':
        if (server == null || validateOrigin(server) != null) return null;
        return OpenComputerLink(
          server: server,
          computer: _nonEmpty(query['computer']),
          session: _nonEmpty(query['session']),
          username: _nonEmpty(query['user']),
        );
    }
    return null;
  }

  static String? _nonEmpty(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }
}

/// Sign in to another account; [server] fills in the address when given.
class AddAccountLink extends AppLink {
  const AddAccountLink({this.server});
  final String? server;
}

/// Open [computer] under the account on [server], as [username] when the phone
/// has several accounts there, and [session] on it; with no [computer], just
/// the computer list. Notifications carry this link.
class OpenComputerLink extends AppLink {
  const OpenComputerLink({
    required this.server,
    this.computer,
    this.session,
    this.username,
  });

  final String server;
  final String? computer;
  final String? session;
  final String? username;
}
