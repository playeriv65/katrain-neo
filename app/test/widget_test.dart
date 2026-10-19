import 'package:flutter_test/flutter_test.dart';
import 'package:katrain_neo/main.dart';

void main() {
  testWidgets('app starts', (tester) async {
    await tester.pumpWidget(const KaTrainNeoApp());
    expect(find.textContaining('KaTrain Neo'), findsOneWidget);
  });
}
