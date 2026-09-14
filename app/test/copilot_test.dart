import 'dart:async';
import 'dart:convert';

import 'package:causal_robo_qc_app/copilot_api.dart';
import 'package:causal_robo_qc_app/copilot_overlay.dart';
import 'package:causal_robo_qc_app/dashboard_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FixtureSource implements CopilotDataSource {
  FixtureSource(this.response);
  final CopilotResponse response;
  final questions = <String>[];
  @override
  Future<CopilotResponse> ask(String question) async {
    questions.add(question);
    return response;
  }
}

class PendingSource implements CopilotDataSource {
  final pending = Completer<CopilotResponse>();
  @override
  Future<CopilotResponse> ask(String question) => pending.future;
}

Widget shell(CopilotDataSource source) => MaterialApp(
      theme: DashboardTheme.light,
      home: StatefulBuilder(builder: (context, setState) {
        return CopilotOverlay(
            dataSource: source,
            child: Scaffold(
                body: TextButton(
                    onPressed: () => setState(() {}),
                    child: const Text('기존 페이지'))));
      }),
    );

Future<void> ask(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('copilot-input')), text);
  await tester.tap(find.byKey(const ValueKey('copilot-send')));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [1440.0, 1280.0, 1024.0, 768.0, 390.0]) {
    testWidgets('floating panel, close, state and bounds at $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = FixtureSource(
          const CopilotResponse(answer: '저장된 제품의 설명입니다.', demoData: true));
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(shell(source));
      expect(find.byTooltip('AI 코파일럿'), findsOneWidget);
      final button =
          tester.getRect(find.byKey(const ValueKey('copilot-toggle')));
      expect(button.width, 48);
      expect(button.right, width - (width < 600 ? 8 : 24));
      await tester.tap(find.byTooltip('AI 코파일럿'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byKey(const ValueKey('copilot-panel')));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(width));
      expect(panel.bottom, lessThanOrEqualTo(844));
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.width, width < 600 ? width - 16 : 420);
      expect(
          tester
              .getSemantics(find.byKey(const ValueKey('copilot-input')))
          .rect
          .height,
          lessThan(150));
      semantics.dispose();
      expect(
          find.descendant(
              of: find.byType(CopilotOverlay),
              matching: find.byType(ModalBarrier)),
          findsNothing);
      await ask(tester, '제품 설명');
      expect(find.text('저장된 제품의 설명입니다.'), findsOneWidget);
      expect(find.text('데모 데이터 기반'), findsOneWidget);
      await tester.tap(find.byTooltip('코파일럿 닫기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('copilot-panel')), findsNothing);
      await tester.tap(find.text('기존 페이지'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('AI 코파일럿'));
      await tester.pumpAndSettle();
      expect(find.text('저장된 제품의 설명입니다.'), findsOneWidget);
      expect(source.questions, ['제품 설명']);
      expect(tester.takeException(), isNull);
    });
  }

  for (final type in ['bar', 'line']) {
    testWidgets('renders compact table and $type chart including null gaps',
        (tester) async {
      final source = FixtureSource(CopilotResponse(
          answer: 'DB 집계 결과입니다.',
          table: const CopilotTable([
            '제품군',
            '작업시간 (s)'
          ], [
            ['A', 2.25],
            ['B', null],
            ['C', 3.75]
          ]),
          chart: CopilotChart(
              type: type,
              title: '테스트 집계',
              labels: const ['A', 'B', 'C'],
              series: const [
                CopilotSeries('작업시간', [2.25, null, 3.75])
              ],
              unit: 's')));
      await tester.pumpWidget(shell(source));
      await tester.tap(find.byTooltip('AI 코파일럿'));
      await tester.pumpAndSettle();
      await ask(tester, '그래프');
      expect(find.byKey(ValueKey('copilot-$type-chart')), findsOneWidget);
      expect(find.byKey(const ValueKey('copilot-table')), findsOneWidget);
      expect(find.text('2.25'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('데모 데이터 기반'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unavailable answer and request survive close while pending',
      (tester) async {
    final source = PendingSource();
    await tester.pumpWidget(shell(source));
    await tester.tap(find.byTooltip('AI 코파일럿'));
    await tester.pumpAndSettle();
    await ask(tester, '사용법');
    expect(find.text('답변을 준비하고 있습니다…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('copilot-send')))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('코파일럿 닫기'));
    source.pending.complete(const CopilotResponse(answer: copilotUnavailable));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI 코파일럿'));
    await tester.pumpAndSettle();
    expect(find.text(copilotUnavailable), findsOneWidget);
  });

  testWidgets('mobile panel stays above software keyboard', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);
    await tester
        .pumpWidget(shell(FixtureSource(const CopilotResponse(answer: '답변'))));
    await tester.tap(find.byTooltip('AI 코파일럿'));
    await tester.pumpAndSettle();
    final panel = tester.getRect(find.byKey(const ValueKey('copilot-panel')));
    expect(panel.bottom, lessThanOrEqualTo(524));
    expect(panel.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  test('API sends only question and keeps real numeric values', () async {
    final source = ApiCopilotDataSource(client: MockClient((request) async {
      expect(request.url.path, '/api/copilot/chat');
      expect(jsonDecode(request.body), {'question': '질문'});
      return http.Response(
          jsonEncode({
            'answer': '응답',
            'demo_data': true,
            'table': {
              'columns': ['점수'],
              'rows': [
                [0.123456789]
              ]
            },
            'chart': {
              'type': 'line',
              'title': '점수',
              'labels': ['제품-1'],
              'series': [
                {
                  'name': '점수',
                  'values': [0.123456789]
                }
              ],
              'unit': ''
            }
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final response = await source.ask('질문');
    expect(response.chart!.series[0].values[0], 0.123456789);
    expect(response.table!.rows[0][0], 0.123456789);
  });

  test('API sanitizes HTTP, connection and invalid payload failures', () async {
    for (final mode in ['http', 'connection', 'invalid']) {
      final source = ApiCopilotDataSource(client: MockClient((request) async {
        if (mode == 'connection') {
          throw Exception('connection refused 127.0.0.1');
        }
        return http.Response(
            'stack trace http://internal', mode == 'http' ? 503 : 200);
      }));
      expect((await source.ask('질문')).answer, copilotUnavailable);
    }
  });
}
