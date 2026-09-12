import 'dart:convert';

import 'package:http/http.dart' as http;

import 'quality_dashboard_data.dart';

const _defaultApiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

final class ApiQualityDashboardDataSource
    implements QualityDashboardDataSource, RpfAnalysisDataSource {
  const ApiQualityDashboardDataSource({this.apiBase = _defaultApiBase});

  final String apiBase;

  Uri _uri(String path) {
    final normalized = apiBase.replaceFirst(RegExp(r'/$'), '');
    if (normalized.isEmpty) return Uri.base.resolve(path);
    return Uri.parse('$normalized$path');
  }

  Future<Map<String, dynamic>> _analysisRequest(int rpfId) async {
    final uri = _uri('/api/rpf/$rpfId');
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail'] : null;
      throw Exception(detail ?? 'AI 분석 요청 오류: HTTP ${response.statusCode}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('분석 API 응답 형식이 올바르지 않습니다.');
    }
    return decoded;
  }

  @override
  Future<RpfAnalysisSnapshot> loadAnalysis(int rpfId) async {
    final detail = await _analysisRequest(rpfId);
    final result = detail['analysis_result'];
    return RpfAnalysisSnapshot(
      result: result == null
          ? null
          : RpfAnalysisResult.fromJson(
              Map<String, dynamic>.from(result as Map)),
      isPending: detail['analysis_pending'] == true,
    );
  }

  @override
  Future<DashboardData> load() async {
    final response = await http
        .get(_uri('/api/rpf?limit=50&offset=0'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('RPF API 오류: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['items'] is! List) {
      throw const FormatException('RPF API 응답 형식이 올바르지 않습니다.');
    }

    final records = (decoded['items'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => _grade(item['grade']) != null)
        .toList(growable: false);
    final products = records.map(_product).toList(growable: false);
    final processed = products.length;
    final normal = products
        .where((product) => product.grade == QualityGrade.normal)
        .length;
    final review = products
        .where((product) => product.grade == QualityGrade.review)
        .length;
    final priority = products
        .where((product) => product.grade == QualityGrade.priority)
        .length;
    final totalWorkTime = products.fold<double>(
      0,
      (sum, product) => sum + product.workTimeSeconds,
    );
    final totalRetries = products.fold<int>(
      0,
      (sum, product) => sum + product.retries,
    );
    final reasonCounts = <String, int>{};
    for (final product in products) {
      for (final reason in product.observations.toSet()) {
        reasonCounts.update(reason, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final sortedReasons = reasonCounts.entries.toList()
      ..sort((left, right) {
        final byCount = right.value.compareTo(left.value);
        return byCount != 0 ? byCount : left.key.compareTo(right.key);
      });
    final abnormalEvents = sortedReasons.map((item) {
      return AbnormalEvent(
        name: item.key,
        count: item.value,
        rate: processed == 0 ? 0 : item.value * 100 / processed,
      );
    }).toList(growable: false);
    final averageWorkTime = processed == 0 ? 0.0 : totalWorkTime / processed;

    return DashboardData(
      processedProducts: processed,
      normalProducts: normal,
      reviewProducts: review,
      priorityProducts: priority,
      averageWorkTimeSeconds: averageWorkTime,
      standardWorkTimeSeconds: averageWorkTime,
      averageRetries: processed == 0 ? 0 : totalRetries / processed,
      processDeviationRate:
          processed == 0 ? 0 : (review + priority) * 100 / processed,
      operatorInterventions: products.fold<int>(
        0,
        (sum, product) => sum + product.operatorInterventions,
      ),
      workTimeTrend: products.reversed
          .map(
            (product) => WorkTimePoint(
              productId: product.id,
              seconds: product.workTimeSeconds,
            ),
          )
          .toList(growable: false),
      abnormalEvents: abnormalEvents,
      products: products,
      isMock: false,
    );
  }

  static ProductRpf _product(Map<String, dynamic> item) {
    final grade = _grade(item['grade'])!;
    final reasons = item['grade_reasons'] is List
        ? (item['grade_reasons'] as List)
            .map((reason) => reason.toString())
            .toList(growable: false)
        : <String>[];
    final status = item['status']?.toString() ?? '-';
    return ProductRpf(
      id: item['product_id']?.toString() ?? 'RPF-${item['id']}',
      rpfId: _integer(item['id']),
      productGroup: item['product_group']?.toString(),
      finishedAt: DateTime.tryParse(item['finished_at']?.toString() ?? ''),
      isCompleted: status == 'completed',
      grade: grade,
      workTimeSeconds: _number(item['work_time_ms']) / 1000,
      retries: _integer(item['retry_count']),
      majorAbnormality: reasons.isEmpty ? '-' : reasons.first,
      status: switch (status) {
        'completed' => '완료',
        'failed' => '실패',
        'running' => '진행 중',
        'interrupted' => '중단',
        'stopped' => '정지',
        'pending' => '대기',
        _ => '상태 확인 중',
      },
      operatorInterventions: _integer(item['operator_interventions']),
      errorEvents: _integer(item['error_count']),
      observations: reasons,
      causeCandidates: const [],
      timeline: [
        RpfStep(name: '사이클 시작', detail: 'cycle ${item['cycle_index']}'),
        ...reasons.map(
          (reason) => RpfStep(name: '판정 근거', detail: reason, isIssue: true),
        ),
        RpfStep(
          name: status == 'completed' ? '사이클 완료' : '사이클 종료',
          detail:
              '${(_number(item['work_time_ms']) / 1000).toStringAsFixed(1)}초',
          isIssue: status != 'completed',
        ),
      ],
      recommendations: const [],
    );
  }

  static QualityGrade? _grade(dynamic value) => switch (value?.toString()) {
        'normal' => QualityGrade.normal,
        'review' => QualityGrade.review,
        'priority' => QualityGrade.priority,
        _ => null,
      };

  static int _integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;

  static double _number(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0;
}
