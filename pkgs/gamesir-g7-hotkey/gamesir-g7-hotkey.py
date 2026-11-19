#!/usr/bin/env python3
"""Re-emit the GameSir G7 HE L4 paddle as F14 without grabbing the gamepad."""

import logging
import time

from evdev import InputDevice, UInput, ecodes


DEVICE = "/dev/input/by-id/usb-3537_GameSir-G7_HE_Controller_for_Xbox-event-joystick"

# El paddle L4 llega como BTN_WEST (código 308) en la interfaz de gamepad.
# R4 no emite ningún evento en este firmware, así que todavía no se puede
# mapear. Mantén el mapa aquí para añadirlo cuando aparezca.
BUTTON_TO_KEY = {
    308: ecodes.KEY_F14,
}

# udev clasifica como ID_INPUT_KEYBOARD solo si el dispositivo anuncia un
# rango de teclas de teclado, no una tecla alta aislada. Sin esto, niri puede
# ignorar el F14 aunque el evento llegue al kernel.
KEYBOARD_KEYS = list(range(ecodes.KEY_ESC, ecodes.KEY_D + 1)) + [
    ecodes.KEY_F14,
]


def open_gamepad():
    while True:
        try:
            device = InputDevice(DEVICE)
            logging.info("listening on %s", device.path)
            return device
        except OSError as error:
            logging.warning("waiting for G7 HE gamepad interface: %s", error)
            time.sleep(2)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    keys = sorted(set(BUTTON_TO_KEY.values()))

    with UInput(
        {ecodes.EV_KEY: sorted(set(keys + KEYBOARD_KEYS))},
        name="gamesir-g7-extra-keys",
        vendor=0x3537,
        product=0x1082,
        version=1,
    ) as uinput:
        while True:
            device = open_gamepad()
            try:
                for event in device.read_loop():
                    if (
                        event.type != ecodes.EV_KEY
                        or event.value != 1
                        or event.code not in BUTTON_TO_KEY
                    ):
                        continue
                    key = BUTTON_TO_KEY[event.code]
                    uinput.write(ecodes.EV_KEY, key, 1)
                    uinput.syn()
                    uinput.write(ecodes.EV_KEY, key, 0)
                    uinput.syn()
                    logging.info("paddle %d -> F%d", event.code, key - ecodes.KEY_F13 + 13)
            except OSError as error:
                logging.warning("G7 HE gamepad interface disconnected: %s", error)
                time.sleep(1)
            finally:
                device.close()


if __name__ == "__main__":
    main()
