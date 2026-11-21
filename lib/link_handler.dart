import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core/links.dart';
import 'core/store.dart';
import 'pages/computers.dart';
import 'pages/sign_in.dart';
import 'services.dart';

/// Acts on [links] (see `core/links.dart`) over whatever page is showing.
///
/// Sits between [Services] and the app, and reaches pages through [navigator].
/// Links are handled one at a time, in the order they came.
class LinkHandler extends StatefulWidget {
  const LinkHandler({
    super.key,
    required this.links,
    required this.navigator,
    required this.child,
  });

  final Stream<Uri> links;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<LinkHandler> createState() => _LinkHandlerState();
}

class _LinkHandlerState extends State<LinkHandler> {
  StreamSubscription<Uri>? _subscription;
  var _queue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _subscription = widget.links.listen(_onLink);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onLink(Uri uri) {
    final link = AppLink.parse(uri);
    if (link == null) return;
    _queue = _queue.then((_) => _handle(link)).catchError((Object _) {});
  }

  /// A context under the navigator, for pushing pages and showing dialogs.
  Future<BuildContext?> _pageContext() async {
    // A link that opened the app comes before the first frame.
    for (var frame = 0; frame < 10; frame++) {
      final context = widget.navigator.currentState?.overlay?.context;
      if (context != null) return context;
      await WidgetsBinding.instance.endOfFrame;
    }
    return null;
  }

  Future<void> _handle(AppLink link) async {
    final store = Services.of(context).store;
    final page = await _pageContext();
    if (page == null || !page.mounted) return;
    final navigator = Navigator.of(page);
    switch (link) {
      case AddAccountLink(:final server):
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => ServerPage(initialOrigin: server),
            ),
          ),
        );
      case OpenComputerLink(
        :final server,
        :final computer,
        :final session,
        :final username,
      ):
        final account = (await store.accounts())
            .where(
              (a) =>
                  sameOrigin(a.origin, server) &&
                  (username == null || a.username == username),
            )
            .firstOrNull;
        if (!page.mounted) return;
        if (account == null) {
          final who = username == null ? '' : ' $username';
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => ServerPage(
                  initialOrigin: server,
                  notice: '要打开这台电脑，请先登录$who。',
                ),
              ),
            ),
          );
          return;
        }
        // The computer opens over the computer list, not over another computer.
        navigator.popUntil((route) => route.isFirst);
        if (computer == null) return;
        // Not awaited: it lasts as long as the computer stays open.
        unawaited(
          openComputerById(page, account, computer, session: session),
        );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
