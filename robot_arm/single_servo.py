#!/usr/bin/env python3
import argparse
import time

import serial


PORT = "/dev/ttyACM0"
BAUD_RATE = 115200
JOINT_PINS = (2, 3, 9, 8, 4, 5)


def wait_for(port, expected, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = port.readline().decode("ascii", errors="replace").strip()
        if line:
            print("Arduino:", line)
            if line == expected:
                return
            if line.startswith("ERR "):
                raise RuntimeError(line)
    raise TimeoutError(f"응답 시간 초과: {expected}")


def send(port, command, expected):
    print("전송:", command)
    port.write((command + "\n").encode("ascii"))
    port.flush()
    wait_for(port, expected)


def main():
    parser = argparse.ArgumentParser(
        description="선택한 Servo 하나만 Attach하여 지정 각도로 이동합니다."
    )
    parser.add_argument("joint", type=int, metavar="JOINT", help="Joint 번호 1~6")
    parser.add_argument("angle", type=int, metavar="ANGLE", help="목표 각도 0~180")
    parser.add_argument("--port", default=PORT, help=f"Serial 포트 (기본: {PORT})")
    args = parser.parse_args()
    if not 1 <= args.joint <= 6:
        parser.error("JOINT는 1~6이어야 합니다.")
    if not 0 <= args.angle <= 180:
        parser.error("ANGLE은 0~180이어야 합니다.")

    pin = JOINT_PINS[args.joint - 1]
    print(f"Joint {args.joint} / D{pin}만 {args.angle}°로 이동합니다.")
    input("로봇팔을 지지하고 Enter를 누르세요. 취소는 Ctrl+C: ")

    port = None
    try:
        port = serial.Serial(
            args.port,
            BAUD_RATE,
            timeout=0.2,
            write_timeout=1.0,
            exclusive=True,
        )
        time.sleep(2.0)
        port.reset_input_buffer()
        send(port, "PING", "PONG")
        send(port, "DETACH", "OK DETACH")
        send(port, f"SET {args.joint} {args.angle}", f"OK SET {args.joint} {args.angle}")
        input("이동을 확인한 뒤 Enter를 누르면 Servo를 Detach합니다: ")
    except (serial.SerialException, OSError, RuntimeError, TimeoutError) as exc:
        raise SystemExit(f"오류: {exc}") from exc
    except KeyboardInterrupt:
        print("\n중지합니다.")
    finally:
        if port is not None and port.is_open:
            try:
                port.write(b"DETACH\n")
                port.flush()
            except (serial.SerialException, OSError):
                pass
            port.close()


if __name__ == "__main__":
    main()
