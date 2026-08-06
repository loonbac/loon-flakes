# Servicio OpenSSH: cada servicio en su propia carpeta, como un crate.
# Habilita el daemon sshd y endurece el acceso (solo claves, no root).
{ config, lib, pkgs, ... }:

{
  services.openssh = {
    enable = true;
    settings = {
      # Solo acceso por clave SSH; desactiva contraseñas.
      PasswordAuthentication = false;
      # Impide login directo como root por SSH.
      PermitRootLogin = "no";
    };
  };
}
