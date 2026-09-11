import 'package:flutter/material.dart';

const metricDescriptions = <String, String>{
  '등급': '공정 이력의 규칙 기반 분류입니다. 정상, 확인 필요, 우선검사로 구분하며 실제 검사 PASS/FAIL을 뜻하지 않습니다.',
  'RPF': '제품별 작업 순서, 작업시간, 재시도, 오류 등 공정 이력을 하나로 묶은 기록입니다.',
  '공정 이상도': '작업시간, 재시도, 오류 등의 특징이 정상 공정과 얼마나 다른지 나타냅니다. 불량 확률은 아닙니다.',
  '검사 위험도':
      '공정 이력이 품질검사 FAIL 패턴과 얼마나 유사한지 나타내는 보조 점수입니다. 현재는 합성 데이터 기반 시험 지표입니다.',
  '공정 단계 시간 이상도': 'HOME부터 RELEASE까지 각 작업 단계의 시간 패턴이 정상 공정과 얼마나 다른지 나타냅니다.',
  '공정 이탈률': '전체 처리 제품 중 정상 등급이 아닌 제품의 비율입니다.',
  '확인 필요': '일부 공정 이상이 있어 추가 확인이 필요한 제품입니다.',
  '우선검사': '오류나 반복 실패 등으로 먼저 검사할 필요가 있는 제품입니다.',
};

class MetricLabel extends StatelessWidget {
  const MetricLabel(this.label, {super.key, this.term, this.style});

  final String label;
  final String? term;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final helpTerm = term ?? label;
    final description = metricDescriptions[helpTerm];
    if (description == null) return Text(label, style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(label, style: style)),
        const SizedBox(width: 4),
        Tooltip(
          message: description,
          triggerMode: TooltipTriggerMode.tap,
          waitDuration: const Duration(milliseconds: 350),
          showDuration: const Duration(seconds: 6),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(
            maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(0, 328),
          ),
          child: Semantics(
            label: '$helpTerm 설명',
            button: true,
            child: SizedBox.square(
              dimension: 24,
              child: Icon(Icons.info_outline,
                  size: 15,
                  color: style?.color ??
                      Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}
