# Servicio OpenSSH: cada servicio en su propia carpeta, como un crate.
# Habilita el daemon sshd y endurece el acceso (no root; contraseñas según modo).
#
# El modo de autenticación se lee de `./ssh-auth-mode`:
#   - "password" -> PasswordAuthentication = true (admite contraseña)
#   - cualquier otro valor (p. ej. "cert") -> solo claves
# El comando custom `nixos-ssh` cambia ese archivo y aplica la configuración.
{ config, lib, pkgs, ... }:

let
  sshAuthModeFile = ./ssh-auth-mode;
  # Si el archivo falta o tiene un valor inesperado, cae a "cert" (seguro:
  # solo claves, contraseñas desactivadas).
  sshAuthMode =
    if builtins.pathExists sshAuthModeFile
    then lib.trim (builtins.readFile sshAuthModeFile)
    else "cert";
in
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = (sshAuthMode == "password");
      # Impide login directo como root por SSH.
      PermitRootLogin = "no";
    };
  };
}
