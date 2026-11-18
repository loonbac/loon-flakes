#!/usr/bin/env python3
"""Fast DDC brightness frontend with a coalescing per-session daemon."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import time


MODEL = os.environ["DDC_BRIGHTNESS_MONITOR_MODEL"]
RUNTIME_ROOT = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
RUNTIME_DIR = RUNTIME_ROOT / "ddc-brightness"
CONTROL = RUNTIME_DIR / "control"
STATE = RUNTIME_DIR / "state.json"
CACHE_ROOT = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
CACHE_DIR = CACHE_ROOT / "ddc-brightness"
BUS_CACHE = CACHE_DIR / "bus"


def run_ddc(bus: int, *args: str) -> str:
    result = subprocess.run(
        ["ddcutil", f"--bus={bus}", "--sleep-multiplier=.1", *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
    )
    return result.stdout


def valid_bus(value: str) -> int | None:
    if not value.isdecimal():
        return None
    bus = int(value)
    path = Path(f"/dev/i2c-{bus}")
    try:
        return bus if stat.S_ISCHR(path.stat().st_mode) else None
    except OSError:
        return None


def detect_bus() -> int:
    try:
        cached = valid_bus(BUS_CACHE.read_text(encoding="ascii").strip())
    except OSError:
        cached = None
    if cached is not None:
        return cached

    result = subprocess.run(
        ["ddcutil", "detect", "--brief"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    bus: int | None = None
    for line in result.stdout.splitlines():
        match = re.search(r"I2C bus:\s+/dev/i2c-(\d+)", line)
        if match:
            bus = int(match.group(1))
        if "Monitor:" in line and f":{MODEL}:" in line and bus is not None:
            CACHE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
            atomic_write(BUS_CACHE, f"{bus}\n", json_data=False)
            return bus
    raise RuntimeError(f"no se encontró el monitor DDC {MODEL}")


def read_hardware(bus: int) -> tuple[int, int]:
    output = run_ddc(bus, "--terse", "getvcp", "10")
    match = re.search(r"^VCP\s+10\s+C\s+(\d+)\s+(\d+)\s*$", output, re.MULTILINE)
    if not match:
        raise RuntimeError("respuesta VCP de brillo inválida")
    current, maximum = map(int, match.groups())
    if maximum <= 0:
        raise RuntimeError("máximo VCP de brillo inválido")
    return current, maximum


def set_hardware(bus: int, percent: int, maximum: int) -> None:
    raw = (percent * maximum + 50) // 100
    # El daemon sincroniza periódicamente el valor real. Evitar la verificación
    # inmediata elimina un segundo intercambio DDC en cada cambio interactivo.
    run_ddc(bus, "--noverify", "setvcp", "10", str(raw))


def atomic_write(path: Path, content: str, *, json_data: bool = True) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8" if json_data else "ascii",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        handle.write(content)
        temporary = Path(handle.name)
    temporary.chmod(0o600)
    os.replace(temporary, path)


def write_state(percent: int, maximum: int) -> None:
    atomic_write(
        STATE,
        json.dumps({"percentage": percent, "maximum": maximum}, separators=(",", ":"))
        + "\n",
    )


def read_state() -> tuple[int, int] | None:
    try:
        data = json.loads(STATE.read_text(encoding="utf-8"))
        percent = data["percentage"]
        maximum = data["maximum"]
        if (
            isinstance(percent, int)
            and 0 <= percent <= 100
            and isinstance(maximum, int)
            and maximum > 0
        ):
            return percent, maximum
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        pass
    return None


def percent_from_raw(current: int, maximum: int) -> int:
    return min(100, max(0, (current * 100 + maximum // 2) // maximum))


def output_json() -> int:
    state = read_state()
    if state is None:
        print(
            json.dumps(
                {
                    "text": "",
                    "percentage": 0,
                    "alt": "unavailable",
                    "tooltip": "Brillo DDC iniciando",
                },
                separators=(",", ":"),
            )
        )
        return 0
    percent, _ = state
    alt = "high" if percent >= 65 else "medium" if percent >= 30 else "low"
    print(
        json.dumps(
            {
                "text": f"{percent}%",
                "percentage": percent,
                "alt": alt,
                "tooltip": f"Brillo del monitor: {percent}%",
            },
            separators=(",", ":"),
        )
    )
    return 0


def parse_percent(value: str) -> int:
    value = value.removesuffix("%")
    if not value.isdecimal() or not 0 <= int(value) <= 100:
        raise ValueError("el brillo debe ser un número entre 0 y 100")
    return int(value)


def send_request(operation: str, value: int | None = None) -> int:
    if not CONTROL.exists():
        subprocess.run(
            ["systemctl", "--user", "start", "ddc-brightness.service"],
            check=True,
            timeout=10,
        )
    deadline = time.monotonic() + 2
    while not CONTROL.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    request = operation if value is None else f"{operation} {value}"
    try:
        descriptor = os.open(CONTROL, os.O_WRONLY | os.O_NONBLOCK)
        try:
            os.write(descriptor, f"{request}\n".encode("ascii"))
        finally:
            os.close(descriptor)
    except OSError as error:
        print(f"ddc-brightness: daemon no disponible: {error}", file=sys.stderr)
        return 1
    return 0


def apply_request(request: str, percent: int) -> tuple[int, bool]:
    fields = request.split()
    if not fields:
        return percent, False
    if fields[0] == "sync":
        return percent, True
    if len(fields) != 2:
        return percent, False
    try:
        value = parse_percent(fields[1])
    except ValueError:
        return percent, False
    if fields[0] == "set":
        return value, False
    if fields[0] == "up":
        return min(100, percent + value), False
    if fields[0] == "down":
        return max(0, percent - value), False
    return percent, False


def daemon() -> int:
    RUNTIME_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        if CONTROL.exists() or CONTROL.is_symlink():
            CONTROL.unlink()
        os.mkfifo(CONTROL, mode=0o600)
        descriptor = os.open(CONTROL, os.O_RDWR | os.O_NONBLOCK)
        selector = selectors.DefaultSelector()
        selector.register(descriptor, selectors.EVENT_READ)

        bus = detect_bus()
        current, maximum = read_hardware(bus)
        percent = percent_from_raw(current, maximum)
        write_state(percent, maximum)
        last_sync = time.monotonic()
        pending = b""

        while True:
            timeout = max(0.0, 30.0 - (time.monotonic() - last_sync))
            events = selector.select(timeout)
            if not events:
                current, maximum = read_hardware(bus)
                actual = percent_from_raw(current, maximum)
                last_sync = time.monotonic()
                if actual != percent:
                    percent = actual
                    write_state(percent, maximum)
                continue

            # Una ventana corta agrupa una ráfaga de rueda/teclas en una sola
            # escritura física, sin retrasar al proceso que recibe el input.
            time.sleep(0.06)
            while True:
                try:
                    chunk = os.read(descriptor, 4096)
                except BlockingIOError:
                    break
                if not chunk:
                    break
                pending += chunk

            lines = pending.split(b"\n")
            pending = lines.pop()
            force_sync = False
            previous = percent
            for line in lines:
                percent, requested_sync = apply_request(
                    line.decode("ascii", errors="ignore"), percent
                )
                force_sync = force_sync or requested_sync

            if force_sync:
                current, maximum = read_hardware(bus)
                percent = percent_from_raw(current, maximum)
                last_sync = time.monotonic()
            if percent != previous or force_sync:
                write_state(percent, maximum)
            if percent != previous:
                set_hardware(bus, percent, maximum)
    except Exception as error:
        print(f"ddc-brightness: {error}", file=sys.stderr)
        return 1
    finally:
        try:
            CONTROL.unlink()
        except OSError:
            pass


def main() -> int:
    command = sys.argv[1] if len(sys.argv) > 1 else "get"
    if command == "daemon":
        return daemon()
    if command == "json":
        return output_json()
    if command == "get":
        state = read_state()
        if state is None:
            print("ddc-brightness: estado no disponible", file=sys.stderr)
            return 1
        print(state[0])
        return 0
    if command == "sync":
        return send_request("sync")
    if command in {"set", "up", "+", "down", "-"}:
        try:
            if command == "set" and len(sys.argv) <= 2:
                raise ValueError("set necesita un porcentaje")
            value = parse_percent(sys.argv[2] if len(sys.argv) > 2 else "10")
        except ValueError as error:
            print(f"ddc-brightness: {error}", file=sys.stderr)
            return 2
        operation = {"+": "up", "-": "down"}.get(command, command)
        return send_request(operation, value)
    print(
        "Uso: ddc-brightness [get|set <0..100>|up [paso]|down [paso]|json|sync]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
