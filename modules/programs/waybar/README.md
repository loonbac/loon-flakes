# Waybar (Tema V2.8 HANCORE + Paleta Dinámica)

Configuración de Waybar gestionada por NixOS, basada en el tema **V2.8** de [HANCORE-linux/waybar-themes](https://github.com/HANCORE-linux/waybar-themes) y adaptada para el compositor **Niri** con extracción de paleta completa dinámica desde el wallpaper.

---

### Estructura

```
modules/programs/waybar/
├── default.nix        # Módulo NixOS (symlinks, tmpfiles y defaults)
├── config.jsonc       # Configuración principal de Waybar
├── style.css          # Estilos CSS (importa paleta dinámica)
└── README.md          # Esta documentación
```

---

### Paleta Dinámica basada en el Wallpaper

El script `accent-wallpaper` analiza el fondo de pantalla actual (video mpvpaper o imagen estática) y genera en `~/.config/waybar/colors.css` la paleta completa:

- `@background`: Tono oscuro profundo y elegante extraído de la base del wallpaper.
- `@surface` / `@background_alt`: Tono intermedio para tooltips y capas elevadas.
- `@foreground`: Texto claro nítido y de alto contraste tintado armónicamente.
- `@accent`: Color más llamativo y saturado del wallpaper.
- `@on_accent`: Color de texto contrastante sobre el acento (`#000000` o `#ffffff`).
- `@highlight`: Segundo color de acento / matiz secundario.
- `@muted`: Color tenue para elementos secundarios.
- `@warning` / `@critical`: Colores de estado armónicos.
- `@color0` a `@color15`: Paleta ANSI completa derivada del fondo.

---

### Comandos útiles

- `accent-wallpaper`: Extrae y aplica inmediatamente la paleta del wallpaper activo, reiniciando Waybar en vivo.
- `accent-wallpaper from VIDEO_O_IMAGEN`: Analiza y aplica la paleta de un archivo específico.
- `omarchy-restart-waybar`: Reinicia Waybar de forma limpia en segundo plano.
