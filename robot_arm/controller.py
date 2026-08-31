#!/usr/bin/env python3
import glob
import json
import os
import time
import tkinter as tk
from tkinter import messagebox, ttk

import serial


BAUD_RATE = 115200
ARDUINO_PORT = "/dev/ttyACM0"
POSE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "poses.json")
NORMAL_POSE_NAMES = (
    "HOME",
    "PICK_ABOVE",
    "PICK",
    "GRAB",
    "LIFT",
    "PLACE",
    "RELEASE",
)
ERROR_POSE_NAMES = ("ERROR_PICK", "ERROR_PLACE")
POSE_NAMES = NORMAL_POSE_NAMES + ERROR_POSE_NAMES
NORMAL_PLAY_ORDER = NORMAL_POSE_NAMES + ("HOME",)
ERROR_PLAY_ORDER = (
    "HOME",
    "PICK_ABOVE",
    "ERROR_PICK",
    "PICK_ABOVE",
    "PICK",
    "GRAB",
    "LIFT",
    "ERROR_PLACE",
    "LIFT",
    "PLACE",
    "RELEASE",
    "HOME",
)

# main.cpp의 SERVO_MIN / SERVO_MAX와 같은 값으로 설정하세요.
SERVO_LIMITS = (
    (0, 180),
    (0, 180),
    (0, 180),
    (0, 180),
    (0, 180),
    (0, 180),
)

POSE_PAUSE_SECONDS = 0.35
MOVE_TIMEOUT_SECONDS = 15.0

root = None
status_var = None
pose_var = None
scales = []
angle_labels = []
manual_widgets = []
play_buttons = []
pose_box = None
stop_button = None
estop_button = None
reset_button = None
detach_button = None

poses = {name: None for name in POSE_NAMES}
angles = [None] * 6
ignore_scale_event = False
set_after_ids = [None] * 6
set_values = [None] * 6
set_ack_values = [None] * 6

port = None
port_names = []
port_index = 0
rx_buffer = bytearray()
ping_after_id = None
ping_deadline = 0.0
serial_ready = False
limits_ok = False
status_ok = False
closing = False

estop_latched = False
stopping = False
running = False
repeat_mode = False
active_play_order = NORMAL_PLAY_ORDER
play_index = 0
pause_until = 0.0
pending_move = None
pending_pose = None
move_acked = False
move_deadline = 0.0


def set_status(text):
    status_var.set(text)


def port_candidates():
    found = []
    for pattern in (ARDUINO_PORT, "/dev/ttyUSB0", "/dev/ttyACM*", "/dev/ttyUSB*"):
        for name in sorted(glob.glob(pattern)):
            if name not in found:
                found.append(name)
    return found


def close_port():
    global port, serial_ready, limits_ok, status_ok, ping_after_id, ping_deadline, rx_buffer
    if ping_after_id is not None:
        try:
            root.after_cancel(ping_after_id)
        except tk.TclError:
            pass
    ping_after_id = None
    ping_deadline = 0.0
    serial_ready = False
    limits_ok = False
    status_ok = False
    old_port = port
    port = None
    rx_buffer = bytearray()
    if old_port is not None:
        try:
            old_port.close()
        except (serial.SerialException, OSError):
            pass


def connection_lost(detail):
    global estop_latched, stopping
    close_port()
    abort_motion()
    cancel_pending_sets()
    clear_known_angles()
    estop_latched = False
    stopping = False
    update_controls()
    set_status(f"연결 끊김: {detail}")


def try_next_port(last_error="응답 없음"):
    global port, port_index, ping_after_id, rx_buffer
    close_port()
    while port_index < len(port_names):
        name = port_names[port_index]
        port_index += 1
        try:
            port = serial.Serial(
                name,
                BAUD_RATE,
                timeout=0,
                write_timeout=0.1,
                exclusive=True,
            )
            rx_buffer = bytearray()
            set_status(f"Arduino 확인 중: {name}")
            # UNO는 포트를 열면 보통 reset되므로 bootloader가 끝난 뒤 확인합니다.
            ping_after_id = root.after(2000, begin_ping)
            return
        except (serial.SerialException, OSError) as exc:
            last_error = f"{name}: {exc}"
            port = None
    update_controls()
    set_status(f"Arduino 연결 실패: {last_error}")


def fail_current_port(detail):
    try_next_port(detail)


def begin_ping():
    global ping_after_id, ping_deadline
    ping_after_id = None
    if port is None or not port.is_open:
        fail_current_port("포트가 닫혔습니다.")
        return
    try:
        port.reset_input_buffer()
        data = b"PING\n"
        if port.write(data) != len(data):
            raise serial.SerialTimeoutException("PING 전송 실패")
        ping_deadline = time.monotonic() + 1.2
    except (serial.SerialException, OSError) as exc:
        fail_current_port(str(exc))


def connect_serial():
    global port_names, port_index, estop_latched, stopping
    abort_motion()
    cancel_pending_sets()
    close_port()
    clear_known_angles()
    estop_latched = False
    stopping = False
    port_names = port_candidates()
    port_index = 0
    update_controls()
    if port_names:
        try_next_port()
    else:
        set_status("/dev/ttyACM* 또는 /dev/ttyUSB* 장치를 찾지 못했습니다.")


def send_line(command):
    if port is None or not port.is_open or not serial_ready:
        return False
    data = (command + "\n").encode("ascii")
    try:
        if port.write(data) != len(data):
            raise serial.SerialTimeoutException("전송 시간 초과")
        return True
    except (serial.SerialException, OSError) as exc:
        connection_lost(str(exc))
        return False


def board_restarted():
    global serial_ready, limits_ok, status_ok, estop_latched, stopping, ping_after_id
    abort_motion()
    cancel_pending_sets()
    clear_known_angles()
    serial_ready = False
    limits_ok = False
    status_ok = False
    estop_latched = False
    stopping = False
    update_controls()
    set_status("Arduino가 재시작되어 각도 상태를 초기화했습니다.")
    if ping_after_id is not None:
        root.after_cancel(ping_after_id)
    ping_after_id = root.after(200, begin_ping)


def handle_limits(parts):
    global limits_ok
    try:
        values = [int(value) for value in parts[1:]]
    except ValueError:
        values = []
    expected = [value for pair in SERVO_LIMITS for value in pair]
    limits_ok = len(values) == 12 and values == expected
    update_controls()
    if limits_ok:
        set_status(f"연결됨: {port.port}")
    else:
        set_status("MIN/MAX가 main.cpp와 controller.py에서 서로 다릅니다.")


def handle_status(parts):
    global ignore_scale_event, estop_latched, status_ok
    if len(parts) != 16:
        return
    try:
        mask = int(parts[1])
        estop = int(parts[3])
        current = [int(value) for value in parts[4:10]]
    except ValueError:
        return

    status_ok = True
    if estop:
        estop_latched = True
    elif not stopping:
        estop_latched = False
    ignore_scale_event = True
    try:
        for index, value in enumerate(current):
            low, high = SERVO_LIMITS[index]
            if mask & (1 << index) and low <= value <= high:
                angles[index] = value
                scales[index].set(value)
                angle_labels[index].configure(text=f"명령각: {value}°")
            else:
                angles[index] = None
                angle_labels[index].configure(text="명령각: 미설정")
    finally:
        ignore_scale_event = False
    update_controls()


def handle_ok(parts):
    global estop_latched, stopping, move_acked
    if len(parts) < 2:
        return
    command = parts[1].upper()
    if command == "SET" and len(parts) == 4:
        try:
            index = int(parts[2]) - 1
            value = int(parts[3])
        except ValueError:
            return
        if 0 <= index < 6 and SERVO_LIMITS[index][0] <= value <= SERVO_LIMITS[index][1]:
            angles[index] = value
            if set_ack_values[index] == value:
                set_ack_values[index] = None
            angle_labels[index].configure(text=f"명령각: {value}°")
    elif command == "MOVE" and pending_move is not None:
        move_acked = True
    elif command == "STOP":
        stopping = False
        send_line("STATUS")
    elif command == "ESTOP":
        estop_latched = True
        stopping = False
        send_line("STATUS")
    elif command == "RESET":
        estop_latched = False
        stopping = False
        send_line("STATUS")
    elif command == "DETACH":
        stopping = False
        clear_known_angles()
    update_controls()


def handle_done():
    global pending_move, pending_pose, move_acked, play_index, pause_until
    if pending_move is None or not move_acked:
        return
    completed_name = pending_move
    completed_pose = pending_pose
    pending_move = None
    pending_pose = None
    move_acked = False
    show_angles(completed_pose)
    if running:
        play_index += 1
        pause_until = time.monotonic() + POSE_PAUSE_SECONDS
        set_status(f"자동 실행: {completed_name} 완료")
    else:
        set_status(f"{completed_name} 이동 완료")
    update_controls()


def handle_error(parts):
    global estop_latched
    message = " ".join(parts[1:]) or "알 수 없는 오류"
    if parts[1:2] == ["ESTOP"]:
        estop_latched = True
        for index in range(6):
            set_ack_values[index] = None
    elif parts[1:2] == ["RANGE"] and len(parts) >= 3:
        try:
            index = int(parts[2]) - 1
            if 0 <= index < 6:
                set_ack_values[index] = None
        except ValueError:
            pass
    if pending_move is not None:
        abort_motion()
    if send_line("STATUS"):
        update_controls()
        set_status(f"Arduino 오류: {message}")


def handle_line(line):
    global serial_ready, limits_ok, status_ok, ping_deadline
    parts = line.split()
    if not parts:
        return
    response = parts[0].upper()
    if response == "PONG" and ping_deadline:
        ping_deadline = 0.0
        serial_ready = True
        limits_ok = False
        status_ok = False
        set_status(f"설정 확인 중: {port.port}")
        send_line("LIMITS")
        send_line("STATUS")
        update_controls()
    elif response == "READY":
        if serial_ready:
            board_restarted()
    elif response == "LIMITS":
        handle_limits(parts)
    elif response == "STATUS":
        handle_status(parts)
    elif response == "OK":
        handle_ok(parts)
    elif response == "DONE":
        handle_done()
    elif response == "ERR":
        handle_error(parts)


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
                    line = raw.rstrip(b"\r").decode("utf-8", errors="replace").strip()
                    if line:
                        handle_line(line)
        except (serial.SerialException, OSError) as exc:
            if serial_ready:
                connection_lost(str(exc))
            else:
                fail_current_port(str(exc))
    if ping_deadline and time.monotonic() >= ping_deadline:
        fail_current_port("PONG 응답 없음")
    root.after(20, poll_serial)


def valid_pose(value):
    if not isinstance(value, list) or len(value) != 6:
        return None
    result = []
    for index, item in enumerate(value):
        low, high = SERVO_LIMITS[index]
        if isinstance(item, bool) or not isinstance(item, int) or not low <= item <= high:
            return None
        result.append(item)
    return result


def load_poses(show_dialog=False):
    global poses
    loaded = {name: None for name in POSE_NAMES}
    try:
        with open(POSE_FILE, "r", encoding="utf-8") as file:
            data = json.load(file)
        if not isinstance(data, dict):
            raise ValueError("JSON 최상위 값은 객체여야 합니다.")
        for name in POSE_NAMES:
            if data.get(name) is not None:
                pose = valid_pose(data[name])
                if pose is None:
                    raise ValueError(f"{name}: 제한 범위 안의 정수 6개가 필요합니다.")
                loaded[name] = pose
        poses = loaded
        count = sum(pose is not None for pose in poses.values())
        set_status(f"poses.json 불러옴: {count}/{len(POSE_NAMES)} Pose")
        if show_dialog:
            messagebox.showinfo("Pose 불러오기", f"{count}개의 Pose를 불러왔습니다.")
    except FileNotFoundError:
        poses = loaded
        set_status("poses.json이 없습니다.")
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        poses = loaded
        messagebox.showerror("poses.json 오류", str(exc))


def save_pose_file():
    try:
        with open(POSE_FILE, "w", encoding="utf-8") as file:
            json.dump(poses, file, ensure_ascii=False, indent=2)
            file.write("\n")
        return True
    except OSError as exc:
        messagebox.showerror("Pose 저장 오류", str(exc))
        return False


def show_angles(values):
    global ignore_scale_event
    ignore_scale_event = True
    try:
        for index, value in enumerate(values):
            angles[index] = value
            scales[index].set(value)
            angle_labels[index].configure(text=f"명령각: {value}°")
    finally:
        ignore_scale_event = False


def show_targets(values):
    global ignore_scale_event
    ignore_scale_event = True
    try:
        for index, value in enumerate(values):
            scales[index].set(value)
    finally:
        ignore_scale_event = False


def clear_known_angles():
    for index in range(6):
        angles[index] = None
        set_ack_values[index] = None
        if angle_labels:
            angle_labels[index].configure(text="명령각: 미설정")


def cancel_pending_sets():
    for index, after_id in enumerate(set_after_ids):
        if after_id is not None:
            try:
                root.after_cancel(after_id)
            except tk.TclError:
                pass
        set_after_ids[index] = None
        set_values[index] = None


def motion_ready():
    return serial_ready and limits_ok and status_ok and not estop_latched and not stopping


def restore_scale(index):
    global ignore_scale_event
    if angles[index] is None:
        return
    ignore_scale_event = True
    scales[index].set(angles[index])
    ignore_scale_event = False


def send_servo(index, value):
    if running or pending_move is not None or not motion_ready():
        restore_scale(index)
        return
    low, high = SERVO_LIMITS[index]
    target = max(low, min(high, int(round(float(value)))))
    if send_line(f"SET {index + 1} {target}"):
        set_ack_values[index] = target
    else:
        restore_scale(index)


def flush_servo(index):
    value = set_values[index]
    set_after_ids[index] = None
    set_values[index] = None
    if value is not None:
        send_servo(index, value)


def scale_changed(index, value):
    if ignore_scale_event:
        return
    if running or pending_move is not None or not motion_ready():
        restore_scale(index)
        return
    low, high = SERVO_LIMITS[index]
    set_values[index] = max(low, min(high, int(round(float(value)))))
    if set_after_ids[index] is not None:
        root.after_cancel(set_after_ids[index])
    set_after_ids[index] = root.after(40, flush_servo, index)


def step_servo(index, amount):
    global ignore_scale_event
    if not motion_ready() or running or pending_move is not None:
        return
    if set_after_ids[index] is not None:
        root.after_cancel(set_after_ids[index])
        set_after_ids[index] = None
        set_values[index] = None
    low, high = SERVO_LIMITS[index]
    target = max(low, min(high, int(scales[index].get()) + amount))
    ignore_scale_event = True
    scales[index].set(target)
    ignore_scale_event = False
    send_servo(index, target)


def angles_ready_to_save():
    if any(after_id is not None for after_id in set_after_ids) or any(
        value is not None for value in set_ack_values
    ):
        messagebox.showwarning("Servo 응답 대기", "마지막 슬라이더 명령이 확인될 때까지 잠시 기다리세요.")
        return False
    if all(value is not None for value in angles):
        return True
    messagebox.showwarning(
        "초기 자세 미설정",
        "Servo 1~6을 직접 조작하거나 저장된 Pose로 먼저 이동한 뒤 저장하세요.",
    )
    return False


def save_current_pose():
    if not angles_ready_to_save():
        return
    name = pose_var.get()
    poses[name] = list(angles)
    if save_pose_file():
        set_status(f"{name} 저장: {poses[name]}")


def start_move(name, pose):
    global pending_move, pending_pose, move_acked, move_deadline
    pending_move = name
    pending_pose = list(pose)
    move_acked = False
    move_deadline = time.monotonic() + MOVE_TIMEOUT_SECONDS
    show_targets(pose)
    update_controls()
    if send_line("MOVE " + " ".join(str(value) for value in pose)):
        set_status(f"{name} 이동 중")
        return True
    pending_move = None
    pending_pose = None
    update_controls()
    return False


def move_selected_pose():
    if not motion_ready() or running or pending_move is not None:
        return
    name = pose_var.get()
    pose = poses.get(name)
    if pose is None:
        messagebox.showwarning("Pose 이동", f"{name} Pose가 저장되지 않았습니다.")
        return
    cancel_pending_sets()
    start_move(name, pose)


def abort_motion():
    global running, repeat_mode, pending_move, pending_pose, move_acked
    running = False
    repeat_mode = False
    pending_move = None
    pending_pose = None
    move_acked = False


def start_playback(repeat, error_mode=False):
    global running, repeat_mode, active_play_order, play_index, pause_until
    if not motion_ready() or running or pending_move is not None:
        return
    if error_mode and repeat:
        messagebox.showwarning("자동 실행", "오류 로직은 1회만 실행할 수 있습니다.")
        return
    selected_order = ERROR_PLAY_ORDER if error_mode else NORMAL_PLAY_ORDER
    missing = [name for name in dict.fromkeys(selected_order) if poses[name] is None]
    if missing:
        messagebox.showwarning("자동 실행", "저장되지 않은 Pose: " + ", ".join(missing))
        return
    cancel_pending_sets()
    running = True
    repeat_mode = repeat
    active_play_order = selected_order
    play_index = 0
    pause_until = 0.0
    update_controls()
    if error_mode:
        set_status("오류 로직 실행 시작")
    else:
        set_status("반복 실행 시작" if repeat else "1회 실행 시작")


def playback_tick():
    global running, play_index, pause_until, stopping
    if closing:
        return
    now = time.monotonic()
    if pending_move is not None and now >= move_deadline:
        timed_out_name = pending_move
        abort_motion()
        stopping = True
        sent = send_line("STOP")
        update_controls()
        if sent:
            set_status(f"{timed_out_name} 이동 시간 초과")
    elif running and pending_move is None and now >= pause_until:
        if play_index >= len(active_play_order):
            if repeat_mode:
                play_index = 0
            else:
                running = False
                update_controls()
                if active_play_order == ERROR_PLAY_ORDER:
                    set_status("오류 로직 실행 완료")
                else:
                    set_status("1회 자동 실행 완료")
        if running and pending_move is None:
            name = active_play_order[play_index]
            pose_var.set(name)
            start_move(name, poses[name])
    root.after(30, playback_tick)


def stop_motion():
    global stopping
    if not serial_ready:
        return
    cancel_pending_sets()
    abort_motion()
    stopping = True
    update_controls()
    if send_line("STOP"):
        set_status("정지 명령 전송")


def emergency_stop():
    global estop_latched, stopping
    if not serial_ready:
        return
    cancel_pending_sets()
    abort_motion()
    estop_latched = True
    stopping = True
    update_controls()
    if send_line("ESTOP"):
        set_status("EMERGENCY STOP: 현재 명령 위치에서 정지")


def reset_estop():
    global stopping
    if not serial_ready or not estop_latched or stopping:
        return
    stopping = True
    update_controls()
    if send_line("RESET"):
        set_status("E-STOP 해제 응답 대기 중")


def detach_servos():
    global stopping
    if not serial_ready:
        return
    cancel_pending_sets()
    abort_motion()
    stopping = True
    clear_known_angles()
    update_controls()
    if send_line("DETACH"):
        set_status("Servo Detach 명령 전송")


def update_controls():
    if root is None:
        return
    busy = running or pending_move is not None
    enabled = motion_ready() and not busy
    state = "normal" if enabled else "disabled"
    for widget in manual_widgets:
        if widget is pose_box:
            widget.configure(state="readonly" if enabled else "disabled")
        else:
            widget.configure(state=state)
    for button in play_buttons:
        button.configure(state=state)
    if stop_button is not None:
        safety_state = "normal" if serial_ready and not stopping else "disabled"
        stop_button.configure(state=safety_state)
        estop_button.configure(state="normal" if serial_ready and not estop_latched else "disabled")
        reset_button.configure(state="normal" if serial_ready and estop_latched and not stopping else "disabled")
        detach_button.configure(state=safety_state)


def on_close():
    global closing
    closing = True
    cancel_pending_sets()
    close_port()
    root.destroy()


def build_gui():
    global root, status_var, pose_var, pose_box
    global stop_button, estop_button, reset_button, detach_button

    root = tk.Tk()
    root.title("MG996R 6축 로봇팔 Teach & Playback")
    root.resizable(False, False)
    root.protocol("WM_DELETE_WINDOW", on_close)
    status_var = tk.StringVar(value="시리얼 포트 검색 전")
    pose_var = tk.StringVar(value=POSE_NAMES[0])

    connection = ttk.Frame(root, padding=(10, 10, 10, 4))
    connection.grid(row=0, column=0, sticky="ew")
    ttk.Label(connection, textvariable=status_var, width=58).grid(row=0, column=0, sticky="w")
    ttk.Button(connection, text="포트 다시 검색", command=connect_serial).grid(row=0, column=1)

    servo_frame = ttk.LabelFrame(root, text="Servo 직접 제어", padding=8)
    servo_frame.grid(row=1, column=0, padx=10, pady=6, sticky="ew")
    ttk.Label(servo_frame, text="서보", width=7).grid(row=0, column=0)
    ttk.Label(servo_frame, text="MIN", width=5).grid(row=0, column=1)
    ttk.Label(servo_frame, text="각도 슬라이더", width=42).grid(row=0, column=2)
    ttk.Label(servo_frame, text="MAX", width=5).grid(row=0, column=3)
    ttk.Label(servo_frame, text="현재 명령각", width=15).grid(row=0, column=4)

    for index, (low, high) in enumerate(SERVO_LIMITS):
        row = index + 1
        ttk.Label(servo_frame, text=f"Servo {index + 1}").grid(row=row, column=0)
        ttk.Label(servo_frame, text=str(low)).grid(row=row, column=1)
        scale = tk.Scale(
            servo_frame,
            from_=low,
            to=high,
            orient="horizontal",
            resolution=1,
            showvalue=False,
            length=330,
            state="disabled",
        )
        scale.set((low + high) // 2)  # 표시만 하며 시작 시 각도를 전송하지 않습니다.
        scale.configure(command=lambda value, i=index: scale_changed(i, value))
        scale.grid(row=row, column=2, padx=5)
        scales.append(scale)
        manual_widgets.append(scale)
        ttk.Label(servo_frame, text=str(high)).grid(row=row, column=3)
        label = ttk.Label(servo_frame, text="명령각: 미설정", width=15)
        label.grid(row=row, column=4, padx=5)
        angle_labels.append(label)
        minus = ttk.Button(servo_frame, text="-1", width=4, command=lambda i=index: step_servo(i, -1))
        plus = ttk.Button(servo_frame, text="+1", width=4, command=lambda i=index: step_servo(i, 1))
        minus.grid(row=row, column=5, padx=2)
        plus.grid(row=row, column=6, padx=2)
        manual_widgets.extend((minus, plus))

    pose_frame = ttk.LabelFrame(root, text="Pose", padding=8)
    pose_frame.grid(row=2, column=0, padx=10, pady=6, sticky="ew")
    pose_box = ttk.Combobox(
        pose_frame,
        textvariable=pose_var,
        values=POSE_NAMES,
        state="disabled",
        width=18,
    )
    pose_box.grid(row=0, column=0, padx=(0, 8))
    save_button = ttk.Button(pose_frame, text="현재 자세 저장", command=save_current_pose)
    move_button = ttk.Button(pose_frame, text="선택 Pose로 이동", command=move_selected_pose)
    load_button = ttk.Button(pose_frame, text="poses.json 불러오기", command=lambda: load_poses(True))
    save_button.grid(row=0, column=1, padx=3)
    move_button.grid(row=0, column=2, padx=3)
    load_button.grid(row=0, column=3, padx=3)
    manual_widgets.extend((pose_box, save_button, move_button, load_button))

    run_frame = ttk.LabelFrame(root, text="자동 실행", padding=8)
    run_frame.grid(row=3, column=0, padx=10, pady=6, sticky="ew")
    once_button = ttk.Button(run_frame, text="1회 실행", command=lambda: start_playback(False))
    error_button = ttk.Button(
        run_frame,
        text="오류 로직 실행",
        command=lambda: start_playback(False, error_mode=True),
    )
    repeat_button = ttk.Button(run_frame, text="반복 실행", command=lambda: start_playback(True))
    stop_button = ttk.Button(run_frame, text="정지", command=stop_motion)
    once_button.grid(row=0, column=0, padx=3)
    error_button.grid(row=0, column=1, padx=3)
    repeat_button.grid(row=0, column=2, padx=3)
    stop_button.grid(row=0, column=3, padx=3)
    play_buttons.extend((once_button, error_button, repeat_button))

    safety = ttk.Frame(root, padding=(10, 4, 10, 10))
    safety.grid(row=4, column=0, sticky="ew")
    estop_button = tk.Button(
        safety,
        text="EMERGENCY STOP",
        command=emergency_stop,
        bg="#c62828",
        fg="white",
        activebackground="#8e0000",
        activeforeground="white",
        width=20,
    )
    estop_button.grid(row=0, column=0, padx=(0, 8))
    reset_button = ttk.Button(safety, text="E-STOP 해제", command=reset_estop, width=16)
    reset_button.grid(row=0, column=1, padx=(0, 8))
    detach_button = ttk.Button(safety, text="Servo Detach", command=detach_servos, width=16)
    detach_button.grid(row=0, column=2)
    update_controls()


def main():
    build_gui()
    load_poses()
    root.after(20, poll_serial)
    root.after(100, connect_serial)
    root.after(30, playback_tick)
    root.mainloop()


if __name__ == "__main__":
    main()
