// LoonLaunch — launcher de apps para niri (Super+Space).
//
// Daemon persistente: la instancia única arranca oculta y vive en segundo
// plano. El bind de niri dispara "activate", que alterna visibilidad; como
// GtkApplication redirige las invocaciones siguientes a la instancia ya
// corriendo (D-Bus), el launcher aparece al instante sin re-inicializar GTK.
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
