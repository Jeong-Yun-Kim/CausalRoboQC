import 'dart:async';

import 'package:causal_robo_qc_app/dashboard_theme.dart';
import 'package:causal_robo_qc_app/data_browser_api.dart';
import 'package:causal_robo_qc_app/data_browser_data.dart';
import 'package:causal_robo_qc_app/data_browser_page.dart';
import 'package:causal_robo_qc_app/quality_dashboard_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class BrowserSource implements DataBrowserDataSource {
  final calls = <({DataBrowserFilter filter, int offset})>[];
  bool fail = false;
  Completer<DataBrowserResult>? pending;

  @override
  Future<DataBrowserResult> load(DataBrowserFilter filter,
      {required int limit, required int offset}) async {
    calls.add((filter: filter, offset: offset));
    if (fail) throw Exception('offline');
    if (pending != null) return pending!.future;
    return DataBrowserResult(
        items: filter.productId == 'empty'
            ? []
            : [
                DataBrowserRecord.fromJson({
                  'id': offset + 1,
                  'product_id': 'ROW-${offset + 1}',
                  'product_group': filter.productGroup,
                  'grade': 'normal',
                  'finished_at': '2026-09-12T03:00:00Z',
                  'work_time_ms': 12500,
                }),
              ],
        total: filter.productId == 'empty' ? 0 : 30,
        productGroups: ['A', 'B', 'C']);
  }

  @override
  Uri csvUri(DataBrowserFilter filter) =>
      const ApiDataBrowserDataSource().csvUri(filter);
}

void main() {
  test('calendar dates become UTC bounds shared by the CSV URL', () {
    final filter = DataBrowserFilter(
        startDate: DateTime(2026, 9, 11),
        endDate: DateTime(2026, 9, 12),
        productGroup: 'A',
        grade: QualityGrade.priority,
        productId: '  한글 & 01  ');
    final uri = const ApiDataBrowserDataSource(apiBase: 'https://example.test/')
        .csvUri(filter);
    expect(uri.path, '/api/data/rpf.csv');
    expect(uri.queryParameters, {
      'from_at': DateTime(2026, 9, 11).toUtc().toIso8601String(),
      'to_at': DateTime(2026, 9, 13).toUtc().toIso8601String(),
      'product_group': 'A',
      'grade': 'priority',
      'product_id': '한글 & 01',
    });
    expect(uri.queryParameters.containsKey('limit'), isFalse);
  });

  Future<void> mount(WidgetTester tester, BrowserSource source,
      {void Function(Uri)? onDownload,
      Size size = const Size(1440, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: DashboardTheme.light,
        home: Scaffold(
            body: DataBrowserPage(
                dataSource: source, onDownload: onDownload ?? (_) {}))));
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.ensureVisible(find.text('조회'));
    await tester.tap(find.text('조회'));
    await tester.pumpAndSettle();
  }

  testWidgets('filters, pagination and CSV use only the applied query',
      (tester) async {
    final source = BrowserSource();
    Uri? download;
    await mount(tester, source, onDownload: (uri) => download = uri);
    expect(find.text('ROW-1'), findsOneWidget);
    expect(find.text('12.50초'), findsOneWidget);
    expect(find.text('-'), findsWidgets);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('우선검사').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '검색 ID');
    final button = find.widgetWithText(OutlinedButton, 'CSV 다운로드');
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    await apply(tester);
    expect(source.calls.last.filter.productGroup, 'A');
    expect(source.calls.last.filter.grade, QualityGrade.priority);
    expect(source.calls.last.filter.productId, '검색 ID');
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    expect(source.calls.last.offset, 25);
    expect(find.text('ROW-26'), findsOneWidget);
    await tester.tap(button);
    expect(download!.queryParameters, source.calls.last.filter.parameters);
    expect(download!.queryParameters.containsKey('offset'), isFalse);
    await tester.tap(find.text('초기화'));
    await tester.pumpAndSettle();
    expect(source.calls.last.offset, 0);
    expect(source.calls.last.filter.productGroup, isNull);
    expect(source.calls.last.filter.grade, isNull);
    expect(source.calls.last.filter.productId, '');
  });

  testWidgets('empty results and errors never leave a stale CSV enabled',
      (tester) async {
    final source = BrowserSource();
    await mount(tester, source);
    await tester.enterText(find.byType(TextField), 'empty');
    await apply(tester);
    expect(find.text('조건에 맞는 데이터가 없습니다.'), findsOneWidget);
    source.fail = true;
    await apply(tester);
    expect(find.textContaining('서버 연결을 확인'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'CSV 다운로드'))
            .onPressed,
        isNull);
  });

  testWidgets('phone layout scrolls without overflow', (tester) async {
    await mount(tester, BrowserSource(), size: const Size(390, 844));
    await tester.drag(find.byType(ListView), const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-flight replies are ignored after leaving the page',
      (tester) async {
    final source = BrowserSource()..pending = Completer<DataBrowserResult>();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DataBrowserPage(dataSource: source))));
    await tester.pumpWidget(const SizedBox());
    source.pending!.complete(
        const DataBrowserResult(items: [], total: 0, productGroups: []));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
