#!/usr/bin/env python3
"""Pausa mpvpaper cuando una ventana opaca cubre un workspace visible."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any


# Apps cuya superficie deja ver el fondo: pausarlo detrás de ellas no ahorra
# GPU y sí corta el efecto. Debe coincidir con lo que de verdad es transparente:
# el window-rule de ghostty en config.kdl (opacity 0.8 + xray) y la transparencia
# propia de PORT (opacity 0.85 en su config.md). Una app opaca NO se añade aquí.
TRANSPARENT_APP_IDS = frozenset({"com.mitchellh.ghostty", "port"})
PAUSE_REASON = "opaque-window"


class VisibilityState:
    def __init__(self) -> None:
        self.workspaces: dict[int, dict[str, Any]] = {}
        self.windows: dict[int, dict[str, Any]] = {}

    def opaque_window_visible(self) -> bool:
        """Comprueba la ventana activa de cada workspace visible por salida."""
        for workspace in self.workspaces.values():
            if not workspace.get("is_active"):
                continue
            window_id = workspace.get("active_window_id")
            if window_id is None:
                continue
            window = self.windows.get(window_id)
            # Durante actualizaciones no atómicas, pausar de forma conservadora
            # hasta que llegue la descripción de la ventana.
            if window is None or window.get("app_id") not in TRANSPARENT_APP_IDS:
                return True
        return False

    def update(self, event: dict[str, Any]) -> bool:
        """Aplica un evento; devuelve True si puede cambiar la visibilidad."""
        if payload := event.get("WorkspacesChanged"):
            self.workspaces = {
                workspace["id"]: workspace for workspace in payload["workspaces"]
            }
            return True

        if payload := event.get("WorkspaceActivated"):
            workspace = self.workspaces.get(payload["id"])
            if workspace is None:
                return False
            output = workspace.get("output")
            for candidate in self.workspaces.values():
                if candidate.get("output") == output:
                    candidate["is_active"] = candidate["id"] == payload["id"]
                if payload.get("focused"):
                    candidate["is_focused"] = candidate["id"] == payload["id"]
            return True

        if payload := event.get("WorkspaceActiveWindowChanged"):
            workspace = self.workspaces.get(payload["workspace_id"])
            if workspace is None:
                return False
            workspace["active_window_id"] = payload.get("active_window_id")
            return bool(workspace.get("is_active"))

        if payload := event.get("WindowsChanged"):
            old_signature = self._window_signature()
            self.windows = {window["id"]: window for window in payload["windows"]}
            return old_signature != self._window_signature()

        if payload := event.get("WindowOpenedOrChanged"):
            window = payload["window"]
            old = self.windows.get(window["id"])
            self.windows[window["id"]] = window
            # Ignorar cambios de título/foco: Ghostty puede emitir decenas por
            # segundo y no cambian si el wallpaper está cubierto.
            return old is None or (
                old.get("app_id"), old.get("workspace_id")
            ) != (window.get("app_id"), window.get("workspace_id"))

        if payload := event.get("WindowClosed"):
            removed = self.windows.pop(payload["id"], None)
            return removed is not None

        return False

    def _window_signature(self) -> set[tuple[int, Any, Any]]:
        return {
            (window_id, window.get("app_id"), window.get("workspace_id"))
            for window_id, window in self.windows.items()
        }


def set_wallpaper_paused(paused: bool) -> None:
    args = ["mpvpaper-wallpaper", "pause" if paused else "resume", PAUSE_REASON]
    if paused:
        # El watcher es dueño de su motivo. Si muere sin retirarlo (crash, OOM,
        # reinicio del servicio) ese pid deja de existir y el siguiente
        # reconcile descarta el motivo en vez de dejar el fondo pausado para
        # siempre. 'resume' no necesita dueño: retira por nombre.
        args.append(f"pid:{os.getpid()}")
    subprocess.run(args, check=False, stdout=subprocess.DEVNULL)


def main() -> int:
    if not os.environ.get("NIRI_SOCKET"):
        print("niri-wallpaper-visibility: NIRI_SOCKET no está definido", file=sys.stderr)
        return 1

    # Reconciliar al arrancar: una instancia anterior pudo morir con su motivo
    # de pausa puesto y, sin este paso, nada lo retiraría hasta el próximo
    # cambio de foco.
    subprocess.run(
        ["mpvpaper-wallpaper", "reconcile"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    state = VisibilityState()
    applied: bool | None = None
    process = subprocess.Popen(
        ["niri", "msg", "-j", "event-stream"],
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None

    try:
        for line in process.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not state.update(event):
                continue
            desired = state.opaque_window_visible()
            if desired == applied:
                continue
            set_wallpaper_paused(desired)
            applied = desired
    finally:
        # El motivo se conserva si niri corta el stream; systemd reiniciará el
        # watcher y reconciliará el estado completo recibido al reconectar.
        if process.poll() is None:
            process.terminate()

    return process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
