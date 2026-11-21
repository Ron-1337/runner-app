import 'package:app_links/app_links.dart';
import 'package:material_ui/material_ui.dart';

import 'core/core.dart';
import 'core/store.dart';
import 'link_handler.dart';
import 'pages/computers.dart';
import 'pages/sign_in.dart';
import 'services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Learns the phone's model early, so pairing names it even when the app
  // opens straight to the computers.
  deviceInfo();
  runApp(
    RunnerApp(
      core: NativeCore.instance,
      store: Store(),
      // `runner-remote://` links, the one that opened the app first.
      links: AppLinks().uriLinkStream,
    ),
  );
}

class RunnerApp extends StatefulWidget {
  const RunnerApp({
    super.key,
    required this.core,
    required this.store,
    this.links = const Stream.empty(),
  });

  final Core core;
  final Store store;
  final Stream<Uri> links;

  @override
  State<RunnerApp> createState() => _RunnerAppState();
}

class _RunnerAppState extends State<RunnerApp> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return Services(
      core: widget.core,
      store: widget.store,
      child: LinkHandler(
        links: widget.links,
        navigator: _navigator,
        child: MaterialApp(
          navigatorKey: _navigator,
          title: 'Runner Remote',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo,
              brightness: Brightness.dark,
            ),
          ),
          home: const StartPage(),
        ),
      ),
    );
  }
}

/// Goes to the computer list when this phone has an account.
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  Future<List<Account>>? _accounts;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accounts ??= Services.of(context).store.accounts();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Account>>(
      future: _accounts,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final accounts = snapshot.data ?? const [];
        return accounts.isEmpty ? const ServerPage() : const ComputersPage();
      },
    );
  }
}
