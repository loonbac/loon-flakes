// LoonLaunch — launcher de apps para niri (Super+Space).
//
// Bootstrap mínimo: inicializa GTK y arma la UI. La lógica vive en
// módulos:
//   - models.rs : Item y constantes de layout
//   - apps.rs   : carga de .desktop y acciones de poder
//   - filter.rs : filtrado y navegación de selección (lógica pura)
//   - icons.rs  : caché y resolución de íconos
//   - ui/       : banner, grid, teclado y estilos
mod apps;
mod filter;
mod icons;
mod models;
mod ui;

#[cfg(test)]
mod tests;

use gtk4::prelude::*;

fn main() {
    let app = gtk4::Application::builder()
        .application_id("dev.loonbac.loonlaunch")
        .build();
    app.connect_activate(ui::build_ui);
    app.run();
}
