// Modelo de una app/acción y constantes de layout del grid.
#[derive(Clone)]
pub struct Item {
    pub name: String,
    pub exec: String, // comando a ejecutar al activar
    pub icon: String,
    /// Si es un wallpaper: el ícono es la miniatura de la imagen/video.
    pub is_wallpaper: bool,
    /// Cabecera de sección (no ejecutable, no seleccionable).
    pub is_header: bool,
    /// Ruta del media real (video o imagen) para el preview en vivo.
    pub media_path: String,
}

impl Item {
    pub fn app(name: impl Into<String>, exec: impl Into<String>, icon: impl Into<String>) -> Self {
        Item {
            name: name.into(),
            exec: exec.into(),
            icon: icon.into(),
            is_wallpaper: false,
            is_header: false,
            media_path: String::new(),
        }
    }

    pub fn wallpaper(name: impl Into<String>, exec: impl Into<String>, thumb: impl Into<String>) -> Self {
        Item {
            name: name.into(),
            exec: exec.into(),
            icon: thumb.into(),
            is_wallpaper: true,
            is_header: false,
            media_path: String::new(),
        }
    }

    pub fn header(name: impl Into<String>) -> Self {
        Item {
            name: name.into(),
            exec: String::new(),
            icon: String::new(),
            is_wallpaper: false,
            is_header: true,
            media_path: String::new(),
        }
    }

    pub fn with_media(mut self, path: impl Into<String>) -> Self {
        self.media_path = path.into();
        self
    }
}

// Las apps se muestran como lista en columnas de ROWS filas: las dos
// primeras columnas quedan visibles y el resto se desplaza a la derecha
// (scroll horizontal en el ScrolledWindow).
pub const ROWS: usize = 4;
pub const CELL_W: i32 = 230;
pub const ROW_H: i32 = 48;

// Ventana de apps: tamaño aprobado del launcher.
pub const WIN_W: i32 = 680;
pub const WIN_H: i32 = 350;
pub const BANNER_H: i32 = 180;

// Modo fondos: un poco más ancho para que el radio de la ventana
// no recorte el borde de las cards.
pub const WP_WIN_W: i32 = 740;
pub const WP_COLS: i32 = 2;
