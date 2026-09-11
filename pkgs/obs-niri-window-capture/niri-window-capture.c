/*
 * Persistent application capture for OBS Studio on niri.
 *
 * Video is acquired by OBS' xdg-desktop-portal PipeWire source. The user
 * authorizes niri's stable "Dynamic Cast Target" once; this plugin switches
 * that target to the selected application through niri IPC.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <gio/gio.h>
#include <obs/obs-module.h>
#include <string.h>

OBS_DECLARE_MODULE()
OBS_MODULE_AUTHOR("loonbac")

#define MAX_WINDOWS 256
#define TARGET_SEPARATOR "\x1f"
#define DBUS_TIMEOUT_MS 5000
#define NIRI_BIN "@niriBin@"

typedef struct {
  guint64 id;
  gchar title[512];
  gchar app_id[256];
} niri_window_t;

typedef struct {
  obs_source_t *source;
  obs_source_t *portal_source;
  obs_data_t *settings;
  GThread *thread;
  GMutex mutex;
  GCond cond;
  gboolean stop_requested;
  gboolean child_showing;
} capture_data_t;

static gboolean should_stop(capture_data_t *data) {
  gboolean stop;
  g_mutex_lock(&data->mutex);
  stop = data->stop_requested;
  g_mutex_unlock(&data->mutex);
  return stop;
}

static gint fetch_windows(niri_window_t *windows, gint capacity) {
  GError *error = NULL;
  GVariant *response = NULL;
  GVariant *window_map = NULL;
  GDBusConnection *dbus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  gint count = 0;

  if (error != NULL) {
    blog(LOG_WARNING, "[niri-application-capture] D-Bus: %s", error->message);
    g_clear_error(&error);
    return 0;
  }

  response = g_dbus_connection_call_sync(
      dbus, "org.gnome.Shell.Introspect", "/org/gnome/Shell/Introspect",
      "org.gnome.Shell.Introspect", "GetWindows", NULL,
      G_VARIANT_TYPE("(a{ta{sv}})"), G_DBUS_CALL_FLAGS_NONE, DBUS_TIMEOUT_MS,
      NULL, &error);

  if (error != NULL) {
    blog(LOG_WARNING, "[niri-application-capture] Window list: %s",
         error->message);
    g_clear_error(&error);
    goto cleanup;
  }

  g_variant_get(response, "(@a{ta{sv}})", &window_map);
  GVariantIter iterator;
  GVariant *properties;
  guint64 id;
  g_variant_iter_init(&iterator, window_map);

  while (count < capacity &&
         g_variant_iter_next(&iterator, "{t@a{sv}}", &id, &properties)) {
    const gchar *title = NULL;
    const gchar *app_id = NULL;
    g_variant_lookup(properties, "title", "&s", &title);
    g_variant_lookup(properties, "app-id", "&s", &app_id);
    if (title != NULL && app_id != NULL && app_id[0] != '\0' &&
        g_strcmp0(app_id, "com.obsproject.Studio.desktop") != 0) {
      windows[count].id = id;
      g_strlcpy(windows[count].title, title, sizeof(windows[count].title));
      g_strlcpy(windows[count].app_id, app_id,
                sizeof(windows[count].app_id));
      count++;
    }
    g_variant_unref(properties);
  }

cleanup:
  if (window_map != NULL)
    g_variant_unref(window_map);
  if (response != NULL)
    g_variant_unref(response);
  if (dbus != NULL)
    g_object_unref(dbus);
  return count;
}

static gchar *make_target(const niri_window_t *window) {
  return g_strdup_printf("%s" TARGET_SEPARATOR "%s", window->app_id,
                         window->title);
}

static void split_target(const gchar *target, gchar **app_id, gchar **title) {
  *app_id = NULL;
  *title = NULL;
  if (target == NULL || target[0] == '\0')
    return;
  const gchar *separator = strchr(target, '\x1f');
  if (separator == NULL) {
    *app_id = g_strdup(target);
    return;
  }
  *app_id = g_strndup(target, separator - target);
  *title = g_strdup(separator + 1);
}

static guint64 resolve_window_id(capture_data_t *data) {
  const gchar *target = obs_data_get_string(data->settings, "target");
  gchar *wanted_app_id = NULL;
  gchar *wanted_title = NULL;
  niri_window_t windows[MAX_WINDOWS] = {0};
  guint64 fallback = 0;

  split_target(target, &wanted_app_id, &wanted_title);
  if (wanted_app_id == NULL || wanted_app_id[0] == '\0')
    goto cleanup;

  gint count = fetch_windows(windows, MAX_WINDOWS);
  for (gint i = 0; i < count; i++) {
    if (g_strcmp0(windows[i].app_id, wanted_app_id) != 0)
      continue;
    if (fallback == 0)
      fallback = windows[i].id;
    if (wanted_title != NULL && wanted_title[0] != '\0' &&
        g_strcmp0(windows[i].title, wanted_title) == 0) {
      fallback = windows[i].id;
      break;
    }
  }

cleanup:
  g_free(wanted_app_id);
  g_free(wanted_title);
  return fallback;
}

static gboolean set_dynamic_target(guint64 window_id) {
  GError *error = NULL;
  GSubprocess *process;
  if (window_id == 0) {
    process = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE,
        &error, NIRI_BIN, "msg", "action", "clear-dynamic-cast-target", NULL);
  } else {
    gchar id[32];
    g_snprintf(id, sizeof(id), "%" G_GUINT64_FORMAT, window_id);
    process = g_subprocess_new(
        G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE,
        &error, NIRI_BIN, "msg", "action", "set-dynamic-cast-window", "--id",
        id, NULL);
  }
  if (process == NULL) {
    blog(LOG_WARNING, "[niri-application-capture] Cannot run niri: %s",
         error->message);
    g_clear_error(&error);
    return FALSE;
  }
  gboolean success = g_subprocess_wait_check(process, NULL, &error);
  if (!success) {
    blog(LOG_WARNING, "[niri-application-capture] Cannot change target: %s",
         error->message);
    g_clear_error(&error);
  }
  g_object_unref(process);
  return success;
}

static void wait_for_change(capture_data_t *data) {
  g_mutex_lock(&data->mutex);
  if (!data->stop_requested) {
    gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
    g_cond_wait_until(&data->cond, &data->mutex, deadline);
  }
  g_mutex_unlock(&data->mutex);
}

static gpointer capture_thread(gpointer pointer) {
  capture_data_t *data = pointer;
  guint64 current_id = G_MAXUINT64;
  while (!should_stop(data)) {
    guint64 window_id = resolve_window_id(data);
    if (window_id != current_id && set_dynamic_target(window_id)) {
      current_id = window_id;
      blog(LOG_INFO, "[niri-application-capture] Dynamic target: %" G_GUINT64_FORMAT,
           window_id);
    }
    wait_for_change(data);
  }
  return NULL;
}

static void start_tracker(capture_data_t *data) {
  g_mutex_lock(&data->mutex);
  if (data->thread == NULL) {
    data->stop_requested = FALSE;
    data->thread =
        g_thread_new("OBS niri application tracker", capture_thread, data);
  }
  g_mutex_unlock(&data->mutex);
}

static void stop_tracker(capture_data_t *data) {
  g_mutex_lock(&data->mutex);
  GThread *thread = data->thread;
  if (thread == NULL) {
    g_mutex_unlock(&data->mutex);
    return;
  }
  data->stop_requested = TRUE;
  g_cond_broadcast(&data->cond);
  g_mutex_unlock(&data->mutex);
  g_thread_join(thread);
  g_mutex_lock(&data->mutex);
  data->thread = NULL;
  g_mutex_unlock(&data->mutex);
}

static const char *source_name(void *unused) {
  UNUSED_PARAMETER(unused);
  return "Captura de aplicación (Niri)";
}

static void *source_create(obs_data_t *settings, obs_source_t *source) {
  capture_data_t *data = g_new0(capture_data_t, 1);
  data->source = source;
  data->settings = settings;
  obs_data_addref(settings);
  g_mutex_init(&data->mutex);
  g_cond_init(&data->cond);

  obs_data_t *portal_settings = obs_data_create();
  const char *token = obs_data_get_string(settings, "RestoreToken");
  if (token != NULL && token[0] != '\0')
    obs_data_set_string(portal_settings, "RestoreToken", token);
  data->portal_source = obs_source_create_private(
      "pipewire-screen-capture-source", NULL, portal_settings);
  obs_data_release(portal_settings);

  if (data->portal_source == NULL) {
    blog(LOG_ERROR,
         "[niri-application-capture] PipeWire portal source unavailable");
    obs_data_release(data->settings);
    g_mutex_clear(&data->mutex);
    g_cond_clear(&data->cond);
    g_free(data);
    return NULL;
  }
  return data;
}

static void source_destroy(void *pointer) {
  capture_data_t *data = pointer;
  stop_tracker(data);
  if (data->child_showing)
    obs_source_dec_showing(data->portal_source);
  obs_source_release(data->portal_source);
  obs_data_release(data->settings);
  g_mutex_clear(&data->mutex);
  g_cond_clear(&data->cond);
  g_free(data);
}

static void source_defaults(obs_data_t *settings) {
  obs_data_set_default_string(settings, "target", "");
  obs_data_set_default_string(settings, "RestoreToken", "");
}

static obs_properties_t *source_properties(void *pointer) {
  capture_data_t *data = pointer;
  obs_properties_t *properties = obs_properties_create();
  obs_property_t *target =
      obs_properties_add_list(properties, "target", "Aplicación / ventana",
                              OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
  obs_property_list_add_string(target, "— Selecciona una ventana —", "");

  niri_window_t windows[MAX_WINDOWS] = {0};
  gint count = fetch_windows(windows, MAX_WINDOWS);
  const gchar *saved = obs_data_get_string(data->settings, "target");
  gboolean saved_is_present = saved == NULL || saved[0] == '\0';
  for (gint i = 0; i < count; i++) {
    gchar *value = make_target(&windows[i]);
    gchar *label =
        g_strdup_printf("%s — %s", windows[i].title, windows[i].app_id);
    obs_property_list_add_string(target, label, value);
    if (g_strcmp0(saved, value) == 0)
      saved_is_present = TRUE;
    g_free(label);
    g_free(value);
  }
  if (!saved_is_present) {
    gchar *app_id = NULL;
    gchar *title = NULL;
    split_target(saved, &app_id, &title);
    gchar *label = g_strdup_printf(
        "[No está abierta] %s — %s",
        title != NULL && title[0] != '\0' ? title : app_id, app_id);
    obs_property_list_add_string(target, label, saved);
    g_free(label);
    g_free(app_id);
    g_free(title);
  }
  obs_properties_add_text(
      properties, "portal_note",
      "Primera vez: en el diálogo del sistema elige “niri Dynamic Cast "
      "Target”. Después no volverá a preguntarlo.",
      OBS_TEXT_INFO);
  return properties;
}

static void source_update(void *pointer, obs_data_t *settings) {
  UNUSED_PARAMETER(settings);
  capture_data_t *data = pointer;
  g_mutex_lock(&data->mutex);
  g_cond_broadcast(&data->cond);
  g_mutex_unlock(&data->mutex);
}

static void source_save(void *pointer, obs_data_t *settings) {
  capture_data_t *data = pointer;
  obs_data_t *portal_settings = obs_source_get_settings(data->portal_source);
  const char *token = obs_data_get_string(portal_settings, "RestoreToken");
  if (token != NULL && token[0] != '\0')
    obs_data_set_string(settings, "RestoreToken", token);
  obs_data_release(portal_settings);
}

static void source_show(void *pointer) {
  capture_data_t *data = pointer;
  if (!data->child_showing) {
    obs_source_inc_showing(data->portal_source);
    data->child_showing = TRUE;
  }
  obs_source_add_active_child(data->source, data->portal_source);
  start_tracker(data);
}

static void source_hide(void *pointer) {
  capture_data_t *data = pointer;
  stop_tracker(data);
  obs_source_remove_active_child(data->source, data->portal_source);
  if (data->child_showing) {
    obs_source_dec_showing(data->portal_source);
    data->child_showing = FALSE;
  }
}

static uint32_t source_width(void *pointer) {
  capture_data_t *data = pointer;
  return obs_source_get_width(data->portal_source);
}

static uint32_t source_height(void *pointer) {
  capture_data_t *data = pointer;
  return obs_source_get_height(data->portal_source);
}

static void source_render(void *pointer, gs_effect_t *effect) {
  UNUSED_PARAMETER(effect);
  capture_data_t *data = pointer;
  obs_source_video_render(data->portal_source);
}

bool obs_module_load(void) {
  static struct obs_source_info source_info = {
      .id = "niri-window-capture-source",
      .type = OBS_SOURCE_TYPE_INPUT,
      .output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_CUSTOM_DRAW |
                      OBS_SOURCE_DO_NOT_DUPLICATE,
      .get_name = source_name,
      .create = source_create,
      .destroy = source_destroy,
      .get_defaults = source_defaults,
      .get_properties = source_properties,
      .update = source_update,
      .save = source_save,
      .show = source_show,
      .hide = source_hide,
      .get_width = source_width,
      .get_height = source_height,
      .video_render = source_render,
      .icon_type = OBS_ICON_TYPE_WINDOW_CAPTURE,
  };
  obs_register_source(&source_info);
  blog(LOG_INFO, "[niri-application-capture] Plugin loaded");
  return true;
}

MODULE_EXPORT const char *obs_module_description(void) {
  return "Persistent application capture through niri Dynamic Cast Target";
}
