import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:causal_robo_qc_app/dashboard_theme.dart';
import 'package:causal_robo_qc_app/metric_help.dart';
import 'package:causal_robo_qc_app/quality_dashboard_data.dart';
import 'package:causal_robo_qc_app/rpf_analysis_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const product = ProductRpf(
  id: 'P-001',
  rpfId: 1,
  isCompleted: true,
  grade: QualityGrade.review,
  workTimeSeconds: 12,
  retries: 1,
  majorAbnormality: '집기 재시도 1회',
  status: '완료',
  operatorInterventions: 0,
  errorEvents: 0,
  observations: [],
  causeCandidates: [],
  timeline: [],
  recommendations: [],
);
const savedResult = RpfAnalysisResult(
  anomalyScore: 0.3,
  inspectionRiskScore: 0.4,
  timeseriesAnomalyScore: null,
  syntheticModel: true,
);

class AnalysisSource implements RpfAnalysisDataSource {
  AnalysisSource(this.read);
  final Future<RpfAnalysisSnapshot> Function() read;
  int calls = 0;

  @override
  Future<RpfAnalysisSnapshot> loadAnalysis(int id) {
    calls++;
    return read();
  }
}

Widget panel(AnalysisSource? source) => MaterialApp(
      home: Scaffold(body: RpfAnalysisPanel(product: product, source: source)),
    );

void main() {
  testWidgets('loads saved scores immediately without an analysis button',
      (tester) async {
    final source = AnalysisSource(
        () async => const RpfAnalysisSnapshot(result: savedResult));
    await tester.pumpWidget(panel(source));
    await tester.pump();
    expect(find.text('AI 분석 실행'), findsNothing);
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('데이터 부족'), findsOneWidget);
    expect(find.text('※ 합성 데이터 기반 시험 모델'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 1);
  });

  testWidgets('briefly polls active analysis and displays the saved result',
      (tester) async {
    var snapshot = const RpfAnalysisSnapshot(isPending: true);
    final source = AnalysisSource(() async => snapshot);
    await tester.pumpWidget(panel(source));
    await tester.pump();
    expect(find.text('분석 중...'), findsNWidgets(3));
    snapshot = const RpfAnalysisSnapshot(result: savedResult);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('30%'), findsOneWidget);
    expect(find.text('분석 중...'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 2);
  });

  testWidgets('stops after five retries and quietly shows waiting',
      (tester) async {
    final source =
        AnalysisSource(() async => const RpfAnalysisSnapshot(isPending: true));
    await tester.pumpWidget(panel(source));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    }
    expect(find.text('분석 대기'), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 6);
  });

  testWidgets('does not poll existing unanalyzed records', (tester) async {
    final source = AnalysisSource(() async => const RpfAnalysisSnapshot());
    await tester.pumpWidget(panel(source));
    await tester.pump();
    expect(find.text('분석 대기'), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 1);
  });

  testWidgets('connection failure shows waiting without error details',
      (tester) async {
    final source =
        AnalysisSource(() async => throw Exception('connection refused'));
    await tester.pumpWidget(panel(source));
    await tester.pump();
    expect(find.text('분석 대기'), findsNWidgets(3));
    expect(find.textContaining('connection refused'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 1);
  });

  testWidgets('closing detail cancels retries and ignores an in-flight reply',
      (tester) async {
    final reply = Completer<RpfAnalysisSnapshot>();
    final source = AnalysisSource(() => reply.future);
    await tester.pumpWidget(panel(source));
    await tester.pumpWidget(const SizedBox());
    reply.complete(const RpfAnalysisSnapshot(isPending: true));
    await tester.pump(const Duration(seconds: 20));
    expect(source.calls, 1);
    expect(tester.takeException(), isNull);

    final pending =
        AnalysisSource(() async => const RpfAnalysisSnapshot(isPending: true));
    await tester.pumpWidget(panel(pending));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
    expect(pending.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('info tap shows help without opening its parent card',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 220,
      child: DashboardMetric(
          label: '공정 이탈률',
          helpTerm: '공정 이탈률',
          value: '10%',
          icon: Icons.analytics_outlined,
          onTap: () => opened = true),
    ))));
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text(metricDescriptions['공정 이탈률']!), findsOneWidget);
    expect(opened, isFalse);
  });

  testWidgets('mouse hover shows the metric explanation', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
      body: Center(child: MetricLabel('검사 위험도')),
    )));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byIcon(Icons.info_outline)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text(metricDescriptions['검사 위험도']!), findsOneWidget);
    await mouse.removePointer();
  });
}
