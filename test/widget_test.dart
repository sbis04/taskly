import 'package:flutter_test/flutter_test.dart';

import 'package:taskly/main.dart';

void main() {
  testWidgets('App renders empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const TasklyApp());
    expect(find.text('Taskly'), findsOneWidget);
    expect(find.text('No tasks yet'), findsOneWidget);
  });
}
