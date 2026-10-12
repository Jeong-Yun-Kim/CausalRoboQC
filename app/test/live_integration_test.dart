import 'dart:convert';
import 'dart:typed_data';
import 'package:causal_robo_qc_app/inspection_panel.dart';
import 'package:causal_robo_qc_app/server_camera_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class InspectionFixture implements InspectionSource {
  Map<String, dynamic>? value;
  bool offline = false;
  @override
  Future<Map<String, dynamic>?> loadInspection(int id) async => value;
  @override
  Future<Map<String, dynamic>> saveInspection(
      int id, Map<String, dynamic> next) async {
    if (offline) throw Exception('offline');
    return value = {
      ...next,
      'rpf_id': id,
      'inspected_at': '2026-10-12T00:00:00Z'
    };
  }
}

void main() {
  testWidgets('server camera displays a memory frame and handles failure',
      (tester) async {
    bool offline = false;
    final Uint8List png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ServerCameraPreview(
                apiBase: 'http://fixture',
                loadFrame: () async {
                  if (offline) throw Exception('offline');
                  return png;
                }))));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.bySemanticsLabel('서버 카메라 영상'), findsOneWidget);
    offline = true;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('카메라에 연결할 수 없습니다. 연결 상태를 확인해 주세요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('inspection saves, edits, reloads and reports write failure',
      (tester) async {
    final source = InspectionFixture();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: InspectionPanel(rpfId: 1, source: source)))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '표면 손상, 위치 확인');
    await tester.enterText(find.byType(TextField).at(1), '재검사');
    await tester.enterText(find.byType(TextField).at(2), '작업자 확인');
    await tester.tap(find.text('PASS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FAIL').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('검사 결과 저장'));
    await tester.tap(find.text('검사 결과 저장'));
    await tester.pumpAndSettle();
    expect(source.value?['result'], 'FAIL');
    expect(source.value?['confirmed_causes'], ['표면 손상', '위치 확인']);
    expect(find.text('검사 결과를 저장했습니다.'), findsOneWidget);
    source.offline = true;
    await tester.tap(find.text('검사 결과 저장'));
    await tester.pumpAndSettle();
    expect(find.text('검사 결과를 저장하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: InspectionPanel(rpfId: 1, source: source)))));
    await tester.pumpAndSettle();
    expect(find.text('FAIL'), findsOneWidget);
    expect(find.text('재검사'), findsOneWidget);
  });
}
