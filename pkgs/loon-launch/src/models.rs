// Modelo de una app/acción y constantes de layout del grid.
#[derive(Clone)]
pub struct Item {
    pub name: String,
    pub exec: String, // comando a ejecutar al activar
    pub icon: String,
}

// Las apps se muestran como lista en columnas de ROWS filas: las dos
// primeras columnas quedan visibles y el resto se desplaza a la derecha
// (scroll horizontal en el ScrolledWindow).
pub const ROWS: usize = 4;
pub const CELL_W: i32 = 230;
pub const ROW_H: i32 = 48;
