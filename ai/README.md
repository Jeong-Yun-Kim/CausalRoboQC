# 합성 ML/DL 파이프라인 시험

실제 공정 데이터가 부족한 상태에서 생성·학습·저장·재로드·추론 경로를
검증하기 위한 독립 실행 코드입니다. **점수와 평가 수치는 합성 데이터 기준이며
실제 제조 공정 성능, 실제 불량 확률 또는 운영 임계값을 의미하지 않습니다.**

## 실행

저장소 루트에서 Python 3.10 이상을 사용합니다. 가상환경을 활성화하면
`python` 명령으로 아래 스크립트를 실행할 수 있습니다.

```bash
python3 -m venv .venv
source .venv/bin/activate
# Linux/Windows에서 CUDA 패키지 없이 CPU 전용 PyTorch를 설치하려면 먼저 실행:
python -m pip install torch --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r ai/requirements.txt
python scripts/generate_synthetic_data.py
python scripts/train_models.py
python scripts/smoke_test_models.py
python -m compileall ai scripts
python -m unittest discover -s server/tests -v
```

기존 RPF 테스트에는 별도로 `server/requirements.txt` 환경이 필요합니다.
학습과 체크포인트 로딩은 CPU를 명시하며 GPU를 요구하지 않습니다.
저장된 모델을 재현하려면 `models/metadata.json`의 패키지 버전을 참고하세요.
특히 scikit-learn 모델은 저장 시 사용한 버전으로 로드하는 것이 좋습니다.

기본 데이터는 제품 2,000개, 제품당 7개 단계 시간 한 행입니다. 시간 단위는
모두 ms이고 제품 ID는 `SYN-P-00001` 형태입니다. seed는 42이며 grade는
normal 1,500개, review 360개, priority 140개입니다. grade는 합성 생성 조건으로,
기존 서비스의 이벤트 기반 등급 규칙을 그대로 재현한 값은 아닙니다.
검사 결과는 작업시간·재시도·오류·개입과 연관된 확률에 노이즈를 더해 생성합니다.
전체 작업시간에는 7개 단계 시간 외 최종 HOME 복귀, 대기, 재시도 등의 추가
소요시간이 포함됩니다. 모든 시간과 생성 계수는 측정값이 아닌 시험용 가정입니다.

스크립트의 기본 경로는 저장소 위치를 기준으로 정합니다. 별도 결과를 보존하려면
생성 스크립트의 `--output-dir`, 학습의 `--data-dir` / `--model-dir`, smoke test의
`--model-dir`을 사용하세요. 기본 경로로 다시 실행하면 합성 CSV/모델을 갱신합니다.

## 학습과 점수

동일한 제품 분할을 세 모델에 사용합니다(train 80%, test 20%). 분할 이후 정상
학습 제품만으로 두 StandardScaler, Isolation Forest, Autoencoder와 점수 변환
기준을 학습합니다. Random Forest는 학습 제품 전체를 사용합니다. 시험 제품은
모델·scaler·변환 기준 학습이나 하이퍼파라미터 선택에 사용하지 않습니다.
`grade`는 분할 및 정상 학습 집합 선택에만, `inspection_result`는 분할 및 RF
target에만 사용합니다. 둘 다 모델 입력에서 제외합니다.

| 모델 | 입력 | 출력 |
| --- | --- | --- |
| Isolation Forest | work_time_ms, retry_count, error_count, operator_interventions | anomaly_score: 정상 공정 특성 대비 특이함 |
| Random Forest | 위 4개 + anomaly_score | inspection_risk_score: 합성 검사 fail의 미보정 predict_proba 시험 점수 |
| Autoencoder | HOME, PICK_ABOVE, PICK, GRAB, LIFT, PLACE, RELEASE | timeseries_anomaly_score: 정상 단계 시간 패턴과의 차이 |

Autoencoder는 7 → 12 → 3 → 12 → 7 MLP입니다. 연속 센서 시계열 대신 제품당
정해진 순서의 7개 공정 소요시간을 사용합니다. IF raw 값은 `-score_samples`,
AE raw 값은 표준화된 7개 입력의 평균 제곱 복원 오차입니다. 두 이상도는 정상
학습 raw 점수의 p05를 `lower`, p99 - p05를 `scale`로 저장하고,
`excess = max(raw - lower, 0)`, `score = excess / (excess + scale)`로 변환합니다.
p05 이하는 0, p99는 0.5이며 이상이 커지면 1에 가까워집니다. 0.5는 운영 판정
임계값이 아니며 두 이상도는 불량 확률이 아닙니다. 각 모델 점수 간 크기도
직접 비교할 수 없습니다. 구체적인 수치·버전·데이터 해시·시험 평가는 metadata에
저장됩니다. 같은 환경과 seed에서 재학습 결과를 재현할 수 있고 학습 시각은 바뀝니다.

## 노트북 추론

저장소 루트를 Python import 경로에 둔 노트북에서 신뢰하는 저장 모델을 로드합니다.

```python
import pandas as pd
from ai.modeling import DATA_DIR, SyntheticModels

rpf = pd.read_csv(DATA_DIR / "rpf.csv").head(3)
sequences = pd.read_csv(DATA_DIR / "rpf_sequences.csv").head(3)
models = SyntheticModels()
scores = models.predict(rpf, sequences)
display(scores)  # 합성 데이터 기반 시험 점수
```

두 DataFrame에 `product_id`가 있으면 ID로 맞춰 추론하고, 두 쪽 모두 없으면
행 순서를 사용합니다. 입력 feature는 이름으로 선택하므로 CSV의 grade와 검사
결과가 입력에 포함되지 않습니다. 학습 스크립트는 저장 전후의 시험 제품 전체
점수가 일치하는지 확인하며 smoke test는 정상형·중간 이상형·강한 이상형의
재로드 추론, 점수 범위, 라벨 배제, 제품 ID 정렬과 잘못된 입력 거부를 확인합니다.

기존 저장 모델로 RPF 30건을 준비하고 앱에서 확인하는 절차는 [PRESENTATION.md](PRESENTATION.md)를 참고하세요.
