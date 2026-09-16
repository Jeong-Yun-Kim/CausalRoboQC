# RPF 발표 환경 준비

기존 모델을 재학습하지 않고 `ai/models/`의 Isolation Forest, Random Forest,
Autoencoder를 사용한다. 제품의 네 특징과 저장된 POSE_REQUESTED/POSE_FINISHED
시각으로 복원한 HOME~RELEASE 7단계 시간이 실제 추론 입력이다. 마지막 HOME
복귀는 제외한다. 모델 출력만 `analysis_results`에 저장하며 규칙 등급과 원본
이벤트 시각은 변경하지 않는다.

## 실행

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
추가한다. 카메라/ArUco, 실제 PASS/FAIL, 실제 센서, 검증되지 않은 베이지안 원인
확률은 구현된 것처럼 표시하지 않는다. 실제 검사 입력·실데이터 재학습·카메라 연동은
별도 후속 범위다. 현재 저장 모델의 합성 데이터 학습 이력·한계는 metadata에 유지한다.

## 검증

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
