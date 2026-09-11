project(
  'obs-niri-window-capture',
  'c',
  version: '0.2.0',
  default_options: ['c_std=gnu11', 'warning_level=2'],
)

shared_library(
  'obs-niri-window-capture',
  'niri-window-capture.c',
  name_prefix: '',
  dependencies: [
    meson.get_compiler('c').find_library('obs'),
    dependency('gio-2.0'),
  ],
  install: true,
  install_dir: join_paths(get_option('libdir'), 'obs-plugins'),
)
