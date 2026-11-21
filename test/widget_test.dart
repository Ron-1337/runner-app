import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runner_app/main.dart';

void main() {
  test('validateOrigin accepts HTTPS and local HTTP only', () {
    expect(validateOrigin('https://runner.example.com'), isNull);
    expect(validateOrigin('http://localhost:8080'), isNull);
    expect(validateOrigin('http://127.0.0.1:8080'), isNull);
    expect(validateOrigin('http://runner.example.com'), isNotNull);
    expect(validateOrigin('runner.example.com'), isNotNull);
  });

  testWidgets('shows an error for a non-HTTPS origin', (tester) async {
    await tester.pumpWidget(const RunnerApp());
    await tester.enterText(
      find.byKey(const Key('origin')),
      'http://example.com',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.text('只支持 HTTPS 地址'), findsOneWidget);
  });
}
