#!/usr/bin/env python3
"""Toggle Equibop's own microphone when the Basilisk V3 emits F13."""

import logging
import os
import socket
import subprocess
import time

from evdev import InputDevice, ecodes
from evdev import list_devices


DEVICE = "/dev/input/by-id/usb-Razer_Razer_Basilisk_V3-if02-event-kbd"
USER = "loonbac"
USER_ID = "1000"
SOCKET = f"/run/user/{USER_ID}/equibop-hotkey.sock"


def open_mouse_keyboard():
    while True:
        try:
            device = InputDevice(DEVICE)
            logging.info("listening on %s", device.path)
            return device
        except OSError as error:
            logging.warning("waiting for Basilisk keyboard interface: %s", error)
            time.sleep(2)


def control_is_held():
    control_keys = {ecodes.KEY_LEFTCTRL, ecodes.KEY_RIGHTCTRL}
    for path in list_devices():
        try:
            device = InputDevice(path)
            try:
                if control_keys.intersection(device.active_keys()):
                    return True
            finally:
                device.close()
        except OSError:
            # Devices can disappear while USB hardware is being enumerated.
            continue
    return False


def send_to_equibop_hotkey_socket(command):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.2)
            client.connect(SOCKET)
            client.sendall(f"{command}\n".encode())
            return client.recv(16).strip() == b"ok"
    except OSError:
        return False


def toggle_equibop_voice_state(deafen):
    command = "deafen" if deafen else "mute"
    if send_to_equibop_hotkey_socket(command):
        logging.info("sent %s through the Equibop hotkey socket", command)
        return

    environment = os.environ | {
        "HOME": f"/home/{USER}",
        "XDG_RUNTIME_DIR": f"/run/user/{USER_ID}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{USER_ID}/bus",
        "PATH": "/run/wrappers/bin:/run/current-system/sw/bin",
    }
    subprocess.Popen(
        [
            "runuser",
            "-u",
            USER,
            "--",
            "equibop",
            "--toggle-deafen" if deafen else "--toggle-mic",
        ],
        env=environment,
        close_fds=True,
        start_new_session=True,
    )
    logging.info("Equibop hotkey socket unavailable; sent %s through the CLI fallback", "--toggle-deafen" if deafen else "--toggle-mic")


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    while True:
        device = open_mouse_keyboard()
        try:
            for event in device.read_loop():
                if (
                    event.type == ecodes.EV_KEY
                    and event.code == ecodes.KEY_F13
                    and event.value == 1
                ):
                    toggle_equibop_voice_state(deafen=control_is_held())
        except OSError as error:
            logging.warning("Basilisk keyboard interface disconnected: %s", error)
            time.sleep(1)
        finally:
            device.close()


if __name__ == "__main__":
    main()
