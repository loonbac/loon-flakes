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
}

impl Item {
    pub fn app(name: impl Into<String>, exec: impl Into<String>, icon: impl Into<String>) -> Self {
        Item { name: name.into(), exec: exec.into(), icon: icon.into(), is_wallpaper: false, is_header: false }
    }

    pub fn wallpaper(name: impl Into<String>, exec: impl Into<String>, thumb: impl Into<String>) -> Self {
        Item { name: name.into(), exec: exec.into(), icon: thumb.into(), is_wallpaper: true, is_header: false }
    }

    pub fn header(name: impl Into<String>) -> Self {
        Item { name: name.into(), exec: String::new(), icon: String::new(), is_wallpaper: false, is_header: true }
    }
}

// Las apps se muestran como lista en columnas de ROWS filas: las dos
// primeras columnas quedan visibles y el resto se desplaza a la derecha
// (scroll horizontal en el ScrolledWindow).
pub const ROWS: usize = 4;
pub const CELL_W: i32 = 230;
pub const ROW_H: i32 = 48;
