#!/usr/bin/env python3
import time
import tkinter as tk
from tkinter import ttk

import serial


PORT = "/dev/ttyACM0"
BAUD_RATE = 115200
JOINT_PINS = (2, 3, 9, 8, 4, 5)
SERVO_LIMITS = ((0, 180),) * 6

root = None
status_var = None
selected_var = None
selected_label = None
angle_label = None
scale = None
joint_buttons = []
motion_widgets = []
stop_button = None
detach_button = None
estop_button = None
reset_button = None
attach_button = None

port = None
connected = False
estop_latched = False
selected = None
selection_ready = False
servo_attached = False
attach_pending = False
detach_mode = None
display_angles = [90] * 6
ignore_scale = False
send_after_id = None
pending_angle = None
ping_deadline = 0.0
rx_buffer = bytearray()
closing = False


def set_status(text):
    status_var.set(text)


def close_port():
    global port, connected, ping_deadline, rx_buffer
    connected = False
    ping_deadline = 0.0
    rx_buffer = bytearray()
    old_port = port
    port = None
    if old_port is not None:
        try:
            old_port.close()
        except (serial.SerialException, OSError):
            pass


def cancel_pending_angle():
    global send_after_id, pending_angle
    if send_after_id is not None:
        try:
            root.after_cancel(send_after_id)
        except tk.TclError:
            pass
    send_after_id = None
    pending_angle = None


def reset_selection():
    global selected, selection_ready, servo_attached, attach_pending, detach_mode
    cancel_pending_angle()
    selected = None
    selection_ready = False
    servo_attached = False
    attach_pending = False
    detach_mode = None
    selected_var.set(-1)
    selected_label.configure(text="선택 Joint: 없음")
    angle_label.configure(text="명령각: 미설정")


def connection_lost(detail):
    global estop_latched
    close_port()
    reset_selection()
    estop_latched = False
    update_controls()
    set_status(f"연결 끊김: {detail}")


def write_line(command, require_connection=True):
    if port is None or not port.is_open or (require_connection and not connected):
        return False
    data = (command + "\n").encode("ascii")
    try:
        if port.write(data) != len(data):
            raise serial.SerialTimeoutException("전송 시간 초과")
        return True
    except (serial.SerialException, OSError) as exc:
        connection_lost(str(exc))
        return False


def send_ping():
    global ping_deadline
    if port is None or not port.is_open:
        return
    try:
        port.reset_input_buffer()
    except (serial.SerialException, OSError) as exc:
        connection_lost(str(exc))
        return
    if write_line("PING", require_connection=False):
        ping_deadline = time.monotonic() + 1.5


def connect():
    global port, estop_latched
    close_port()
    reset_selection()
    estop_latched = False
    update_controls()
    try:
        port = serial.Serial(
            PORT,
            BAUD_RATE,
            timeout=0,
            write_timeout=0.2,
            exclusive=True,
        )
        set_status(f"Arduino 준비 대기 중: {PORT}")
        root.after(2200, send_ping)
    except (serial.SerialException, OSError) as exc:
        port = None
        set_status(f"연결 실패: {exc}")


def handle_ok(parts):
    global estop_latched, selection_ready, servo_attached, attach_pending, detach_mode
    if len(parts) < 2:
        return
    command = parts[1]
    if command == "SET" and len(parts) == 4:
        try:
            joint = int(parts[2]) - 1
            angle = int(parts[3])
        except ValueError:
            return
        if joint == selected:
            servo_attached = True
            attach_pending = False
            angle_label.configure(text=f"명령각: {angle}°")
    elif command == "DETACH":
        if detach_mode == "select" and selected is not None:
            selection_ready = True
            servo_attached = False
            attach_pending = False
            detach_mode = None
            set_status("첫 명령각을 정한 뒤 Attach 버튼을 누르세요.")
        else:
            reset_selection()
            set_status("모든 Servo Detach")
    elif command == "ESTOP":
        estop_latched = True
        set_status("EMERGENCY STOP")
    elif command == "RESET":
        estop_latched = False
        selection_ready = selected is not None
        set_status("E-STOP 해제")
    elif command == "STOP":
        set_status("현재 명령 위치에서 정지")
    update_controls()


def handle_line(line):
    global connected, ping_deadline, estop_latched, attach_pending
    parts = line.split()
    if not parts:
        return
    response = parts[0]
    if response == "PONG" and ping_deadline:
        ping_deadline = 0.0
        connected = True
        set_status(f"연결됨: {PORT} — Joint를 선택하세요.")
        write_line("STATUS")
        update_controls()
    elif response == "READY" and connected:
        connected = False
        reset_selection()
        update_controls()
        set_status("Arduino 재시작 감지")
        root.after(200, send_ping)
    elif response == "OK":
        handle_ok(parts)
    elif response == "STATUS" and len(parts) == 16:
        try:
            estop_latched = bool(int(parts[3]))
        except ValueError:
            return
        update_controls()
    elif response == "ERR":
        attach_pending = False
        if parts[1:2] == ["ESTOP"]:
            estop_latched = True
        update_controls()
        set_status("Arduino 오류: " + " ".join(parts[1:]))


def poll_serial():
    global rx_buffer
    if closing:
        return
    if port is not None and port.is_open:
        try:
            waiting = port.in_waiting
            if waiting:
                rx_buffer.extend(port.read(waiting))
                while b"\n" in rx_buffer:
                    raw, _, rx_buffer = rx_buffer.partition(b"\n")
                    line = raw.rstrip(b"\r").decode("ascii", errors="replace").strip()
                    if line:
                        handle_line(line)
        except (serial.SerialException, OSError) as exc:
            connection_lost(str(exc))
    if ping_deadline and time.monotonic() >= ping_deadline:
        connection_lost("PONG 응답 없음 — 먼저 main.cpp를 Upload하세요.")
    root.after(20, poll_serial)


def select_joint(index):
    global selected, selection_ready, servo_attached, attach_pending, detach_mode, ignore_scale
    if not connected or estop_latched:
        selected_var.set(selected if selected is not None else -1)
        return
    cancel_pending_angle()
    selected = index
    selection_ready = False
    servo_attached = False
    attach_pending = False
    detach_mode = "select"
    selected_label.configure(text=f"선택 Joint: Joint {index + 1} / D{JOINT_PINS[index]}")
    angle_label.configure(text="명령각: 미설정")
    ignore_scale = True
    scale.configure(from_=SERVO_LIMITS[index][0], to=SERVO_LIMITS[index][1])
    scale.set(display_angles[index])
    ignore_scale = False
    update_controls()
    if write_line("DETACH"):
        set_status(f"Joint {index + 1} 단독 테스트 준비 중 (모두 Detach)")


def send_angle_now():
    global send_after_id, pending_angle
    send_after_id = None
    angle = pending_angle
    pending_angle = None
    if selected is not None and selection_ready and servo_attached and angle is not None:
        write_line(f"SET {selected + 1} {angle}")


def scale_changed(value):
    global send_after_id, pending_angle
    if ignore_scale or selected is None or not selection_ready:
        return
    low, high = SERVO_LIMITS[selected]
    angle = max(low, min(high, int(round(float(value)))))
    display_angles[selected] = angle
    if not servo_attached:
        angle_label.configure(text=f"첫 명령 후보: {angle}°")
        return
    pending_angle = angle
    if send_after_id is not None:
        root.after_cancel(send_after_id)
    send_after_id = root.after(40, send_angle_now)


def step_angle(amount):
    global ignore_scale
    if selected is None or not selection_ready:
        return
    cancel_pending_angle()
    low, high = SERVO_LIMITS[selected]
    angle = max(low, min(high, int(scale.get()) + amount))
    display_angles[selected] = angle
    ignore_scale = True
    scale.set(angle)
    ignore_scale = False
    if servo_attached:
        write_line(f"SET {selected + 1} {angle}")
    else:
        angle_label.configure(text=f"첫 명령 후보: {angle}°")


def attach_selected():
    global attach_pending
    if selected is None or not selection_ready or servo_attached or attach_pending:
        return
    cancel_pending_angle()
    angle = int(scale.get())
    attach_pending = True
    update_controls()
    if write_line(f"SET {selected + 1} {angle}"):
        set_status(f"Joint {selected + 1}을 선택한 {angle}°로 Attach 중")
    else:
        attach_pending = False
        update_controls()


def stop():
    cancel_pending_angle()
    if connected:
        write_line("STOP")


def detach_all():
    global detach_mode, selection_ready, servo_attached, attach_pending
    cancel_pending_angle()
    selection_ready = False
    servo_attached = False
    attach_pending = False
    detach_mode = "all"
    update_controls()
    if connected:
        write_line("DETACH")


def emergency_stop():
    global estop_latched, selection_ready
    cancel_pending_angle()
    if connected:
        estop_latched = True
        selection_ready = False
        update_controls()
        write_line("ESTOP")


def reset_estop():
    if connected and estop_latched:
        write_line("RESET")


def update_controls():
    joint_state = "normal" if connected and not estop_latched else "disabled"
    motion_state = "normal" if connected and selection_ready and not estop_latched else "disabled"
    for button in joint_buttons:
        button.configure(state=joint_state)
    for widget in motion_widgets:
        widget.configure(state=motion_state)
    if attach_button is not None:
        attach_button.configure(
            state="normal"
            if connected and selection_ready and not servo_attached and not attach_pending and not estop_latched
            else "disabled"
        )
    if stop_button is not None:
        stop_button.configure(state="normal" if connected else "disabled")
        detach_button.configure(state="normal" if connected else "disabled")
        estop_button.configure(state="normal" if connected and not estop_latched else "disabled")
        reset_button.configure(state="normal" if connected and estop_latched else "disabled")


def on_close():
    global closing
    closing = True
    cancel_pending_angle()
    close_port()
    root.destroy()


def build_gui():
    global root, status_var, selected_var, selected_label, angle_label, scale
    global stop_button, detach_button, estop_button, reset_button, attach_button
    root = tk.Tk()
    root.title("MG996R 개별 Servo 테스트")
    root.resizable(False, False)
    root.protocol("WM_DELETE_WINDOW", on_close)
    status_var = tk.StringVar(value="연결 전")
    selected_var = tk.IntVar(value=-1)

    top = ttk.Frame(root, padding=10)
    top.grid(row=0, column=0, sticky="ew")
    ttk.Label(top, textvariable=status_var, width=60).grid(row=0, column=0, sticky="w")
    ttk.Button(top, text="다시 연결", command=connect).grid(row=0, column=1)

    joints = ttk.LabelFrame(root, text="테스트할 Joint 선택 — 선택 시 모두 Detach", padding=8)
    joints.grid(row=1, column=0, padx=10, pady=5, sticky="ew")
    for index, pin in enumerate(JOINT_PINS):
        button = ttk.Radiobutton(
            joints,
            text=f"Joint {index + 1} (D{pin})",
            variable=selected_var,
            value=index,
            command=lambda i=index: select_joint(i),
        )
        button.grid(row=index // 3, column=index % 3, padx=12, pady=5, sticky="w")
        joint_buttons.append(button)

    control = ttk.LabelFrame(root, text="선택 Servo 제어", padding=10)
    control.grid(row=2, column=0, padx=10, pady=5, sticky="ew")
    selected_label = ttk.Label(control, text="선택 Joint: 없음", width=32)
    selected_label.grid(row=0, column=0, columnspan=4, sticky="w")
    scale = tk.Scale(control, from_=0, to=180, orient="horizontal", resolution=1, length=360, showvalue=True)
    scale.set(90)  # 표시만 하며 시작 시 각도를 전송하지 않습니다.
    scale.configure(command=scale_changed)
    scale.grid(row=1, column=0, columnspan=4, pady=5)
    minus = ttk.Button(control, text="-1", command=lambda: step_angle(-1), width=8)
    plus = ttk.Button(control, text="+1", command=lambda: step_angle(1), width=8)
    minus.grid(row=2, column=0)
    angle_label = ttk.Label(control, text="명령각: 미설정", width=20, anchor="center")
    angle_label.grid(row=2, column=1)
    plus.grid(row=2, column=2)
    attach_button = ttk.Button(control, text="선택 각도로 Attach", command=attach_selected, width=18)
    attach_button.grid(row=2, column=3, padx=(10, 0))
    motion_widgets.extend((scale, minus, plus))

    safety = ttk.Frame(root, padding=10)
    safety.grid(row=3, column=0, sticky="ew")
    stop_button = ttk.Button(safety, text="정지", command=stop, width=12)
    detach_button = ttk.Button(safety, text="모두 Detach", command=detach_all, width=14)
    estop_button = tk.Button(safety, text="EMERGENCY STOP", command=emergency_stop, bg="#c62828", fg="white", width=18)
    reset_button = ttk.Button(safety, text="E-STOP 해제", command=reset_estop, width=14)
    stop_button.grid(row=0, column=0, padx=3)
    detach_button.grid(row=0, column=1, padx=3)
    estop_button.grid(row=0, column=2, padx=3)
    reset_button.grid(row=0, column=3, padx=3)
    ttk.Label(
        root,
        text="MG996R는 외부 5–6V 전원을 사용하고 GND를 Arduino와 공통 연결하세요.",
        foreground="#9a4d00",
        padding=(10, 0, 10, 10),
    ).grid(row=4, column=0)
    update_controls()


def main():
    build_gui()
    root.after(20, poll_serial)
    root.after(100, connect)
    root.mainloop()


if __name__ == "__main__":
    main()
