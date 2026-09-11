import html
import os
import queue
import random
import re
import socket
import ssl
import subprocess
import tempfile
import threading
import time

import obspython as obs


TTS_BINARY = "@ttsBinary@"
TTS_MODEL = "@ttsModel@"
TTS_TOKENS = "@ttsTokens@"
TTS_DATA_DIR = "@ttsDataDir@"
SOURCE_NAME = "Twitch GLaDOS TTS"
SCENE_NAME = "Chat"
SOURCE_NAME_PATTERN = re.compile(r"^" + re.escape(SOURCE_NAME) + r"(?: \d+)+$")

channel = "loonbac21"
command = "!t"
max_chars = 220
user_cooldown = 12
queue_limit = 6
volume = 80
monitor = True
speed = 1.0
test_text = "Hola. Esta es una prueba del sistema de Aperture Science."

stop_event = threading.Event()
speech_queue = queue.Queue(maxsize=6)
ready_queue = queue.Queue(maxsize=6)
threads = []
irc_socket = None
tts_process = None
current_wav = None
current_started = 0.0
current_seen_playing = False
current_last_restart = 0.0
sequence = 0
loaded = False
frontend_ready = False
loaded_at = 0.0


def script_description():
    return (
        "Lee mensajes de !t del chat de Twitch con una voz GLaDOS local. "
        "La conexión IRC, la síntesis y los WAV efímeros solo existen mientras "
        "OBS está abierto. La fuente 'Twitch GLaDOS TTS' tiene su propio fader "
        "en el mezclador de audio."
    )


def script_defaults(settings):
    obs.obs_data_set_default_string(settings, "channel", "loonbac21")
    obs.obs_data_set_default_string(settings, "command", "!t")
    obs.obs_data_set_default_int(settings, "max_chars", 220)
    obs.obs_data_set_default_int(settings, "user_cooldown", 12)
    obs.obs_data_set_default_int(settings, "queue_limit", 6)
    obs.obs_data_set_default_int(settings, "volume", 80)
    obs.obs_data_set_default_bool(settings, "monitor", True)
    obs.obs_data_set_default_double(settings, "speed", 1.0)
    obs.obs_data_set_default_string(
        settings,
        "test_text",
        "Hola. Esta es una prueba del sistema de Aperture Science.",
    )


def script_properties():
    props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "channel", "Canal de Twitch", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "command", "Comando", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_int(props, "max_chars", "Máximo de caracteres", 20, 500, 10)
    obs.obs_properties_add_int(
        props, "user_cooldown", "Espera por usuario (segundos)", 0, 300, 1
    )
    obs.obs_properties_add_int(props, "queue_limit", "Tamaño máximo de cola", 1, 20, 1)
    obs.obs_properties_add_int_slider(props, "volume", "Volumen inicial", 0, 100, 1)
    obs.obs_properties_add_bool(props, "monitor", "Escuchar localmente y emitir")
    obs.obs_properties_add_float_slider(props, "speed", "Velocidad de voz", 0.7, 1.4, 0.05)
    obs.obs_properties_add_text(props, "test_text", "Texto de prueba", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_button(props, "test", "Probar voz", _test_voice)
    return props


def script_update(settings):
    global channel, command, max_chars, user_cooldown, queue_limit, volume, monitor, speed
    global test_text
    global irc_socket

    old_channel = channel
    requested_channel = obs.obs_data_get_string(settings, "channel").strip().lower()
    channel = re.sub(r"[^a-z0-9_]", "", requested_channel.lstrip("@#")) or "loonbac21"
    command = obs.obs_data_get_string(settings, "command").strip() or "!t"
    max_chars = max(20, obs.obs_data_get_int(settings, "max_chars"))
    user_cooldown = max(0, obs.obs_data_get_int(settings, "user_cooldown"))
    queue_limit = max(1, obs.obs_data_get_int(settings, "queue_limit"))
    volume = min(100, max(0, obs.obs_data_get_int(settings, "volume")))
    monitor = obs.obs_data_get_bool(settings, "monitor")
    speed = min(1.4, max(0.7, obs.obs_data_get_double(settings, "speed")))
    test_text = obs.obs_data_get_string(settings, "test_text").strip() or test_text

    if loaded and frontend_ready:
        _ensure_source()
        _apply_source_audio_settings()

    if old_channel != channel and irc_socket is not None:
        try:
            irc_socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def script_load(settings):
    global loaded, frontend_ready, loaded_at, threads
    loaded = True
    frontend_ready = False
    loaded_at = time.monotonic()
    stop_event.clear()
    _prepare_runtime_dir()
    obs.obs_frontend_add_event_callback(_frontend_event)
    obs.timer_add(_main_tick, 100)

    threads = [
        threading.Thread(target=_irc_loop, name="obs-twitch-irc", daemon=True),
        threading.Thread(target=_tts_loop, name="obs-glados-tts", daemon=True),
    ]
    for thread in threads:
        thread.start()
    _log(obs.LOG_INFO, "TTS iniciado para #" + channel + "; esperando " + command)


def script_unload():
    global loaded, frontend_ready, irc_socket, tts_process, threads
    global current_wav, current_started, current_seen_playing, current_last_restart
    loaded = False
    frontend_ready = False
    stop_event.set()
    obs.timer_remove(_main_tick)
    obs.obs_frontend_remove_event_callback(_frontend_event)

    sock = irc_socket
    irc_socket = None
    if sock is not None:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    process = tts_process
    if process is not None and process.poll() is None:
        process.terminate()

    for thread in threads:
        thread.join(timeout=1.5)
    threads = []
    # La fuente forma parte de la colección y debe sobrevivir al cierre de OBS.
    # Borrarla aquí provoca que el cargador de escenas y el script compitan por
    # el mismo nombre durante el siguiente arranque.
    _clear_source_file()
    _clean_runtime_dir()
    current_wav = None
    current_started = 0.0
    current_seen_playing = False
    current_last_restart = 0.0


def _runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    return os.path.join(base, "obs-twitch-glados-tts")


def _prepare_runtime_dir():
    path = _runtime_dir()
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    _clean_wavs(path)


def _clean_wavs(path=None):
    directory = path or _runtime_dir()
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for name in names:
        if name.endswith(".wav"):
            try:
                os.unlink(os.path.join(directory, name))
            except OSError:
                pass


def _clean_runtime_dir():
    _clean_wavs()
    try:
        os.rmdir(_runtime_dir())
    except OSError:
        pass


def _log(level, message):
    # OBS abre el panel de logs de scripts al recibir advertencias, lo cual es
    # intrusivo durante un stream. El TTS se recupera solo de desconexiones y no
    # necesita notificaciones emergentes.
    return


def _frontend_event(event):
    global frontend_ready
    if event in (
        obs.OBS_FRONTEND_EVENT_FINISHED_LOADING,
        obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED,
    ):
        frontend_ready = True
        _ensure_source()
        _apply_source_audio_settings()
        return

    if event in (
        obs.OBS_FRONTEND_EVENT_SCENE_CHANGED,
        obs.OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED,
    ) and frontend_ready:
        _ensure_source()


def _ensure_source():
    if not frontend_ready:
        return

    _remove_duplicate_sources()
    source = obs.obs_get_source_by_name(SOURCE_NAME)
    if source is None:
        settings = obs.obs_data_create()
        obs.obs_data_set_bool(settings, "is_local_file", True)
        obs.obs_data_set_bool(settings, "looping", False)
        obs.obs_data_set_bool(settings, "restart_on_activate", True)
        obs.obs_data_set_bool(settings, "clear_on_media_end", True)
        obs.obs_data_set_bool(settings, "close_when_inactive", True)
        source = obs.obs_source_create("ffmpeg_source", SOURCE_NAME, settings, None)
        obs.obs_data_release(settings)

    if source is None:
        _log(obs.LOG_ERROR, "No se pudo crear la fuente de audio " + SOURCE_NAME)
        return

    scene_source = obs.obs_get_source_by_name(SCENE_NAME)
    if scene_source is not None:
        scene = obs.obs_scene_from_source(scene_source)
        if scene is not None and obs.obs_scene_find_source(scene, SOURCE_NAME) is None:
            obs.obs_scene_add(scene, source)
        obs.obs_source_release(scene_source)

    obs.obs_source_set_volume(source, volume / 100.0)
    obs.obs_source_set_monitoring_type(
        source,
        obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT
        if monitor
        else obs.OBS_MONITORING_TYPE_NONE,
    )
    obs.obs_source_release(source)


def _remove_duplicate_sources():
    """Retira únicamente copias numéricas creadas por la carrera de arranque."""
    sources = obs.obs_enum_sources()
    if sources is None:
        return
    try:
        for source in sources:
            name = obs.obs_source_get_name(source) or ""
            if not SOURCE_NAME_PATTERN.fullmatch(name):
                continue
            if obs.obs_source_get_id(source) != "ffmpeg_source":
                continue
            obs.obs_source_remove(source)
    finally:
        obs.source_list_release(sources)


def _apply_source_audio_settings():
    source = obs.obs_get_source_by_name(SOURCE_NAME)
    if source is None:
        return
    obs.obs_source_set_volume(source, volume / 100.0)
    obs.obs_source_set_monitoring_type(
        source,
        obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT
        if monitor
        else obs.OBS_MONITORING_TYPE_NONE,
    )
    obs.obs_source_release(source)


def _clear_source_file(source=None):
    owned_reference = source is None
    if source is None:
        source = obs.obs_get_source_by_name(SOURCE_NAME)
    if source is None:
        return
    obs.obs_source_media_stop(source)
    settings = obs.obs_data_create()
    obs.obs_data_set_string(settings, "local_file", "")
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    if owned_reference:
        obs.obs_source_release(source)


def _main_tick():
    global frontend_ready, current_wav, current_started, current_seen_playing
    global current_last_restart

    if not frontend_ready:
        # Al cargar el script manualmente, OBS ya emitió FINISHED_LOADING. En
        # ese caso esperamos dos segundos y exigimos que la escena destino esté
        # presente antes de permitir la creación. Durante el arranque normal el
        # evento anterior habilita esta ruta sin demora ni carreras.
        if time.monotonic() - loaded_at < 2.0:
            return
        scene_source = obs.obs_get_source_by_name(SCENE_NAME)
        if scene_source is None:
            return
        obs.obs_source_release(scene_source)
        frontend_ready = True
        _ensure_source()

    source = obs.obs_get_source_by_name(SOURCE_NAME)
    if source is None:
        _ensure_source()
        source = obs.obs_get_source_by_name(SOURCE_NAME)
        if source is None:
            return

    if current_wav is not None:
        state = obs.obs_source_media_get_state(source)
        busy = state in (
            obs.OBS_MEDIA_STATE_PLAYING,
            obs.OBS_MEDIA_STATE_OPENING,
            obs.OBS_MEDIA_STATE_BUFFERING,
            obs.OBS_MEDIA_STATE_PAUSED,
        )
        now = time.monotonic()
        if busy:
            if state == obs.OBS_MEDIA_STATE_PLAYING:
                current_seen_playing = True
            obs.obs_source_release(source)
            return
        if not current_seen_playing and now - current_started < 30:
            # Loading a scene and opening a media file are asynchronous. Keep
            # the WAV alive until OBS has actually started reading it.
            if now - current_last_restart >= 1:
                obs.obs_source_media_restart(source)
                current_last_restart = now
            obs.obs_source_release(source)
            return
        if current_seen_playing and now - current_started < 0.75:
            obs.obs_source_release(source)
            return
        try:
            os.unlink(current_wav)
        except OSError:
            pass
        current_wav = None
        _clear_source_file(source)

    try:
        wav_path = ready_queue.get_nowait()
    except queue.Empty:
        obs.obs_source_release(source)
        return

    settings = obs.obs_data_create()
    obs.obs_data_set_bool(settings, "is_local_file", True)
    obs.obs_data_set_string(settings, "local_file", wav_path)
    obs.obs_data_set_bool(settings, "looping", False)
    obs.obs_data_set_bool(settings, "clear_on_media_end", True)
    obs.obs_data_set_bool(settings, "close_when_inactive", True)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
    obs.obs_source_media_restart(source)
    current_wav = wav_path
    current_started = time.monotonic()
    current_seen_playing = False
    current_last_restart = current_started
    obs.obs_source_release(source)


def _test_voice(props, prop):
    _enqueue_speech(_sanitize_message(test_text))
    return True


def _enqueue_speech(text):
    if speech_queue.qsize() >= queue_limit:
        _log(obs.LOG_WARNING, "Cola TTS llena; mensaje descartado")
        return False
    try:
        speech_queue.put_nowait(text)
        return True
    except queue.Full:
        _log(obs.LOG_WARNING, "Cola TTS llena; mensaje descartado")
        return False


def _sanitize_message(message):
    text = html.unescape(message)
    text = re.sub(r"\x01ACTION\s+(.*?)\x01", r"\1", text)
    text = re.sub(r"https?://\S+|www\.\S+", " enlace ", text, flags=re.IGNORECASE)
    text = "".join(char if char.isprintable() else " " for char in text)
    text = re.sub(r"(.)\1{7,}", lambda match: match.group(1) * 3, text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:max_chars].strip()


def _is_common_chat_expression(token):
    token = token.casefold()
    if len(token) > 24:
        return False
    fixed = {
        "xd", "lol", "lmao", "rofl", "uwu", "owo", "gg", "wp", "nt",
        "ez", "f", "wtf", "omg", "bruh", "kekw", "lul", "kappa",
        "pog", "pogchamp", "copium", "monkas", "pepega", "based",
    }
    if token in fixed:
        return True
    return bool(
        re.fullmatch(r"x{1,3}d{1,6}", token)
        or re.fullmatch(r"(?:ja|je|ji|jo|ju){2,}", token)
        or re.fullmatch(r"(?:ha|he|hi|ho|hu){2,}", token)
    )


def _looks_like_gibberish(message):
    text = html.unescape(message).casefold().strip()
    text = re.sub(r"https?://\S+|www\.\S+", " enlace ", text)
    if not text:
        return False
    if len(text) > max_chars * 3:
        return True

    tokens = re.findall(r"[^\W\d_]+", text, flags=re.UNICODE)
    meaningful = [token for token in tokens if not _is_common_chat_expression(token)]
    if tokens and not meaningful:
        return False

    compact = "".join(char for char in text if char.isalnum())
    letters = [char for char in text if char.isalpha()]
    symbols = [char for char in text if not char.isalnum() and not char.isspace()]

    if re.search(r"(.)\1{7,}", compact):
        return True
    if re.search(r"(.{1,3})\1{4,}", compact):
        return True
    if re.search(r"(?:asdf|qwer|zxcv|hjkl|ñlkj|wasd){2,}", compact):
        return True
    if len(text) >= 12 and len(symbols) / len(text) > 0.45:
        return True

    word_counts = {}
    for token in meaningful:
        word_counts[token] = word_counts.get(token, 0) + 1
    if any(count >= 5 for count in word_counts.values()):
        return True

    vowels = set("aeiouáéíóúü")
    suspicious = 0
    for token in meaningful:
        if len(token) < 8:
            continue
        vowel_count = sum(char in vowels for char in token)
        vowel_ratio = vowel_count / len(token)
        if re.search(r"[bcdfghjklmnñpqrstvwxyz]{6,}", token):
            suspicious += 2
        elif vowel_ratio < 0.12 or vowel_ratio > 0.82:
            suspicious += 1
        if len(token) >= 14 and len(set(token)) / len(token) > 0.78:
            suspicious += 1

    if len(letters) >= 20:
        uppercase = sum(char.isupper() for char in message if char.isalpha())
        if uppercase / len(letters) > 0.9:
            suspicious += 1

    return suspicious >= 2


def _irc_loop():
    global irc_socket
    cooldowns = {}
    last_speaker = None
    last_speaker_at = 0.0
    reconnect_delay = 1

    while not stop_event.is_set():
        joined_channel = channel
        sock = None
        try:
            raw_socket = socket.create_connection(("irc.chat.twitch.tv", 6697), timeout=10)
            sock = ssl.create_default_context().wrap_socket(
                raw_socket, server_hostname="irc.chat.twitch.tv"
            )
            # Twitch puede dejar un canal inactivo durante varios minutos entre
            # PINGs. La conexión se desbloquea en script_unload al cerrar el
            # socket, por lo que no hace falta un timeout periódico.
            sock.settimeout(None)
            irc_socket = sock
            nickname = "justinfan" + str(random.randint(10000, 99999))
            payload = (
                "PASS SCHMOOPIIE\r\n"
                + "NICK " + nickname + "\r\n"
                + "CAP REQ :twitch.tv/tags twitch.tv/commands\r\n"
                + "JOIN #" + joined_channel + "\r\n"
            )
            sock.sendall(payload.encode("utf-8"))
            _log(obs.LOG_INFO, "Conectado al chat de #" + joined_channel)
            reconnect_delay = 1
            buffer = b""

            while not stop_event.is_set() and joined_channel == channel:
                chunk = sock.recv(4096)
                if not chunk:
                    raise ConnectionError("Twitch cerró la conexión")
                buffer += chunk
                while b"\r\n" in buffer:
                    raw_line, buffer = buffer.split(b"\r\n", 1)
                    line = raw_line.decode("utf-8", errors="replace")
                    if line.startswith("PING "):
                        sock.sendall(("PONG " + line[5:] + "\r\n").encode("utf-8"))
                        continue
                    parsed = _parse_privmsg(line, joined_channel)
                    if parsed is None:
                        continue
                    username, display_name, message = parsed
                    prefix = command + " "
                    if message != command and not message.startswith(prefix):
                        continue
                    raw_spoken = message[len(command):].lstrip()
                    if _looks_like_gibberish(raw_spoken):
                        _log(obs.LOG_WARNING, "Spam TTS bloqueado de " + username)
                        continue
                    spoken = _sanitize_message(raw_spoken)
                    if not spoken:
                        continue
                    now = time.monotonic()
                    if now - cooldowns.get(username, 0.0) < user_cooldown:
                        continue
                    introduction = username != last_speaker or now - last_speaker_at > 45
                    speech = (
                        _sanitize_message(display_name) + " dice. " + spoken
                        if introduction
                        else spoken
                    )
                    if _enqueue_speech(speech):
                        cooldowns[username] = now
                        last_speaker = username
                        last_speaker_at = now
        except (OSError, ssl.SSLError, ConnectionError) as error:
            if not stop_event.is_set():
                _log(obs.LOG_WARNING, "Chat desconectado; reintento automático: " + str(error))
        finally:
            if irc_socket is sock:
                irc_socket = None
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

        stop_event.wait(reconnect_delay)
        reconnect_delay = min(30, reconnect_delay * 2)


def _parse_privmsg(line, expected_channel):
    tags = {}
    if line.startswith("@"):
        raw_tags, separator, line = line.partition(" ")
        if not separator:
            return None
        for entry in raw_tags[1:].split(";"):
            key, _, value = entry.partition("=")
            tags[key] = _decode_twitch_tag(value)
    match = re.match(r":([^! ]+)!\S+ PRIVMSG #([^ ]+) :(.*)$", line)
    if match is None or match.group(2).lower() != expected_channel:
        return None
    username = match.group(1).lower()
    display_name = tags.get("display-name") or match.group(1)
    return username, display_name, match.group(3)


def _decode_twitch_tag(value):
    replacements = {
        "s": " ",
        ":": ";",
        "r": "\r",
        "n": "\n",
        "\\": "\\",
    }
    return re.sub(r"\\(.)", lambda match: replacements.get(match.group(1), match.group(1)), value)


def _tts_loop():
    global sequence, tts_process
    while not stop_event.is_set():
        try:
            text = speech_queue.get(timeout=0.5)
        except queue.Empty:
            continue

        sequence += 1
        wav_path = os.path.join(_runtime_dir(), "speech-{:06d}.wav".format(sequence))
        args = [
            TTS_BINARY,
            "--vits-model=" + TTS_MODEL,
            "--vits-tokens=" + TTS_TOKENS,
            "--vits-data-dir=" + TTS_DATA_DIR,
            "--output-filename=" + wav_path,
            "--num-threads=2",
            "--vits-length-scale=" + str(speed),
            "--tts-max-num-sentences=1",
            text,
        ]
        try:
            tts_process = subprocess.Popen(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            _, stderr = tts_process.communicate(timeout=45)
            if tts_process.returncode != 0:
                raise RuntimeError((stderr or "error desconocido").strip()[-500:])
            if stop_event.is_set():
                try:
                    os.unlink(wav_path)
                except OSError:
                    pass
                continue
            try:
                ready_queue.put(wav_path, timeout=1)
            except queue.Full:
                os.unlink(wav_path)
        except subprocess.TimeoutExpired:
            tts_process.kill()
            tts_process.wait()
            _log(obs.LOG_ERROR, "La síntesis TTS excedió 45 segundos")
            try:
                os.unlink(wav_path)
            except OSError:
                pass
        except (OSError, RuntimeError) as error:
            _log(obs.LOG_ERROR, "Falló la síntesis TTS: " + str(error))
            try:
                os.unlink(wav_path)
            except OSError:
                pass
        finally:
            tts_process = None
            speech_queue.task_done()
