---
description: Actualizar el fork de NixOS desde mainstream (loonbac) — herramienta exclusiva del agente
subagent: false
---

Eres el único operador autorizado para traer mainstream a esta configuración de NixOS. Usa **exclusivamente** la herramienta `scripts/nixos-upstream-sync`: está prohibido hacer `git fetch`/`git merge`/`git pull` manuales. Los remotes son fijos (`origin` = fork `SaiToEJ/loon-flakes`, `upstream` = mainstream `loonbac/loon-flakes`); no los cambies ni los intercambies.

Procedimiento obligatorio:

1. Ejecuta desde la raíz del repo: `bash scripts/nixos-upstream-sync` y lee el JSON de stdout.
2. Actúa según `status`:
   - `up_to_date`: informa de que mainstream no trae cambios y termina.
   - `merged`: el fork ya quedó empujado. Verifica con `git status -sb` y `git log -1 --oneline`; después aplica `rebuild update` (pasa por el gate de `nixos-updates`) o `rebuild`, y reporta el resultado avisando de que la activación re-servicia unidades.
   - `conflict`: no resuelvas a ciegas; muestra `files` y pide decisión al usuario.
   - `error`: muestra `reason` y detente sin reintentar.
3. La entrega (rama/PR) sigue el flujo descrito en `AGENTS.md`.

$ARGUMENTS
