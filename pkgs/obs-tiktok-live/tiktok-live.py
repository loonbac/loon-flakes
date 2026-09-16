import os
import re
import signal
import subprocess

import obspython as obs


SERVICE = "@serviceBinary@"
PORT = 5124
process = None
loaded = False


def script_description():
    return (
        "Overlay local para TikTok LIVE: chat y alertas de regalos, follows, "
        "compartidos, entradas y likes. Añade las fuentes de navegador manualmente "
        "con las URLs locales indicadas en la documentación."
    )


def script_defaults(settings):
    obs.obs_data_set_default_string(settings, "unique_id", "")
    obs.obs_data_set_default_bool(settings, "show_joins", True)
    obs.obs_data_set_default_bool(settings, "show_likes", True)


def script_properties():
    props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "unique_id", "Usuario de TikTok (@usuario)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_bool(props, "show_joins", "Mostrar alertas al entrar")
    obs.obs_properties_add_bool(props, "show_likes", "Mostrar alertas de likes agrupados")
    return props


def _unique_id(settings):
    value = obs.obs_data_get_string(settings, "unique_id").strip()
    return re.sub(r"[^A-Za-z0-9._]", "", value.lstrip("@"))


def _stop():
    global process
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
    process = None


def _start(settings):
    global process
    _stop()
    process = subprocess.Popen(
        [
            SERVICE,
            "--port", str(PORT),
            "--unique-id", _unique_id(settings),
            "--show-joins", str(obs.obs_data_get_bool(settings, "show_joins")).lower(),
            "--show-likes", str(obs.obs_data_get_bool(settings, "show_likes")).lower(),
        ],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def script_load(settings):
    global loaded
    loaded = True
    _start(settings)


def script_update(settings):
    if loaded:
        _start(settings)


def script_unload():
    global loaded
    loaded = False
    _stop()
