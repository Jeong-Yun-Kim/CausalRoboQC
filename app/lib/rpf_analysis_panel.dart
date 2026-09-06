import 'package:flutter/material.dart';

import 'quality_dashboard_data.dart';

/// The analysis state belongs to this detail dialog, not the rule-based grade.
class RpfAnalysisPanel extends StatefulWidget {
  const RpfAnalysisPanel(
      {super.key, required this.product, required this.source});

  final ProductRpf product;
  final RpfAnalysisDataSource? source;

  @override
  State<RpfAnalysisPanel> createState() => _RpfAnalysisPanelState();
}

class _RpfAnalysisPanelState extends State<RpfAnalysisPanel> {
  RpfAnalysisResult? _result;
  bool _loading = true;
  bool _analyzing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.product.rpfId;
      final source = widget.source;
      final result =
          id == null || source == null ? null : await source.loadAnalysis(id);
      if (mounted) setState(() => _result = result);
    } catch (_) {
      if (mounted) setState(() => _error = '저장된 분석 결과를 불러오지 못했습니다.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _analyze() async {
    if (_analyzing) return;
    setState(() {
      _analyzing = true;
      _error = null;
    });
    try {
      final result = await widget.source!.analyze(widget.product.rpfId!);
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Widget _score(String label, double? value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(
              value == null ? '데이터 부족' : '${(value * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final canAnalyze = widget.product.rpfId != null &&
        widget.product.isCompleted &&
        widget.source != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('ML / DL 분석', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        if (_loading)
          const Text('분석 결과 불러오는 중...')
        else if (result == null)
          const Text('분석 결과 없음')
        else ...[
          _score('공정 이상도', result.anomalyScore),
          _score('검사 위험도', result.inspectionRiskScore),
          _score('시계열 이상도', result.timeseriesAnomalyScore),
          if (result.syntheticModel) ...[
            const SizedBox(height: 6),
            Text('※ 합성 데이터 기반 시험 모델',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: canAnalyze && !_loading && !_analyzing ? _analyze : null,
            icon: _analyzing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.analytics_outlined, size: 18),
            label: Text(_analyzing ? '분석 중...' : 'AI 분석 실행'),
          ),
        ),
        if (!canAnalyze) ...[
          const SizedBox(height: 6),
          Text('완료된 실제 RPF를 선택하면 분석할 수 있습니다.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
