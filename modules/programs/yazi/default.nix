# Módulo "programs/yazi": configuración gestionada del abridor de archivos.
#
# La config se genera en /etc/yazi/yazi.toml y tmpfiles la enlaza al directorio
# que Yazi consulta en el home del usuario.
{ pkgs, ... }:

let
  yaziConfig = (pkgs.formats.toml { }).generate "yazi.toml" {
    opener.notepad-next = [
      {
        run = "${pkgs.notepad-next}/bin/NotepadNext %s";
        orphan = true;
        desc = "Notepad Next";
        for = "linux";
      }
    ];

    open.prepend_rules = [
      {
        mime = "text/*";
        use = "notepad-next";
      }
      {
        mime = "application/{json,ndjson,toml,yaml,x-yaml,xml,javascript,x-javascript}";
        use = "notepad-next";
      }
    ];
  };
in
{
  environment.etc."yazi/yazi.toml".source = yaziConfig;

  # Ruta absoluta: systemd-tmpfiles no expande "~".
  systemd.tmpfiles.rules = [
    "d /home/loonbac/.config/yazi 0755 loonbac users -"
    "L+ /home/loonbac/.config/yazi/yazi.toml - - - - /etc/yazi/yazi.toml"
  ];
}
