import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  RpfAnalysisSnapshot? _snapshot;
  bool _pending = false;
  int _retries = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _result = widget.product.analysis;
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
        _snapshot = snapshot;
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
        if (_snapshot?.stages.isNotEmpty == true) ...[
          const Divider(height: 32),
          Text('공정 단계별 소요시간', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final step in _snapshot!.stages)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(step.name)),
                  Text(step.detail)
                ])),
        ],
        if (_snapshot?.recommendedChecks.isNotEmpty == true) ...[
          const Divider(height: 32),
          Text('권장 점검 순서', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (var i = 0; i < _snapshot!.recommendedChecks.length; i++)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('${i + 1}. ${_snapshot!.recommendedChecks[i]}')),
          const SizedBox(height: 6),
          Text('기록에 따른 확인 항목이며 원인을 확정하지 않습니다.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
        if (_snapshot?.reportDraft != null) ...[
          const Divider(height: 32),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('품질보고서 초안'),
            children: [
              Semantics(
                label: _snapshot!.reportDraft!,
                excludeSemantics: true,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(_snapshot!.reportDraft!)),
              ),
              Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                      onPressed: () async {
                        try {
                          await Clipboard.setData(
                              ClipboardData(text: _snapshot!.reportDraft!));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('보고서 초안을 복사했습니다.')));
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('본문을 선택해 복사해 주세요.')));
                          }
                        }
                      },
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: const Text('보고서 복사'))),
            ],
          ),
        ],
      ],
    );
  }
}
