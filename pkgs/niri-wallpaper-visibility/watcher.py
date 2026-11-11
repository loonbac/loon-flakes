#!/usr/bin/env python3
"""Pausa mpvpaper salvo que el foco esté en un terminal o el workspace esté vacío."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any


# Política: el wallpaper animado corre SOLO a pleno cuando el foco está en un
# terminal o el workspace visible está vacío. Con cualquier otra ventana
# enfocada se congela en el último frame, y ahí está el ahorro: mpv deja de
# decodificar mientras el usuario mira el navegador o el chat. Por eso la
# lista es cerrada y de terminales; una app translúcida NO se añade aunque
# deje ver el fondo, porque detrás de ella el frame congelado apenas se nota
# y el ahorro compensa. Debe coincidir con el window-rule de ghostty en
# config.kdl (opacity 0.8 + xray), la única superficie que lo deja ver.
ANIMATED_APP_IDS = frozenset({"com.mitchellh.ghostty"})
PAUSE_REASON = "opaque-window"


class VisibilityState:
    def __init__(self) -> None:
        self.workspaces: dict[int, dict[str, Any]] = {}
        self.windows: dict[int, dict[str, Any]] = {}

    def should_freeze_wallpaper(self) -> bool:
        """True si el wallpaper debe congelarse: hay una ventana enfocada que
        no es terminal en algún workspace visible. Los workspaces vacíos no
        cuentan: en el escritorio solo el fondo corre."""
        for workspace in self.workspaces.values():
            if not workspace.get("is_active"):
                continue
            window_id = workspace.get("active_window_id")
            if window_id is None:
                continue
            window = self.windows.get(window_id)
            # Durante actualizaciones no atómicas, congelar de forma conservadora
            # hasta que llegue la descripción de la ventana.
            if window is None or window.get("app_id") not in ANIMATED_APP_IDS:
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


def wallpaper_status() -> str:
    try:
        result = subprocess.run(
            ["mpvpaper-wallpaper", "status"],
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        )
    except OSError:
        return ""
    return result.stdout.strip()


def pause_reasons() -> list[str]:
    """Motivos de pausa presentes, como 'manual (3h2m, cli)'.

    Se listan todos, incluido el propio `opaque-window`: si después de pedir
    animación sigue ahí, es información útil (otra instancia lo puso o el
    `resume` no llegó), no algo que deba esconderse.
    """
    try:
        result = subprocess.run(
            ["mpvpaper-wallpaper", "reasons"],
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        )
    except OSError:
        return []
    reasons: list[str] = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        # reason<TAB>age<TAB>owner
        if len(fields) < 2:
            continue
        owner = fields[2] if len(fields) > 2 else "desconocido"
        reasons.append(f"{fields[0]} ({fields[1]}, {owner})")
    return reasons


_paused_warning: tuple[str, ...] | None = None


def warn_if_still_paused(desired_freeze: bool) -> None:
    """Avisa en el journal cuando el fondo sigue pausado pese a querer animarlo.

    Sin este aviso una pausa ajena es invisible: `status` solo dice 'paused' y el
    fondo se queda en el último frame hasta que alguien piense en correr
    `mpvpaper-wallpaper reasons`. Pasó el 2026-11-10: un motivo 'manual' de
    origen 'cli' congeló el fondo tres horas y ningún cambio de foco lo retiró,
    porque los motivos ajenos solo los retira una orden explícita `resume`.
    Se avisa una sola vez por conjunto de motivos para no inundar el journal
    con cada cambio de foco.
    """
    global _paused_warning
    if desired_freeze:
        return
    if wallpaper_status() != "paused":
        # Dejó de estar pausado: si vuelve a ocurrir, volverá a avisar.
        _paused_warning = None
        return
    reasons = pause_reasons()
    signature = tuple(reasons)
    if signature == _paused_warning:
        return
    _paused_warning = signature
    if reasons:
        detail = f"por: {', '.join(reasons)}"
    else:
        detail = (
            "sin ningún motivo registrado: es una pausa directa sobre el IPC de "
            "mpv, y el próximo `pause` la conservará como motivo 'manual'"
        )
    print(
        "niri-wallpaper-visibility: el fondo animado sigue pausado "
        f"{detail}. Reanuda con: mpvpaper-wallpaper resume",
        file=sys.stderr,
        flush=True,
    )


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
            desired = state.should_freeze_wallpaper()
            if desired != applied:
                set_wallpaper_paused(desired)
                applied = desired
            # Se comprueba también cuando no hubo que actuar: una pausa ajena
            # puede aparecer (o desaparecer) sin que cambie la visibilidad.
            warn_if_still_paused(desired)
    finally:
        # El motivo se conserva si niri corta el stream; systemd reiniciará el
        # watcher y reconciliará el estado completo recibido al reconectar.
        if process.poll() is None:
            process.terminate()

    return process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
