# RPF 발표 환경 준비

## 통합 실행

저장소 루트에서 아래 명령 하나를 실행한다. Python `.venv`(서버/AI 의존성),
Flutter, Ollama, **이미 설치된 `qwen3:4b-instruct`**가 필요하다.

```bash
./scripts/run_presentation.sh
```

http://127.0.0.1:8080 에 접속한다. AI는 9000, Robot API는 8000을 사용한다.
Ollama가 실행 중이면 재사용하고, 꺼져 있으면 로컬 서비스를 시작한다. 모델이
없으면 안내 후 종료하며 자동 다운로드하지 않는다. 이후 AI 모델 로딩 → API의
30건 준비/분석 완료 → Flutter 빌드/서빙 순서로 진행한다. Ctrl+C로 이 스크립트가
시작한 프로세스만 종료한다. 외부에서 실행한 Ollama는 유지한다. 로그는
`server/data/presentation-runtime/`에 저장한다.

### 같은 네트워크의 태블릿에서 접속

PC와 태블릿을 같은 와이파이 또는 핫스팟에 연결한다. 기존 실행을 종료한 뒤,
PC의 현재 와이파이 IPv4 주소를 지정해서 실행한다. 아래 주소는 예시다.

```bash
PRESENTATION_LAN_IP=172.20.10.4 ./scripts/run_presentation.sh
```

태블릿 브라우저에서 `http://172.20.10.4:8080`을 연다. 이 옵션은 웹 앱과 API를
네트워크에 공개하고, 앱의 API 주소 및 해당 웹 주소의 CORS 허용을 함께 설정한다.
AI와 Ollama는 PC 내부 주소를 계속 사용한다. PC의 IP가 바뀌면 새 주소로 다시 실행한다.

### 실행 및 데이터 관리

중복 실행은 파일 잠금으로 차단한다. 8000/9000/8080 중 다른 서버가 사용 중인
포트가 있으면 해당 서버를 교체하거나 종료하지 않고 실행을 거부한다.

`PRESENTATION_MODE=true`인 Robot API는 **`server/data/presentation.db`**를 사용한다.
`PRESENTATION_DATABASE_PATH`로 별도 경로를 지정할 수 있다. 일반 `DATABASE_PATH`와
기본 `robot_arm.db`는 발표 경로로 사용할 수 없다. 소유 application ID가 없는 기존
DB는 자동 채택하지 않으며, 새 경로를 지정해야 한다. 기존 사용자 DB는 수정하지 않는다.

- 처음 시작할 때 기존 seed 정의 그대로 RPF-001~RPF-030을 생성한다.
- 준비 중에는 API의 시작 완료를 알리지 않는다. 기존 저장 IF/RF/AE 모델로 실제
  HTTP inference 30건을 수행하고 세 점수를 하나의 트랜잭션으로 저장한다.
- 완성된 30건과 점수는 재시작 시 그대로 사용한다. 누락된 점수는 다시 분석하고,
  불완전한 seed 소유 데이터만 복원한다. 소유하지 않은 RPF가 섞이면 삭제하지 않고 중단한다.
- 로봇의 Run/Event, 상태, WebSocket, 서보/포즈/안전 명령은 유지한다. 발표 모드의
  로봇 실행에서는 RPF 생성·완료와 자동 분석 예약을 건너뛴다. 품질 데이터는 항상
  30건이며 실행 이력은 별도로 남는다. 일반 모드의 저장 동작은 바뀌지 않는다.
- 앱은 서버가 준비한 값을 조회한다. Flutter만 단독 시작하면 API를 자동 실행하지 않는다.

## FMEA / Bayesian 원인 후보

`server/config/fmea_bayesian.json`에 여섯 원인, 고장 형태/영향, 점검 항목,
사전확률과 이산 CPT를 명시한다. 확률은 **발표를 위한 가정**이며 실제 공정에서
학습하거나 보정한 값이 아니다. 위치 오차 mm, 카메라 측정값, 실제 검사 판정은 생성하지 않는다.

작은 자체 BN은 범주형 `Cause` → 관측 노드 구조다. 제품 초기 위치, 그리퍼,
배치 위치, 통신/제어, 작업자 개입, 제품 식별 중 하나의 주원인을 가정하고
`P(C | E) ∝ P(C) × ∏ P(E_i | C)`를 여섯 상태에 대해 정확히 계산한다.
이 가정 안에서 원인들은 상호 배타적이고 관측은 원인이 주어졌을 때 조건부 독립이다.
현실의 동시 원인을 검증하거나 개입 효과를 추정하는 모델은 아니다.

재시도/개입 횟수와 집기 실패·배치 실패·시간 초과·ID 불일치 이벤트를 사용한다.
완료된 기록에서 없는 이벤트는 해당 이벤트 기록 없음(false), 진행 중 기록의 없는 이벤트는
unknown으로 주변화한다. 작업시간 초과는 명시적 이벤트로만 판단하며 임의의 시간
임계값을 만들지 않는다. error_count에 이미 포함된 특정 이상을 이중 집계하지 않도록
분류 가능한 관측이 있으면 별도 일반 오류 evidence는 제외한다.

전체 6개 posterior의 합은 1이다. API는 전체 후보와 상위 3개/나머지 확률을 반환한다.
상위 3개를 다시 100%로 정규화하지 않는다. 품질 상세와 코파일럿은 반드시
**현재 정의한 FMEA/Bayesian 모델 기준 원인 후보 확률**로 설명하며 실제 불량 확률이나
원인 확정으로 표현하지 않는다. 이상 관측이 없을 때도 그 사실을 표시한다.

제품 상세 API의 `presentation.cause_analysis`에서 확인할 수 있다. DB 스키마 추가나
새 학습 의존성은 없다. 조회 시 설정과 기록으로 계산하고 저장된 ML 점수는 변경하지 않는다.

코파일럿 예:
- `RPF-018 원인 후보 알려줘`
- `RPF-018에서 먼저 뭘 점검해야 해?`
- `우선검사 제품들의 원인 후보 비교해줘`

서버가 확률/표/점검 문장을 만들고 Ollama는 근거 ID만 선택한다. 원인 후보와 확률의
의미는 필수 근거라서 LLM이 생략하거나 임의의 확률로 교체할 수 없다. 사용자 화면과
답변에는 출처 배지를 표시하지 않으며 내부 synthetic_model/seed 소유 표시는 보존한다.

## 일반 모드에서 기존 DB 수동 준비

기존 모델을 재학습하지 않고 `ai/models/`의 Isolation Forest, Random Forest,
Autoencoder를 사용한다. 제품의 네 특징과 저장된 POSE_REQUESTED/POSE_FINISHED
시각으로 복원한 HOME~RELEASE 7단계 시간이 실제 추론 입력이다. 마지막 HOME
복귀는 제외한다. 모델 출력만 `analysis_results`에 저장하며 규칙 등급과 원본
이벤트 시각은 변경하지 않는다.

### 개별 실행

저장소 루트에서 기존 AI 환경을 사용한다.

```bash
# 터미널 1: 저장 모델 로드. 코파일럿을 쓰면 이미 설치한 Ollama 모델명도 설정.
OLLAMA_MODEL=qwen3:4b-instruct .venv/bin/python -m uvicorn ai.app.main:app --port 9000

# 기존 DB: 소유 표시가 있는 30건만 ID 마이그레이션 + 실제 추론.
.venv/bin/python scripts/prepare_rpf_presentation.py

# 터미널 2: 로봇 API. DB 경로를 바꿨다면 DATABASE_PATH도 동일하게 설정.
.venv/bin/python -m uvicorn server.app.main:app --port 8000

# 웹 앱
cd app
flutter build web --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/web
```

새 DB가 필요한 경우에만 `scripts/seed_demo_rpf.py --database PATH`로
RPF-001~RPF-030을 생성한 후 `prepare_rpf_presentation.py --database PATH`를
실행한다. seed 생성 도구는 단계 기록을 만들며 점수를 생성하지 않는다.
`--analysis-url`은 실행 중인 AI 서버 주소, `--migrate-only`는 ID만 이전하는 옵션이다.

## 데이터 보존

- CLI는 SQLite backup API로 WAL까지 포함한 `*.before-presentation-*.db`를 만든다.
- 기존 `DEMO_RPF_SEEDED` 이벤트와 `causalroboqc:seed_demo_rpf:v1` 마커가 모두
  있는 기록만 이전한다. 접두사만 같은 사용자 기록은 소유 근거가 아니다.
- ID와 해당 seed 소유 이벤트의 제품 ID만 바꾼다. PK, Run 연결, 등급, 시각,
  기존 분석값은 유지한다. 대상 ID 충돌은 전체 마이그레이션을 취소한다.
- 30건의 입력을 검증한 뒤 추론한다. 세 점수가 모두 반환되고 입력이 그대로일
  때만 한 트랜잭션으로 저장한다. 중간 실패·누락·동시 수정 시 기존 점수를 보존한다.
- 모델 출처와 seed 소유 정보는 내부 메타데이터로 유지한다. 앱·코파일럿에는
  출처 배지를 표시하지 않는다. 점수는 실제 검사 결과나 불량 확률로 표현하지 않는다.
- DB·백업·모델 변경은 Git 커밋에 포함하지 않는다. 새로운 환경은 위 명령으로 준비한다.

## 화면과 API

- `GET /api/rpf?include_analysis=true`는 각 제품에 `analysis_result`를 포함한다.
  옵션 없는 기존 목록 응답과 내부 RPF 레코드 형식은 유지한다.
- 대시보드·품질관리: 세 평균, 실제 저장 점수 추세, 펼쳐 보는 제품별 점수 표.
- 품질 목록·제품 상세·데이터 조회·CSV: 같은 저장 점수를 표시한다. 없는 값은
  빈칸/대기 상태로 두며 0이나 임의 값으로 채우지 않는다.
- 상세 `presentation`: 저장된 단계별 시간, 이벤트·횟수 기반 점검 순서,
  복사 가능한 품질보고서 초안. 조회는 추론이나 DB 쓰기를 수행하지 않는다.
- 코파일럿: `RPF-014가 왜 확인 필요야?`, `RPF-001과 RPF-002 비교해줘`,
  `최근 30개 제품 공정 단계 시간 이상도 그래프로 보여줘`,
  `RPF-014 점검 순서 알려줘`, `RPF-014 품질보고서 초안 작성해줘`.
  질문의 전제보다 저장된 규칙 등급을 우선한다. 기본 seed의 RPF-014는 정상이다.
- 보고서와 점검 안내는 서버의 저장 근거를 사용한다. Ollama는 검증된 근거 ID를
  선택하며 임의 점수·검사 판정·원인 확률을 생성하지 않는다. 상세 안내는 Ollama가
  꺼져 있어도 조회할 수 있다.

## Notion 계획과 대조

2026-09-17에 GitHub MCP로 main `758cd8d`와 다음 Notion 문서를 확인했다.

- [메인 아이디어 내용](https://app.notion.com/p/3b9409e342a9808395bff4ca1fe13655)
- [진행 상황 및 추가할 기능](https://app.notion.com/p/3cc409e342a98047b8abf9037614f876)
- [추후 계획](https://app.notion.com/p/3d1409e342a980f68865c3af64abef49)

데이터 조회·CSV·제품군·자동 분석·코파일럿은 이미 구현되어 있었다.
이번에는 점수 연결을 완성하고 단계별 시간, 기록 기반 권장 점검과 보고서 초안을
추가했다. 위 통합 모드에서 추가한 Bayesian 후보는 명시적 가정에 따른 계산이다.
카메라/ArUco, 실제 PASS/FAIL, 실제 센서는 구현된 것처럼 표시하지 않는다. 실제 검사 입력·실데이터 재학습·카메라 연동은
별도 후속 범위다. 현재 저장 모델의 합성 데이터 학습 이력·한계는 metadata에 유지한다.

## 검증

통합 모드 추가 후 확인: 기존 서버 49개 + 발표/BN/실행기 14개, AI 12개,
Flutter 34개 테스트 통과. `flutter analyze`와 웹 빌드 통과. 실제 통합 스크립트로
30건/90개 점수 준비, 중복 실행 거부, 종료 정리를 확인했다. 실제 Ollama
`qwen3:4b-instruct`로 원인·점검·등급별 비교 질문과 UI 응답을 확인했고, 브라우저에서
상세 후보 확률/API 일치, 대시보드·조회·CSV·모바일·출처 문구 미노출을 확인했다.
로봇 API와 안전 제어는 시리얼 응답 fixture로 검증했으며 물리 로봇 구동 검증은 아니다.

```bash
.venv/bin/python -m unittest discover -s server/tests -v
.venv/bin/python -m unittest discover -s ai/tests -v
cd app
flutter analyze
flutter test
flutter build web --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:18000
cd ..
.venv/bin/python -m server.tests.copilot_browser_fixture
```

Playwright MCP의 `browser_run_code_unsafe`로 `scripts/check_copilot_browser.js`를
실행한다. 임시 DB의 30건은 실제 저장 모델로 추론하고 Ollama 응답 선택만 fixture를
사용한다. 세 그래프의 각 점을 DB와 대조하고, 화면/응답에 출처 표기가 없는지,
메뉴 전환·연결 실패·모바일 화면을 검사한다. 실제 실행 환경에서도 설치된 Ollama로
질문 응답을 확인한다. 검증 후 8000 포트용 앱을 다시 빌드한다.

최종 앱에서는 `scripts/check_presentation_browser.js`를 실행해 대시보드,
품질 목록 30건, 상세 점수·7단계 시간·보고서, 데이터 조회 2페이지·CSV 다운로드,
로봇 제어 화면과 모바일 화면의 표시를 확인한다.

2026-09-17 검증: 서버 49개, AI 11개, Flutter 33개 테스트 통과.
`flutter analyze`, `flutter build web` 통과. 두 Playwright 스크립트와
실제 Ollama `qwen3:4b-instruct`를 통한 제품 설명·비교·세 점수 그래프·보고서
질문 6건을 확인했다. 로컬 DB 30건의 PK·규칙 등급·원본 시각·Run 연결 보존과
저장 모델 SHA-256 불변을 백업과 대조했다. 물리 로봇·카메라 동작 검증은 포함하지 않는다.
