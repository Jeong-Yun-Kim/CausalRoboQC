import 'dart:async';

import 'package:flutter/material.dart';

import 'metric_help.dart';
import 'quality_dashboard_data.dart';

/// Read saved auxiliary analysis without changing the rule-based grade.
class RpfAnalysisPanel extends StatefulWidget {
  const RpfAnalysisPanel(
      {super.key, required this.product, required this.source});

  final ProductRpf product;
  final RpfAnalysisDataSource? source;

  @override
  State<RpfAnalysisPanel> createState() => _RpfAnalysisPanelState();
}

class _RpfAnalysisPanelState extends State<RpfAnalysisPanel> {
  static const _maxRetries = 5;
  RpfAnalysisResult? _result;
  bool _pending = false;
  int _retries = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _pending = widget.product.rpfId != null &&
        widget.product.isCompleted &&
        widget.source != null;
    _load();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.product.rpfId;
    final source = widget.source;
    if (id == null || source == null) return;
    try {
      final snapshot = await source.loadAnalysis(id);
      if (!mounted) return;
      setState(() {
        _result = snapshot.result ?? _result;
        _pending =
            _result == null && snapshot.isPending && _retries < _maxRetries;
      });
      if (_pending) {
        _retryTimer = Timer(const Duration(seconds: 2), () {
          _retries++;
          _load();
        });
      }
    } catch (error, stack) {
      debugPrint('Analysis load failed: $error\n$stack');
      if (mounted) setState(() => _pending = false);
    }
  }

  Widget _score(String label, double? value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: MetricLabel(label)),
            const SizedBox(width: 8),
            Text(
              _result == null
                  ? (_pending ? '분석 중...' : '분석 대기')
                  : value == null
                      ? '데이터 부족'
                      : '${(value * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('보조 분석', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        _score('공정 이상도', result?.anomalyScore),
        _score('검사 위험도', result?.inspectionRiskScore),
        _score('공정 단계 시간 이상도', result?.timeseriesAnomalyScore),
        if (result?.syntheticModel == true) ...[
          const SizedBox(height: 6),
          Text('※ 합성 데이터 기반 시험 모델',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
