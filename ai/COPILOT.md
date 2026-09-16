# CausalRoboQC AI 코파일럿 v1

## 실행

Ollama 설치와 모델 준비는 사용자가 직접 합니다. 앱과 서버는 설치나 다운로드를
자동 실행하지 않습니다. 사용할 모델을 준비한 노트북에서:

```bash
ollama serve
```

다른 터미널에서 저장소 루트의 기존 AI 가상환경을 사용합니다.

```bash
source .venv/bin/activate
python -m pip install -r ai/requirements.txt
export OLLAMA_MODEL='준비한 모델 이름'
export OLLAMA_BASE_URL=http://127.0.0.1:11434
export OLLAMA_TIMEOUT_SECONDS=45
uvicorn ai.app.main:app --host 0.0.0.0 --port 9000
```

모델명 기본값은 없습니다. Ollama의 `/api/chat` JSON schema 출력 지원을 사용합니다.
참고: [Ollama Chat API](https://docs.ollama.com/api/chat).

Pi의 기존 FastAPI는 `ANALYSIS_BASE_URL=http://노트북주소:9000`을 재사용합니다.
`COPILOT_TIMEOUT_SECONDS` 기본값은 55초이며, 기존 ML/DL의
`ANALYSIS_TIMEOUT_SECONDS`와 분리됩니다. Flutter의 요청 제한은 65초입니다.
Ollama 제한을 늘리면 Pi와 Flutter의 요청 제한도 그보다 길게 맞춰야 합니다.
Pi에는 Ollama/ML/LLM 라이브러리를 설치하지 않습니다.

Docker Compose 사용 시 서버 환경에 `ANALYSIS_BASE_URL`과 필요시
`COPILOT_TIMEOUT_SECONDS`를 전달하세요. 컨테이너의 127.0.0.1은 노트북 주소가 아닙니다.

Ollama가 꺼져 있거나 모델이 없으면 **코파일럿만 unavailable**입니다.
서버 시작, 로봇 제어, RPF·규칙 등급, 기존 ML/DL, 조회·CSV, Flutter는 계속 작동합니다.
Ollama는 질문 요청에서만 호출하며 설치·다운로드·시작 시 연결 확인은 하지 않습니다.
연결 실패, 시간 초과, 잘못된 응답에는 공통 한국어 안내만 표시합니다.

## 데이터 흐름과 근거

Flutter → Pi `POST /api/copilot/chat` (`{"question":"..."}`) → 기존 SQLite
RPF/Event/analysis_results 조회·집계 → 노트북의 같은 경로 → Ollama → 응답입니다.
응답은 `answer`, `table` 또는 null, `chart` 또는 null, `demo_data`를 포함합니다.
노트북은 DB에 접근하지 않습니다. Pi의 질의 모듈만 허용된 읽기 함수를 실행합니다.

v1은 규칙 기반 intent routing입니다. LLM에 SQL이나 함수 실행 권한을 주지 않습니다.
Pi가 실제 데이터로 한국어 근거 문장과 표·차트를 생성하고, LLM이 관련 근거 ID를
선택·정렬합니다. 노트북과 Pi에서 ID를 검사하고 Pi가 원본 근거로 답변을 재구성합니다.
LLM의 자유 생성 문장이나 수치는 표시하지 않으므로 프롬프트만으로 허구 수치를
막는 방식에 의존하지 않습니다. 등급·점수·원인은 새로 판정하지 않습니다.
기록되지 않은 인과 원인과 특징 기여도는 확인할 수 없다고 안내합니다.

지원: 제품 ID 상세/최대 5개 비교, 제품군 비교, 제품 목록/상위 점수, 기간 요약,
이상 제품의 기록된 공통 판정 근거, 등급 분포, 공정 지표·등급 추세, 기록 기반 점검 순서·품질보고서 초안, 앱 사용법.
사용법은 `server/app/knowledge/`의 작은 문서만 읽으며 Docker에도 함께 포함됩니다.
`이 제품`처럼 ID가 없는 질문은 ID를 요청합니다. 이전 대화에서 필터를 추측하지 않습니다.

기간은 완료 시각 기준입니다. `최근 N일`, `최근 N주`, 오늘/어제,
`YYYY-MM-DD` 또는 시작일·종료일을 지원합니다. 날짜는 한국 시간이며 종료일을 포함합니다.
기간 없는 집계는 전체 저장 데이터, `최근`만 있으면 최근 7일,
`최근 N개`는 전체 기간 중 최신 N개입니다. 제품 ID 상세는 해당 ID를 직접 조회합니다.
목록·개별 제품 차트는 최대 50개, 제품군 차트는 이름순 최대 50개,
등급 추세는 데이터가 있는 최근 최대 50일입니다. 요약 평균은 전체 조회 범위에서
해당 값이 저장된 제품만 분모로 사용합니다.

차트는 서버가 만든 bar/line JSON을 Flutter 기본 CustomPainter로 표시합니다.
추가 차트 패키지는 없고, null은 0으로 보간하지 않습니다. 원본 값은 옆의 표에서도
확인할 수 있습니다. 분석이 전혀 없으면 `분석 결과 없음`으로 표시합니다.
데모 여부는 제품 ID 이름이나 합성 모델 여부가 아닌 기존 seed 소유 이벤트로 확인합니다.
출처 메타데이터는 내부적으로 유지하며 앱과 답변에는 출처 배지를 표시하지 않습니다. 없는 제품은
`현재 데이터에서 확인할 수 없습니다.`로 응답하며 추측하지 않습니다.

`GET /api/copilot/health`는 Ollama를 호출하지 않습니다. 노트북은 모델 환경변수
설정 여부(configured/unavailable), Pi는 라우터 상태만 표시합니다.
`ollama_checked: false`이므로 실행 중인 모델의 가용성을 의미하지 않습니다.

## UI와 검증

기존 네 메뉴 위에 공통 Stateful 오버레이를 둡니다. 데스크톱은 우측 하단 48px
아이콘과 420px × 최대 640px 패널, 모바일은 키보드를 피하는 넓은 하단 패널입니다.
별도 페이지·Route·메뉴·배경 dim은 없습니다. 닫기·메뉴 이동 후에도 대화가 유지됩니다.

```bash
python -m unittest discover -s ai/tests -v
python -m unittest discover -s server/tests -v
cd app
flutter analyze
flutter test
flutter build web
```

테스트는 임시 SQLite의 기존 Demo seed와 명시적 분석 fixture, mock Ollama를
사용합니다. 기존 seed, 실제 DB, 모델을 수정하지 않습니다. 실제 모델 품질·응답 속도는
사용자가 선택한 모델과 노트북 사양에 따라 별도로 확인해야 합니다.

브라우저 재현: `flutter build web --dart-define=API_BASE_URL=http://127.0.0.1:18000`
후 저장소 루트에서 `python -m server.tests.copilot_browser_fixture`를 실행합니다.
Playwright MCP의 `browser_run_code_unsafe`에 `scripts/check_copilot_browser.js`의
절대 경로를 filename으로 전달하면 메뉴 이동·질의·OFF·모바일 흐름을 검증합니다.
fixture는 임시 DB만 사용하고 로봇 시작을 차단합니다. 검증 후 Ctrl-C로 종료합니다.

기존 seed ID 이전과 실제 모델 분석값 준비, 추가된 화면은 [PRESENTATION.md](PRESENTATION.md)를 참고하세요.
