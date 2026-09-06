# RPF 분석 연결

기존 모델을 재학습하거나 CSV를 생성하지 않고 사용합니다. 노트북만 모델을
로드하며, Robot API 서버는 RPF 준비·HTTP 호출·SQLite 저장만 담당합니다.
규칙 기반 grade/grade_reasons는 분석 요청으로 바뀌지 않습니다.

## 노트북 AI 서버

저장소 루트에서 기존 ML 가상환경을 활성화하고 실행합니다.

```bash
source .venv/bin/activate
python -m pip install -r ai/requirements.txt
uvicorn ai.app.main:app --host 0.0.0.0 --port 9000
```

시작 시 `SyntheticModels`를 프로세스당 한 번 로드합니다. 기존 모델/scaler/
metadata를 사용하며 CPU에서 추론합니다. `GET /health`로 로드 완료를 확인하고,
`POST /api/analyze/rpf`에 `rpf_id`, `product_id`, 네 feature와 선택적인 sequence를
보냅니다. sequence가 없거나 7개 값 중 일부가 없으면 IF/RF만 실행하고
`timeseries_anomaly_score`는 null입니다. 잘못된 음수·문자열·비정수 count 등의
입력은 422입니다.

## Robot API 서버

Robot 서버 환경에는 `server/requirements.txt`만 설치합니다. ML 의존성과 모델
로드가 필요하지 않습니다. 기존 서버 실행 환경에서 다음 설정을 사용합니다.

```bash
export ANALYSIS_BASE_URL=http://127.0.0.1:9000
export ANALYSIS_TIMEOUT_SECONDS=3
uvicorn server.app.main:app --host 0.0.0.0 --port 8000
```

두 서버가 다른 장치에 있으면 `ANALYSIS_BASE_URL`을 노트북 hotspot IP의
`http://192.168.x.x:9000` 형태로 바꾸고 Robot 서버를 다시 시작합니다. 이 주소는
Flutter의 `API_BASE_URL`과 다릅니다. Flutter는 계속 Robot API 서버에 접속합니다.

`POST /api/rpf/{id}/analyze`는 완료된 RPF만 받습니다. 네 입력은 저장된
`work_time_ms`, `retry_count`, `error_count`, `operator_interventions`입니다.
RPF에 연결된 이벤트를 기록 순서대로 읽어 POSE_REQUESTED/POSE_FINISHED를
짝지으며, pose·step_index·cycle과 시간 순서를 검사합니다. 요청부터 완료까지의
실측 ms를 HOME/PICK_ABOVE/PICK/GRAB/LIFT/PLACE/RELEASE 순서로 전달합니다.
마지막 HOME 복귀는 제외합니다. 반복 pose·오류 경로·누락·0/음수 시간·겹치는
단계 등 명확히 짝지을 수 없는 기록은 sequence=null로 처리합니다.

SQLite 시작 시 `CREATE TABLE IF NOT EXISTS analysis_results`로 테이블을 추가하며
기존 데이터는 유지합니다. 성공 결과를 RPF ID 기준 upsert하고 분석 시각과
모델 정보를 저장합니다. `GET /api/rpf/{id}`는 기존 필드와 events에
`analysis_result`를 추가합니다(미분석이면 null). 노트북 연결 실패/timeout은 503,
잘못된 노트북 응답은 502이며 이전 분석 결과와 다른 API는 유지합니다.

## 앱과 점수 의미

품질관리 제품 상세 Dialog에서 AI 분석 실행을 누릅니다. 분석 중 버튼을
비활성화하고, 성공하면 공정 이상도·검사 위험도·시계열 이상도를 표시합니다.
Dialog를 다시 열면 DB에 저장된 결과를 불러옵니다. sequence가 없으면 시계열은
데이터 부족으로 표시합니다. 실패 시 오류와 재시도 버튼을 표시하고 이전 결과를
유지합니다.

공정 이상도는 정상 공정 대비 특이함이고, 시계열 이상도는 정상 단계 시간 패턴과의
차이입니다. 불량 확률이 아닙니다. 검사 위험도도 합성 데이터로 학습한 미보정 시험
점수입니다. metadata의 `synthetic_data`를 `synthetic_model`로 전달하고 앱에
합성 데이터 기반 시험 모델 안내를 표시합니다. 실제 제조 성능을 주장하지 않습니다.

## 하드웨어 없는 검증

```bash
python -m unittest discover -s ai/tests -v
python -m unittest discover -s server/tests -v
python -m compileall ai/app server/app server/tests ai/tests
cd app
flutter analyze
flutter build web
```

API 테스트는 실제 저장 모델, 임시 SQLite, 명시적인 pose 이벤트 fixture 및
httpx MockTransport를 사용합니다. RobotService 시작은 mock 처리하므로 로봇에
접속하지 않습니다. 하드웨어 연결 후에는 RPF별 이벤트 짝/시각/단위, 최종 HOME
제외, 노트북 IP 도달성 및 실제 요청 지연을 확인해야 합니다.
