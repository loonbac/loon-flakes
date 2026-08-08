// Estilos CSS del launcher (provider global del display).
use gtk4::prelude::*;

pub fn setup_styles(window: &gtk4::ApplicationWindow) {
    let css = gtk4::CssProvider::new();
    css.load_from_data(
        ".banner-viewport {
             border-radius: 18px;
             overflow: hidden;
         }
         entry.search-entry {
             min-height: 46px;
             border-radius: 14px;
             background-color: rgba(22, 22, 30, 0.94);
             color: white;
             caret-color: white;
             border: 1px solid rgba(255, 255, 255, 0.42);
             padding: 10px 16px;
             font-size: 15px;
         }
         entry.search-entry placeholder {
             color: rgba(255, 255, 255, 0.78);
         }
         entry.search-entry selection {
             background-color: rgba(88, 101, 242, 0.9);
             color: white;
         }
         label.app-name {
             color: rgba(255, 255, 255, 0.96);
             font-size: 13px;
             font-weight: 500;
         }
         .selected {
             background-color: rgba(88, 101, 242, 0.48);
             border-radius: 12px;
         }",
    );
    // Provider global (display) para que aplique a TODOS los widgets,
    // incluido el banner-box (el provider de la ventana no alcanzaba).
    gtk4::style_context_add_provider_for_display(
        &WidgetExt::display(window),
        &css,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
