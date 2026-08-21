# Módulo "programs/virtualbox": VirtualBox Host en NixOS.
#
# Configura el hipervisor VirtualBox tipo 2 en el sistema anfitrión:
#   - Módulos del kernel (vboxdrv, vboxnetflt, vboxnetadp) compilados para el kernel actual.
#   - Reglas de udev para permisos sobre /dev/vboxdrv.
#   - Grupo `vboxusers` para que el usuario pueda crear y ejecutar máquinas virtuales.
#   - Paquete VirtualBox (GUI en Qt + CLI VBoxManage) en systemPackages.
#   - Extension Pack de Oracle para soporte de USB 2.0/3.0, NVMe y RDP.
{ config, lib, pkgs, ... }:

{
  # Habilita VirtualBox como host (compila módulos de kernel y configura udev rules)
  virtualisation.virtualbox.host = {
    enable = true;
    # Extension Pack desactivado por defecto debido a restricciones de descarga directa de Oracle
    enableExtensionPack = false;
  };

  # Agrega al usuario loonbac al grupo vboxusers para acceder a los dispositivos de virtualización
  users.extraGroups.vboxusers.members = [ "loonbac" ];
}
