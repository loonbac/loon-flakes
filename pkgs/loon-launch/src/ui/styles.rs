// Estilos CSS del launcher (provider global del display).
use gtk4::prelude::*;

pub fn setup_styles(window: &gtk4::ApplicationWindow) {
    let css = gtk4::CssProvider::new();
    css.load_from_data(
        ".banner-viewport {
             border-radius: 18px 18px 0 0;
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
             transition: border-color 160ms cubic-bezier(0.16, 1, 0.3, 1),
                         box-shadow 160ms cubic-bezier(0.16, 1, 0.3, 1);
         }
         entry.search-entry:focus {
             border-color: rgba(160, 176, 255, 0.85);
             box-shadow: 0 0 0 3px rgba(88, 101, 242, 0.28);
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
         row {
             border-radius: 12px;
             transition: background-color 200ms cubic-bezier(0.16, 1, 0.3, 1);
         }
         row:hover {
             background-color: rgba(255, 255, 255, 0.06);
         }
         row.selected {
             background-color: rgba(88, 101, 242, 0.48);
             border-radius: 12px;
         }
         window.loon-launch.wallpaper-mode {
             background-color: rgba(9, 10, 15, 0.94);
         }
         .wallpaper-carousel {
             background-color: transparent;
         }
         label.section-header {
             color: rgba(230, 234, 255, 0.72);
             font-size: 11px;
             font-weight: 700;
             letter-spacing: 1.5px;
             text-transform: uppercase;
             margin-top: 0;
             margin-bottom: 4px;
         }
         scrollbar,
         scrollbar * {
             min-width: 0;
             min-height: 0;
             opacity: 0;
             background: transparent;
             border: none;
         }",
    );
    gtk4::style_context_add_provider_for_display(
        &WidgetExt::display(window),
        &css,
        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
