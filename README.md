# CausalRoboQC 실기기 통합 구조

소프트웨어 및 fixture 기반 검증 완료, 실기기 검증 필요.
이 변경에서는 Arduino/서보, USB 카메라, 실제 시리얼 포트, Raspberry Pi,
포터블 모니터, LAN/핫스팟 장비를 사용한 검증이나 배포를 수행하지 않았다.

## 구성

| 위치 | 프로세스 | 주소/역할 |
| --- | --- | --- |
| Raspberry Pi (64-bit OS) | FastAPI, SQLite, OpenCV ArUco, Arduino USB Serial | `:8000` |
| Raspberry Pi | Nginx, Flutter Web | `:8080`, API/WebSocket/카메라 프록시 |
| 노트북 | 기존 ML/DL 모델 추론 API | `:9000` |
| 노트북 | Ollama `qwen3:4b-instruct` | `127.0.0.1:11434` |
| Pi 직접 연결 모니터 | Chromium | `http://127.0.0.1:8080` |
| 같은 LAN/핫스팟의 태블릿 | 브라우저 | `http://Pi_IP:8080` |

Pi는 `ANALYSIS_BASE_URL=http://노트북_IP:9000`으로 연결한다. AI 연결 실패는
RPF 완료·규칙 판정·로봇 제어·카메라·앱 가용성을 바꾸지 않는다. 분석 결과는
성공한 경우에만 저장하며 실패한 완료 RPF는 기존 `/api/rpf/{id}/analyze`로
재시도할 수 있다. 모델 재학습은 수행하지 않는다. 기존 IF/RF/Autoencoder
아티팩트는 합성 데이터 기반이며 내부 metadata를 유지한다.

## 카메라와 사이클

| 환경변수 | 기본값 | 의미 |
| --- | --- | --- |
| `VISION_ENABLED` | `false` | ArUco 제품 확인 사용 |
| `VISION_REQUIRED` | `false` | 비전 준비 실패 시 Run 시작 차단 |
| `CAMERA_DEVICE` | `/dev/video0` | OpenCV가 소유할 장치 |
| `VISION_CONFIG_PATH` | `server/config/vision.json` (저장소 기준 절대 경로) | ROI/안정 프레임/타임아웃 |
| `CAMERA_PREVIEW_MODE` | `browser` | `browser`, `server`, `off` |
| `SERIAL_DEVICE` | `/dev/ttyACM0` | 기존 `SERIAL_PORT`보다 우선 |
| `ANALYSIS_BASE_URL` | `http://127.0.0.1:9000` | 노트북 추론 서버 |
| `PRESENTATION_MODE` | `false` | 별도 DB의 발표용 30개 RPF 유지 |

Pi compose의 기본값은 `VISION_ENABLED=true`, `VISION_REQUIRED=true`,
`CAMERA_PREVIEW_MODE=server`이다. FastAPI는 **worker 1개**로 실행한다.
프로세스 하나만 USB 카메라와 시리얼을 소유해야 한다.

* `browser`: 기존 명시적 시작 버튼으로 getUserMedia 사용. 서버 캡처는 하지 않는다.
  `VISION_ENABLED=true`와 함께 설정하면 비전 설정 오류 상태로 남으며 서버는 기동한다.
* `server`: 브라우저 getUserMedia를 사용하지 않는다. 단일 OpenCV 공급부가 공유하는
  최신 프레임을 `/api/camera/snapshot` 또는 `/api/camera/stream`(MJPEG)으로 제공한다.
  Flutter는 snapshot을 순차 요청하며 연결 실패 시 안내 후 재시도한다.
* `off`: 영상 endpoint와 앱 미리보기 비활성. `VISION_ENABLED=true`이면 검출은 계속한다.

프레임·overlay·JPEG는 메모리에만 존재한다. 녹화, 이미지 파일 저장, 이미지 업로드는
하지 않는다. overlay는 ArUco ID, 입력/출력 ROI, 활성 마커 ID만 표시한다.

`vision.json`은 `DICT_4X4_50`, normalized `[x, y, width, height]` ROI,
`stable_frames`, `place_timeout_seconds`를 사용한다. 마커 중심이 ROI 내부인지 판정하며
ROI는 서로 겹칠 수 없다. 기본 ROI는 구성 예시이며 실제 배치에 맞춰 조정해야 한다.

1. 입력 ROI의 단일 동일 ID가 연속 N개 처리 프레임에서 검출되면 잠근다.
2. Run 시작 시 입력 ROI에 잠긴 ID가 여전히 있는지 확인한 뒤 예약하고 해당 사이클 RPF의 `marker_id`에 저장한다.
   `product_id`는 마커 재사용과 무관한 `P-<UUID>`로 생성한다.
3. 사이클 도중 가려져도 ID를 유지한다. LIFT 완료 후 입력 ROI에서 해당 ID가
   사라지는 관측이 있어야 `PICK_VERIFIED` 이벤트를 기록한다.
4. RELEASE 완료 이후 출력 ROI의 동일 ID가 N개 연속 프레임에서 검출되고
   PICK도 확인되면 `PLACE_VERIFIED`, RPF 완료, 기존 ML/DL 자동 분석 예약 순으로 처리한다.
   복귀 HOME은 로봇 Run의 후속 동작이며 이미 확인된 배치 결과를 덮어쓰지 않는다.
5. 출력 ROI에 다른 ID가 있으면 `PRODUCT_ID_MISMATCH`; RELEASE 기준 제한시간이
   지나면 `PLACE_TIMEOUT`. 카메라가 끊겨도 타이머는 진행한다. 해당 RPF/Run은 실패로
   종료하고 실패 이벤트와 규칙 등급을 저장한다. 같은 마커의 다음 사용은 새 RPF다.
6. 반복 실행은 다음 입력 ID가 잠길 때까지 대기한다. 기존 Stop으로 대기를 취소할 수 있다.

ID/ROI 확인은 픽업의 시각적 근거이며 물리적 그립 성공이나 mm/각도 정밀도를 보증하지
않는다. 보정값 없는 위치·회전 오차를 생성하지 않는다.

`VISION_REQUIRED=true`인 경우 카메라/비전이 준비되지 않으면 Run만 거부한다.
`VISION_ENABLED=true`, `VISION_REQUIRED=false`에서 카메라가 준비되지 않은 경우
기존 로봇 Run은 허용하되 마커 없는 RPF는 생성하지 않는다. 카메라가 준비되어 있으나
안정적인 입력 ID가 없으면 Run은 대기 안내와 함께 거부한다. `VISION_ENABLED=false`는
기존 비전 없는 사이클 경로를 유지한다. 이 경로는 배치가 시각 검증된 것으로 표시하지 않는다.

발표 모드는 기존 전용 DB의 `RPF-001`~`RPF-030`을 유지한다. 로봇/카메라 상태와 실행
이벤트를 확인할 수 있지만 로봇 실행으로 발표용 RPF를 추가하지 않는다. AI가 없으면
발표 RPF/규칙/앱은 기동하며 미완료 분석은 비어 있는 상태로 남는다.

## 실제 검사 결과

SQLite 기동 시 기존 테이블/레코드를 삭제하지 않고 `marker_id` 컬럼과 `inspections`
테이블을 추가한다. `rpf_id` 외래키/기본키로 제품당 현재 검사 결과 1건을 보관한다.

`PUT /api/rpf/{rpf_id}/inspection`:

```json
{"result":"FAIL","confirmed_causes":["표면 손상"],"action":"재검사","note":"작업자 확인"}
```

`inspected_at`은 서버 UTC 시각으로 생성·수정된다. 제품 상세의 실제 검사 결과 폼에서
저장/수정하고 상세·목록·데이터 조회·CSV에서 확인한다. CSV에는 마커 ID, 검사 결과,
원인, 조치, 메모, 검사 시각이 포함된다. 사용자 입력은 스프레드시트 수식 실행을
막도록 이스케이프한다. inspection은 grade/분석 결과를 변경하지 않으며 향후
Random Forest 정답 라벨로 사용하기 위한 저장만 수행한다. 현재 모델은 갱신하지 않는다.

## 배포 준비와 이후 실기기 실행

다음 실행 절차는 나중에 사용자가 실기기에서 수행할 지침이다. 이 변경에서 실행하지 않았다.

1. 노트북에 기존 Python AI 의존성과 Ollama를 준비하고 `qwen3:4b-instruct`를 설치한다.
   `scripts/run_notebook_ai.sh --dry-run`으로 명령을 확인한다. 나중에 `--start`로
   Ollama `/api/tags`와 모델 존재를 확인한 뒤 AI 서버를 `0.0.0.0:9000`에 기동한다.
   자동 모델 다운로드나 학습은 하지 않는다.
2. 노트북에서 Web을 빌드한다: `cd app && flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=/`.
   Pi용 `app/Dockerfile.pi`는 이 `app/build/web` 산출물을 Nginx에 넣는다.
   저장소와 함께 Web 산출물도 나중에 Pi에 전달해야 한다(산출물은 gitignore 대상).
   Pi에서 Flutter SDK/브라우저 빌드 이미지를 실행할 필요가 없다.
3. Pi에서 `.pi.env.example`을 `.pi.env`로 복사하고 노트북 IP와 장치 경로를 설정한다.
   env 파일은 예시처럼 따옴표 없는 `KEY=value` 형식을 사용한다.
   `scripts/run_pi.sh --check`는 경로 존재만 확인하고 실행 명령·주소를 출력한다.
   장치를 열거나 Docker/HTTP를 실행하지 않는다.
4. 이후 `scripts/run_pi.sh --start`가 별도 `docker-compose.pi.yml`로 FastAPI/Nginx를
   실행한다. `--health`는 API/App/Camera 상태를 HTTP로 확인한다.
   `scripts/kiosk.sh --dry-run`은 명령만 출력하고, 이후 `--start`가 앱 응답을 기다린 뒤
   Chromium kiosk를 실행한다. systemd 파일은 `deploy-examples/`의 미설치 예시다.

compose는 선택한 serial/camera만 devices로 전달하고 `privileged`나 전체 `/dev`
마운트를 사용하지 않는다. SQLite 볼륨은 일반 Docker 재기동으로 삭제하지 않는다.
장치가 빠진 상태에서는 Docker의 device 매핑 자체가 시작을 막을 수 있다. 이 경우
누락된 장치의 devices 항목을 별도 override에서 제거하고 `VISION_REQUIRED` 정책을
선택한다. API 내부에서는 카메라/AI 장애가 전체 기동 실패를 유발하지 않는다.

핫스팟/같은 LAN에서 노트북 `9000`, Pi `8080`으로 연결한다. Ollama는 노트북 내부에
두어도 된다. App은 같은 origin의 Nginx 프록시를 사용하므로 태블릿에서 `localhost`
API로 연결하지 않는다. 실험실의 신뢰할 수 있는 LAN용이며 외부 공개 배포는 범위 밖이다.

## 소프트웨어 검증

이번 변경의 검증 결과: Python 전체 회귀 91개 통과 후 추가된 5개를 포함한
비전/통합 19개 재검증 통과(서로 다른 테스트 총 96개), Flutter widget 37개 통과,
`flutter analyze` 및 Web release 빌드 통과, Playwright fixture 3개 시나리오 통과.
실제 하드웨어 검증은 별도 필요하다.

```bash
.venv/bin/python scripts/test_software.py
cd app
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=/
```

Python 진입점은 실제 `serial.Serial`, `cv2.VideoCapture`, 외부 HTTP transport를 차단한다.
ArUco 이미지는 메모리에서 생성하며 SQLite는 임시 경로를 사용한다. 배포 테스트는
`docker compose config` 파싱만 하며 Docker daemon/컨테이너/장치에 접근하지 않는다.
스크립트 dry-run 검증은 임시 파일 장치와 실패하도록 만든 명령 fixture를 사용한다.

Playwright: `.venv/bin/python -m server.tests.live_browser_fixture`를 실행하고
`scripts/check_live_browser.js`를 Playwright의 `browser_run_code_unsafe`에 전달한다.
`127.0.0.1:18081`의 임시 DB·메모리 ArUco 프레임만 사용하고 browser getUserMedia 호출을
금지한다. 기존 `check_camera_browser.js`는 실제 카메라용이므로 이번 검증에서 사용하지 않는다.

나중에 확인할 항목: 실제 USB 권한/재연결, 프레임 속도와 조명·마커 크기·ROI,
로봇 LIFT/RELEASE 타이밍, 카메라 가림, 시리얼 안전 정지, Pi arm64 이미지 기동,
핫스팟 연결/방화벽, 모니터 해상도·kiosk, 노트북 AI/Ollama 응답.
