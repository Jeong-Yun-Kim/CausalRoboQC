import 'package:causal_robo_qc_app/dashboard_theme.dart';
import 'package:causal_robo_qc_app/quality_dashboard_data.dart';
import 'package:causal_robo_qc_app/quality_dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1440.0, 1280.0, 1024.0, 768.0, 390.0]) {
    testWidgets('quality overview and detail fit a ${width.toInt()}px viewport',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: DashboardTheme.light,
        home: const Scaffold(
          body: QualityDashboardPage(
            dataSource: MockQualityDashboardDataSource(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final product = find.text('P-127').first;
      await tester.ensureVisible(product);
      await tester.tap(product);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('규칙 기반 등급'), findsOneWidget);
      expect(find.text('판정 근거'), findsWidgets);
      expect(find.text('보조 분석'), findsOneWidget);
      expect(tester.getTopLeft(find.text('규칙 기반 등급')).dy,
          lessThan(tester.getTopLeft(find.text('보조 분석')).dy));
      final dialog = tester.getRect(find.byType(Dialog));
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }
}
