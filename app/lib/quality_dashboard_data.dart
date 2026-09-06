enum QualityGrade { normal, review, priority }

extension QualityGradeText on QualityGrade {
  String get label => switch (this) {
        QualityGrade.normal => '정상',
        QualityGrade.review => '확인 필요',
        QualityGrade.priority => '우선검사',
      };

  int get priority => switch (this) {
        QualityGrade.normal => 0,
        QualityGrade.review => 1,
        QualityGrade.priority => 2,
      };
}

final class WorkTimePoint {
  const WorkTimePoint({required this.productId, required this.seconds});

  final String productId;
  final double seconds;
}

final class CauseCandidate {
  const CauseCandidate({required this.name, required this.probability});

  final String name;
  final double probability;
}

final class AbnormalEvent {
  const AbnormalEvent({
    required this.name,
    required this.count,
    required this.rate,
  });

  final String name;
  final int count;
  final double rate;
}

final class RpfStep {
  const RpfStep({
    required this.name,
    required this.detail,
    this.isIssue = false,
  });

  final String name;
  final String detail;
  final bool isIssue;
}

final class ProductRpf {
  const ProductRpf({
    required this.id,
    required this.grade,
    required this.workTimeSeconds,
    required this.retries,
    required this.majorAbnormality,
    required this.status,
    required this.operatorInterventions,
    required this.errorEvents,
    required this.observations,
    required this.causeCandidates,
    required this.timeline,
    required this.recommendations,
    this.rpfId,
    this.isCompleted = false,
  });

  final String id;
  final int? rpfId;
  final bool isCompleted;
  final QualityGrade grade;
  final double workTimeSeconds;
  final int retries;
  final String majorAbnormality;
  final String status;
  final int operatorInterventions;
  final int errorEvents;
  final List<String> observations;
  final List<CauseCandidate> causeCandidates;
  final List<RpfStep> timeline;
  final List<String> recommendations;
}

final class DashboardData {
  const DashboardData({
    required this.processedProducts,
    required this.normalProducts,
    required this.reviewProducts,
    required this.priorityProducts,
    required this.averageWorkTimeSeconds,
    required this.standardWorkTimeSeconds,
    required this.averageRetries,
    required this.processDeviationRate,
    required this.operatorInterventions,
    required this.workTimeTrend,
    required this.abnormalEvents,
    required this.products,
    required this.isMock,
  });

  final int processedProducts;
  final int normalProducts;
  final int reviewProducts;
  final int priorityProducts;
  final double averageWorkTimeSeconds;
  final double standardWorkTimeSeconds;
  final double averageRetries;
  final double processDeviationRate;
  final int operatorInterventions;
  final List<WorkTimePoint> workTimeTrend;
  final List<AbnormalEvent> abnormalEvents;
  final List<ProductRpf> products;
  final bool isMock;

  List<ProductRpf> get sortedProducts {
    final result = List<ProductRpf>.of(products)
      ..sort((left, right) {
        final byGrade = right.grade.priority.compareTo(left.grade.priority);
        if (byGrade != 0) return byGrade;
        return right.id.compareTo(left.id);
      });
    return List<ProductRpf>.unmodifiable(result);
  }
}

abstract interface class QualityDashboardDataSource {
  Future<DashboardData> load();
}

final class RpfAnalysisResult {
  const RpfAnalysisResult({
    required this.anomalyScore,
    required this.inspectionRiskScore,
    required this.timeseriesAnomalyScore,
    required this.syntheticModel,
  });

  factory RpfAnalysisResult.fromJson(Map<String, dynamic> json) {
    double score(String name) {
      final value = json[name];
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        throw const FormatException('분석 점수 형식이 올바르지 않습니다.');
      }
      return value.toDouble();
    }

    return RpfAnalysisResult(
      anomalyScore: score('anomaly_score'),
      inspectionRiskScore: score('inspection_risk_score'),
      timeseriesAnomalyScore: json['timeseries_anomaly_score'] == null
          ? null
          : score('timeseries_anomaly_score'),
      syntheticModel: json['synthetic_model'] == true,
    );
  }

  final double anomalyScore;
  final double inspectionRiskScore;
  final double? timeseriesAnomalyScore;
  final bool syntheticModel;
}

abstract interface class RpfAnalysisDataSource {
  Future<RpfAnalysisResult?> loadAnalysis(int rpfId);
  Future<RpfAnalysisResult> analyze(int rpfId);
}

final class MockQualityDashboardDataSource
    implements QualityDashboardDataSource {
  const MockQualityDashboardDataSource();

  @override
  Future<DashboardData> load() async => _dashboard;

  static const DashboardData _dashboard = DashboardData(
    processedProducts: 128,
    normalProducts: 108,
    reviewProducts: 12,
    priorityProducts: 8,
    averageWorkTimeSeconds: 12.4,
    standardWorkTimeSeconds: 11.8,
    averageRetries: 0.32,
    processDeviationRate: 15.6,
    operatorInterventions: 4,
    isMock: true,
    workTimeTrend: [
      WorkTimePoint(productId: 'P-109', seconds: 11.5),
      WorkTimePoint(productId: 'P-110', seconds: 11.8),
      WorkTimePoint(productId: 'P-111', seconds: 12.1),
      WorkTimePoint(productId: 'P-112', seconds: 11.7),
      WorkTimePoint(productId: 'P-113', seconds: 12.0),
      WorkTimePoint(productId: 'P-114', seconds: 12.3),
      WorkTimePoint(productId: 'P-115', seconds: 11.9),
      WorkTimePoint(productId: 'P-116', seconds: 12.2),
      WorkTimePoint(productId: 'P-117', seconds: 11.6),
      WorkTimePoint(productId: 'P-118', seconds: 11.9),
      WorkTimePoint(productId: 'P-119', seconds: 11.8),
      WorkTimePoint(productId: 'P-120', seconds: 11.7),
      WorkTimePoint(productId: 'P-121', seconds: 12.4),
      WorkTimePoint(productId: 'P-122', seconds: 12.4),
      WorkTimePoint(productId: 'P-123', seconds: 11.9),
      WorkTimePoint(productId: 'P-124', seconds: 14.1),
      WorkTimePoint(productId: 'P-125', seconds: 12.2),
      WorkTimePoint(productId: 'P-126', seconds: 11.6),
      WorkTimePoint(productId: 'P-127', seconds: 18.7),
      WorkTimePoint(productId: 'P-128', seconds: 12.2),
    ],
    abnormalEvents: [
      AbnormalEvent(name: '집기 재시도', count: 3, rate: 2.3),
      AbnormalEvent(name: '작업시간 초과', count: 1, rate: 0.8),
      AbnormalEvent(name: '배치 실패', count: 1, rate: 0.8),
      AbnormalEvent(name: '작업자 수동 보정', count: 1, rate: 0.8),
    ],
    products: [
      ProductRpf(
        id: 'P-128',
        grade: QualityGrade.normal,
        workTimeSeconds: 12.2,
        retries: 0,
        majorAbnormality: '-',
        status: '완료',
        operatorInterventions: 0,
        errorEvents: 0,
        observations: ['전 공정 정상 완료', '재시도 및 수동 개입 없음'],
        causeCandidates: [],
        timeline: _normalTimeline,
        recommendations: ['추가 조치 없음'],
      ),
      ProductRpf(
        id: 'P-127',
        grade: QualityGrade.priority,
        workTimeSeconds: 18.7,
        retries: 3,
        majorAbnormality: '집기 반복 실패',
        status: '검사 대기',
        operatorInterventions: 0,
        errorEvents: 2,
        observations: ['집기 재시도 3회', '작업시간 +4.2초', '배치 위치 오차'],
        causeCandidates: [
          CauseCandidate(name: '제품 초기 위치 오류', probability: 48),
          CauseCandidate(name: '그리퍼 설정 이상', probability: 27),
          CauseCandidate(name: '카메라 좌표 오차', probability: 17),
          CauseCandidate(name: '통신 지연', probability: 8),
        ],
        timeline: [
          RpfStep(name: '제품 인식', detail: '✓'),
          RpfStep(name: '집기', detail: '재시도 3회', isIssue: true),
          RpfStep(name: '이동', detail: '완료'),
          RpfStep(name: '배치', detail: '위치 오차', isIssue: true),
          RpfStep(name: '작업', detail: '완료'),
          RpfStep(name: '품질 검사', detail: '대기', isIssue: true),
        ],
        recommendations: [
          '제품 초기 위치 확인',
          '그리퍼 파지 위치 및 각도 확인',
          '카메라 좌표 보정 상태 확인',
        ],
      ),
      ProductRpf(
        id: 'P-126',
        grade: QualityGrade.normal,
        workTimeSeconds: 11.6,
        retries: 0,
        majorAbnormality: '-',
        status: '완료',
        operatorInterventions: 0,
        errorEvents: 0,
        observations: ['기준 작업시간 이내 완료'],
        causeCandidates: [],
        timeline: _normalTimeline,
        recommendations: ['추가 조치 없음'],
      ),
      ProductRpf(
        id: 'P-125',
        grade: QualityGrade.review,
        workTimeSeconds: 12.2,
        retries: 1,
        majorAbnormality: '집기 재시도',
        status: '확인 완료',
        operatorInterventions: 0,
        errorEvents: 1,
        observations: ['첫 집기 실패 후 재시도 성공'],
        causeCandidates: [
          CauseCandidate(name: '제품 초기 위치 오류', probability: 44),
          CauseCandidate(name: '그리퍼 설정 이상', probability: 31),
          CauseCandidate(name: '카메라 좌표 오차', probability: 25),
        ],
        timeline: _retryTimeline,
        recommendations: ['제품 투입 위치 확인', '동일 현상 반복 여부 관찰'],
      ),
      ProductRpf(
        id: 'P-124',
        grade: QualityGrade.review,
        workTimeSeconds: 14.1,
        retries: 1,
        majorAbnormality: '작업시간 초과',
        status: '확인 필요',
        operatorInterventions: 1,
        errorEvents: 1,
        observations: ['기준 작업시간 +2.3초', '집기 재시도 1회', '명령 응답 지연 감지'],
        causeCandidates: [
          CauseCandidate(name: '통신 지연', probability: 41),
          CauseCandidate(name: '제품 초기 위치 오류', probability: 32),
          CauseCandidate(name: '그리퍼 설정 이상', probability: 18),
          CauseCandidate(name: '카메라 좌표 오차', probability: 9),
        ],
        timeline: [
          RpfStep(name: '제품 인식', detail: '✓'),
          RpfStep(name: '집기', detail: '재시도 1회', isIssue: true),
          RpfStep(name: '이동', detail: '응답 지연', isIssue: true),
          RpfStep(name: '배치', detail: '완료'),
          RpfStep(name: '작업', detail: '14.1초', isIssue: true),
          RpfStep(name: '품질 확인', detail: '필요', isIssue: true),
        ],
        recommendations: [
          'USB Serial 연결 상태 확인',
          '제어 명령 응답 지연 확인',
          '동일 현상 반복 여부 관찰'
        ],
      ),
      ProductRpf(
        id: 'P-123',
        grade: QualityGrade.normal,
        workTimeSeconds: 11.9,
        retries: 0,
        majorAbnormality: '--',
        status: '완료',
        operatorInterventions: 0,
        errorEvents: 0,
        observations: ['기준 작업시간 대비 +0.1초', '재시도 및 오류 이벤트 없음'],
        causeCandidates: [],
        timeline: _normalTimeline,
        recommendations: ['추가 조치 없음'],
      ),
      ProductRpf(
        id: 'P-122',
        grade: QualityGrade.normal,
        workTimeSeconds: 12.4,
        retries: 0,
        majorAbnormality: '-',
        status: '완료',
        operatorInterventions: 0,
        errorEvents: 0,
        observations: ['전 공정 정상 완료'],
        causeCandidates: [],
        timeline: _normalTimeline,
        recommendations: ['추가 조치 없음'],
      ),
      ProductRpf(
        id: 'P-121',
        grade: QualityGrade.review,
        workTimeSeconds: 12.4,
        retries: 0,
        majorAbnormality: '작업자 수동 보정',
        status: '확인 완료',
        operatorInterventions: 1,
        errorEvents: 0,
        observations: ['배치 전 제품 위치 수동 보정'],
        causeCandidates: [
          CauseCandidate(name: '제품 초기 위치 오류', probability: 57),
          CauseCandidate(name: '카메라 좌표 오차', probability: 29),
          CauseCandidate(name: '그리퍼 설정 이상', probability: 14),
        ],
        timeline: [
          RpfStep(name: '제품 인식', detail: '위치 편차', isIssue: true),
          RpfStep(name: '작업자 보정', detail: '완료'),
          RpfStep(name: '집기', detail: '완료'),
          RpfStep(name: '이동', detail: '완료'),
          RpfStep(name: '배치', detail: '완료'),
          RpfStep(name: '작업', detail: '완료'),
        ],
        recommendations: ['제품 공급 위치 점검', '카메라 좌표 편차 관찰'],
      ),
      ProductRpf(
        id: 'P-120',
        grade: QualityGrade.normal,
        workTimeSeconds: 11.7,
        retries: 0,
        majorAbnormality: '-',
        status: '완료',
        operatorInterventions: 0,
        errorEvents: 0,
        observations: ['기준 작업시간 이내 완료'],
        causeCandidates: [],
        timeline: _normalTimeline,
        recommendations: ['추가 조치 없음'],
      ),
      ProductRpf(
        id: 'P-119',
        grade: QualityGrade.review,
        workTimeSeconds: 11.8,
        retries: 1,
        majorAbnormality: '배치 위치 보정',
        status: '확인 완료',
        operatorInterventions: 1,
        errorEvents: 1,
        observations: ['배치 위치 오차 후 자동 보정 완료'],
        causeCandidates: [
          CauseCandidate(name: '카메라 좌표 오차', probability: 52),
          CauseCandidate(name: '제품 초기 위치 오류', probability: 30),
          CauseCandidate(name: '그리퍼 설정 이상', probability: 18),
        ],
        timeline: [
          RpfStep(name: '제품 인식', detail: '✓'),
          RpfStep(name: '집기', detail: '완료'),
          RpfStep(name: '이동', detail: '완료'),
          RpfStep(name: '배치', detail: '위치 보정', isIssue: true),
          RpfStep(name: '작업', detail: '완료'),
        ],
        recommendations: ['카메라 좌표 보정 상태 확인', '배치 위치 편차 추적'],
      ),
    ],
  );
}

const mockQualityDashboardDataSource = MockQualityDashboardDataSource();

const _normalTimeline = [
  RpfStep(name: '제품 인식', detail: '✓'),
  RpfStep(name: '집기', detail: '완료'),
  RpfStep(name: '이동', detail: '완료'),
  RpfStep(name: '배치', detail: '완료'),
  RpfStep(name: '작업', detail: '완료'),
  RpfStep(name: '품질 검사', detail: '완료'),
];

const _retryTimeline = [
  RpfStep(name: '제품 인식', detail: '✓'),
  RpfStep(name: '집기', detail: '재시도 1회', isIssue: true),
  RpfStep(name: '이동', detail: '완료'),
  RpfStep(name: '배치', detail: '완료'),
  RpfStep(name: '작업', detail: '완료'),
  RpfStep(name: '품질 확인', detail: '완료'),
];
