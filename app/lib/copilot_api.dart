import 'dart:convert';

import 'package:http/http.dart' as http;

const copilotUnavailable = 'AI 코파일럿을 사용할 수 없습니다.\n로컬 AI 서버 상태를 확인해주세요.';

class CopilotTable {
  const CopilotTable(this.columns, this.rows);
  final List<String> columns;
  final List<List<Object?>> rows;

  factory CopilotTable.fromJson(Map<String, dynamic> json) {
    final columns = (json['columns'] as List).cast<String>();
    final rows = (json['rows'] as List)
        .map((row) => (row as List).cast<Object?>())
        .toList();
    if (columns.isEmpty ||
        columns.length > 12 ||
        rows.length > 50 ||
        rows.any((row) => row.length != columns.length)) {
      throw const FormatException('Invalid table');
    }
    return CopilotTable(columns, rows);
  }
}

class CopilotSeries {
  const CopilotSeries(this.name, this.values);
  final String name;
  final List<double?> values;
}

class CopilotChart {
  const CopilotChart(
      {required this.type,
      required this.title,
      required this.labels,
      required this.series,
      required this.unit});
  final String type;
  final String title;
  final List<String> labels;
  final List<CopilotSeries> series;
  final String unit;

  factory CopilotChart.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    final labels = (json['labels'] as List).cast<String>();
    final series = (json['series'] as List).map((item) {
      return CopilotSeries(
          item['name'] as String,
          (item['values'] as List)
              .map((value) => value == null ? null : (value as num).toDouble())
              .toList());
    }).toList();
    if (!['bar', 'line'].contains(type) ||
        labels.isEmpty ||
        labels.length > 50 ||
        series.isEmpty ||
        series.length > 4 ||
        series.any((s) =>
            s.values.length != labels.length ||
            s.values.any((v) => v != null && (!v.isFinite || v < 0)))) {
      throw const FormatException('Invalid chart');
    }
    return CopilotChart(
        type: type,
        title: json['title'] as String,
        labels: labels,
        series: series,
        unit: json['unit'] as String);
  }
}

class CopilotResponse {
  const CopilotResponse(
      {required this.answer, this.table, this.chart, this.demoData = false});
  final String answer;
  final CopilotTable? table;
  final CopilotChart? chart;
  final bool demoData;

  factory CopilotResponse.fromJson(Map<String, dynamic> json) =>
      CopilotResponse(
          answer: json['answer'] as String,
          table: json['table'] == null
              ? null
              : CopilotTable.fromJson(json['table'] as Map<String, dynamic>),
          chart: json['chart'] == null
              ? null
              : CopilotChart.fromJson(json['chart'] as Map<String, dynamic>),
          demoData: json['demo_data'] as bool);
}

abstract interface class CopilotDataSource {
  Future<CopilotResponse> ask(String question);
}

class ApiCopilotDataSource implements CopilotDataSource {
  const ApiCopilotDataSource(
      {this.apiBase = const String.fromEnvironment('API_BASE_URL',
          defaultValue: 'http://127.0.0.1:8000'),
      this.client});
  final String apiBase;
  final http.Client? client;

  @override
  Future<CopilotResponse> ask(String question) async {
    final base = apiBase.replaceFirst(RegExp(r'/$'), '');
    final uri = base.isEmpty
        ? Uri.base.resolve('/api/copilot/chat')
        : Uri.parse('$base/api/copilot/chat');
    final connection = client ?? http.Client();
    try {
      final response = await connection
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'question': question}))
          .timeout(const Duration(seconds: 65));
      if (response.statusCode != 200) {
        // Never render transport details, endpoints, tracebacks or remote errors.
        var demo = false;
        try {
          demo =
              jsonDecode(utf8.decode(response.bodyBytes))['demo_data'] == true;
        } catch (_) {
          // A non-JSON error is still the same user-facing unavailable state.
        }
        return CopilotResponse(answer: copilotUnavailable, demoData: demo);
      }
      return CopilotResponse.fromJson(
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return const CopilotResponse(answer: copilotUnavailable);
    } finally {
      if (client == null) connection.close();
    }
  }
}
