import 'package:material_ui/material_ui.dart';

import 'core/core.dart';
import 'core/store.dart';
import 'pages/computers.dart';
import 'pages/sign_in.dart';
import 'services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(RunnerApp(core: NativeCore.instance, store: Store()));
}

class RunnerApp extends StatelessWidget {
  const RunnerApp({super.key, required this.core, required this.store});

  final Core core;
  final Store store;

  @override
  Widget build(BuildContext context) {
    return Services(
      core: core,
      store: store,
      child: MaterialApp(
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
    );
  }
}

/// Goes to the computer list when this phone is already signed in.
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  Future<Account?>? _account;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _account ??= Services.of(context).store.account();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Account?>(
      future: _account,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final account = snapshot.data;
        return account == null
            ? const ServerPage()
            : ComputersPage(account: account);
      },
    );
  }
}
