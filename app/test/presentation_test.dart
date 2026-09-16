import 'dart:convert';

import 'package:causal_robo_qc_app/copilot_chart.dart';
import 'package:causal_robo_qc_app/dashboard_theme.dart';
import 'package:causal_robo_qc_app/quality_dashboard_api.dart';
import 'package:causal_robo_qc_app/quality_dashboard_data.dart';
import 'package:causal_robo_qc_app/rpf_analysis_overview.dart';
import 'package:causal_robo_qc_app/rpf_analysis_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> record(int index) => {
      'id': index,
      'product_id': 'RPF-${index.toString().padLeft(3, '0')}',
      'product_group': 'A',
      'grade': 'review',
      'grade_reasons': ['집기 재시도 1회'],
      'status': 'completed',
      'work_time_ms': 12000,
      'retry_count': 1,
      'error_count': 0,
      'operator_interventions': 0,
      'analysis_result': {
        'anomaly_score': .125,
        'inspection_risk_score': .25,
        'timeseries_anomaly_score': .375,
        'synthetic_model': true,
      },
      'presentation': {
        'stages': [
          {'name': 'PICK', 'duration_ms': 950}
        ],
        'recommended_checks': ['그리퍼 파지 위치를 확인하세요.'],
        'report_draft': '품질보고서 초안 · RPF-001\n공정 이상도: 0.125',
      },
    };

final records = [for (var index = 30; index >= 1; index--) record(index)];

MockClient connection() => MockClient((request) async => http.Response(
    jsonEncode(request.url.path == '/api/rpf' ? {'items': records} : record(1)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'}));

void assertNoPresentationLabels(WidgetTester tester) {
  final visible = tester
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .join('\n');
  expect(
      RegExp(r'데모|합성|테스트|demo|synthetic', caseSensitive: false)
          .hasMatch(visible),
      isFalse);
}

void main() {
  test('quality API retains three stored scores and presentation evidence',
      () async {
    final client = connection();
    addTearDown(client.close);
    await http.runWithClient(() async {
      const source = ApiQualityDashboardDataSource();
      final data = await source.load();
      expect(data.products.length, 30);
      expect(data.products.last.id, 'RPF-001');
      expect(data.products.first.analysis!.timeseriesAnomalyScore, .375);
      expect(data.products.first.grade, QualityGrade.review);
      final detail = await source.loadAnalysis(1);
      expect(detail.stages.single.detail, '0.950초');
      expect(detail.recommendedChecks.single, contains('그리퍼'));
      expect(detail.reportDraft, contains('공정 이상도: 0.125'));
    }, () => client);
  });

  for (final width in [1440.0, 390.0]) {
    testWidgets('30 stored score rows, chart and averages fit $width',
        (tester) async {
      final client = connection();
      addTearDown(client.close);
      final data = await http.runWithClient(
          () => const ApiQualityDashboardDataSource().load(), () => client);
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          theme: DashboardTheme.light,
          home: Scaffold(
              body: SingleChildScrollView(
                  child: RpfAnalysisOverview(products: data.products)))));
      await tester.pumpAndSettle();
      expect(find.text('분석 결과 30 / 30건'), findsOneWidget);
      for (final value in ['12.5%', '25.0%', '37.5%']) {
        expect(find.text(value), findsOneWidget);
      }
      final chart =
          tester.widget<CopilotChartView>(find.byType(CopilotChartView)).chart;
      expect(chart.labels.first, 'RPF-001');
      expect(chart.labels.last, 'RPF-030');
      expect(chart.series.length, 3);
      expect(chart.series.last.values, List.filled(30, 37.5));
      await tester.ensureVisible(find.text('분석값 표 보기'));
      await tester.tap(find.text('분석값 표 보기'));
      await tester.pumpAndSettle();
      expect(find.text('RPF-001'), findsOneWidget);
      expect(find.text('RPF-030'), findsOneWidget);
      assertNoPresentationLabels(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'detail shows saved scores, stages, checks and report without provenance badges',
      (tester) async {
    final client = connection();
    addTearDown(client.close);
    await http.runWithClient(() async {
      const source = ApiQualityDashboardDataSource();
      final data = await source.load();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: RpfAnalysisPanel(
                      product: data.products.last, source: source)))));
      await tester.pumpAndSettle();
      expect(find.text('38%'), findsOneWidget);
      expect(find.text('PICK'), findsOneWidget);
      expect(find.text('0.950초'), findsOneWidget);
      expect(find.textContaining('그리퍼 파지'), findsOneWidget);
      await tester.ensureVisible(find.text('품질보고서 초안'));
      await tester.tap(find.text('품질보고서 초안'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.text('보고서 복사'), findsOneWidget);
      assertNoPresentationLabels(tester);
      expect(tester.takeException(), isNull);
    }, () => client);
  });
}
