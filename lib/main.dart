import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const RunnerApp());
}

class RunnerApp extends StatelessWidget {
  const RunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: const ServerPage(),
    );
  }
}

/// First screen: the runner-server origin to sign in to.
///
/// Sign-in (device flow), the computer list and terminals come next, once the
/// Rust core is bridged in.
class ServerPage extends StatefulWidget {
  const ServerPage({super.key});

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  final _origin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _origin.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() => _error = validateOrigin(_origin.text));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Runner Remote')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('origin'),
              controller: _origin,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://runner.example.com',
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _submit, child: const Text('登录')),
          ],
        ),
      ),
    );
  }
}

/// Mirrors Runner's rule: HTTPS only, except plain HTTP on localhost for testing.
String? validateOrigin(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.host.isEmpty)
    return '请输入完整地址，例如 https://runner.example.com';
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1')) {
    return null;
  }
  return '只支持 HTTPS 地址';
}
