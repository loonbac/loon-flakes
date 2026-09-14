# Plataforma exclusiva de nixos-pc.
{ config, lib, pkgs, ... }:

let
  ddcBrightness = pkgs.callPackage ../../pkgs/ddc-brightness {
    monitorModel = "GM3CC236";
  };

  # Fedora publica shim con firmas de Microsoft UEFI CA 2011 y 2023. Esto
  # permite conservar exclusivamente las llaves de fábrica en el firmware y
  # delegar la confianza de la llave local de NixOS al almacén MOK de shim.
  fedoraShim = pkgs.stdenvNoCC.mkDerivation {
    pname = "fedora-shim-x64";
    version = "16.1-7";

    src = pkgs.fetchurl {
      url = "https://kojipkgs.fedoraproject.org/packages/shim/16.1/7/x86_64/shim-x64-16.1-7.x86_64.rpm";
      hash = "sha256-ChGfNIjl2ifKVcGGTujhMa+l7PJ2iThboJuAXrAN1gg=";
    };

    nativeBuildInputs = [ pkgs.rpmextract ];
    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      mkdir extracted
      cd extracted
      rpmextract "$src"

      install -Dm0755 \
        usr/lib/efi/shim/16.1-7/EFI/fedora/shimx64.efi \
        "$out/share/efi/shimx64.efi"
      install -Dm0755 \
        usr/lib/efi/shim/16.1-7/EFI/fedora/mmx64.efi \
        "$out/share/efi/mmx64.efi"

      runHook postInstall
    '';
  };

  # shim busca el cargador siguiente con el nombre fijo grubx64.efi. El
  # contenido sigue siendo systemd-boot, firmado con una llave MOK separada;
  # no se instala GRUB ni se sustituye la entrada actual.
  shimSync = pkgs.writeShellApplication {
    name = "nixos-shim-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.efibootmgr
      pkgs.gnugrep
      pkgs.openssl
      pkgs.sbsigntool
      pkgs.util-linux
    ];
    text = ''
      esp=/boot
      shim_dir="$esp/EFI/nixos-shim"
      mok_dir=/var/lib/nixos-shim
      key="$mok_dir/mok.key"
      cert="$mok_dir/mok.pem"
      unsigned_loader=${config.systemd.package}/lib/systemd/boot/efi/systemd-bootx64.efi

      if [ ! -e "$key" ] || [ ! -e "$cert" ]; then
        umask 0077
        install -d -m0700 "$mok_dir"
        openssl req -new -x509 -newkey rsa:4096 -sha256 -nodes \
          -keyout "$key" \
          -out "$cert" \
          -days 3650 \
          -subj '/CN=NixOS shim MOK/'
      fi
      if [ ! -r "$key" ] || [ ! -r "$cert" ]; then
        echo "nixos-shim-sync: faltan las llaves MOK en $mok_dir" >&2
        exit 1
      fi
      if ! mountpoint -q "$esp"; then
        echo "nixos-shim-sync: $esp no esta montado" >&2
        exit 1
      fi

      install -d -m0700 "$shim_dir"
      install -m0700 ${fedoraShim}/share/efi/shimx64.efi "$shim_dir/shimx64.efi"
      install -m0700 ${fedoraShim}/share/efi/mmx64.efi "$shim_dir/mmx64.efi"

      signed_loader=$(mktemp --tmpdir nixos-systemd-boot.XXXXXX.efi)
      trap 'rm -f "$signed_loader"' EXIT
      sbsign \
        --key "$key" \
        --cert "$cert" \
        --output "$signed_loader" \
        "$unsigned_loader"
      install -m0700 "$signed_loader" "$shim_dir/grubx64.efi"
      openssl x509 -in "$cert" -outform DER -out "$shim_dir/loon-nixos-mok.der"
      chmod 0600 "$shim_dir/loon-nixos-mok.der"
      rm -f "$shim_dir/loon-nixos-db.der"

      # Lanzaboote conserva su firma propia para el arranque directo y esta
      # segunda firma permite a systemd-boot cargar los mismos UKI vía MOK.
      signed_uki=$(mktemp --tmpdir nixos-uki.XXXXXX.efi)
      trap 'rm -f "$signed_loader" "$signed_uki"' EXIT
      for uki in "$esp"/EFI/Linux/nixos-generation-*.efi; do
        [ -e "$uki" ] || continue
        if sbverify --list "$uki" 2>/dev/null | grep -Fq '/CN=NixOS shim MOK'; then
          continue
        fi
        sbsign \
          --key "$key" \
          --cert "$cert" \
          --output "$signed_uki" \
          "$uki"
        install -m0700 "$signed_uki" "$uki"
      done

      # La entrada queda fuera de BootOrder hasta completar y comprobar MOK;
      # puede seleccionarse una sola vez mediante BootNext sin arriesgar la
      # entrada directa de Lanzaboote que ya funciona.
      if ! efibootmgr -v | grep -Fqi 'NixOS (Microsoft shim)'; then
        esp_device=$(findmnt -nro SOURCE --target "$esp")
        esp_device=$(readlink -f "$esp_device")
        esp_disk_name=$(lsblk -nro PKNAME "$esp_device")
        esp_partition=$(lsblk -nro PARTN "$esp_device")
        if [ -z "$esp_disk_name" ] || [ -z "$esp_partition" ]; then
          echo "nixos-shim-sync: no se pudo identificar la ESP $esp_device" >&2
          exit 1
        fi
        efibootmgr --create-only \
          --disk "/dev/$esp_disk_name" \
          --part "$esp_partition" \
          --label 'NixOS (Microsoft shim)' \
          --loader '\EFI\nixos-shim\shimx64.efi'
      fi
    '';
  };
in
{
  # Lanzaboote reemplaza al módulo systemd-boot y firma toda la cadena de
  # arranque. En el primer switch permite instalar sin firma, genera las claves
  # bajo /var/lib/sbctl y los switches posteriores instalan artefactos firmados.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    autoGenerateKeys.enable = true;
    # La ESP es de 196 MiB; conservar rollbacks suficientes sin saturarla con
    # initrds de generaciones antiguas.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # Vanguard también comprueba que la protección DMA/IOMMU esté disponible.
  # La opción IOMMU debe permanecer habilitada asimismo en el UEFI.
  boot.kernelParams = [ "amd_iommu=on" "iommu=pt" ];

  # Muestra el selector NixOS/Windows; el resto de hosts conserva el arranque
  # directo definido por el módulo común.
  boot.loader.timeout = 5;

  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;

  # Los monitores externos no exponen /sys/class/backlight. DDC/CI viaja por
  # los buses I2C de la NVIDIA; este backend controla el monitor principal
  # GM3CC236 conectado a DP-2 y alimenta el indicador de Waybar.
  hardware.i2c.enable = true;
  users.users.loonbac.extraGroups = [ "i2c" ];
  environment.systemPackages = [
    # Diagnóstico, verificación y enrolamiento manual de Secure Boot.
    pkgs.sbctl
    pkgs.efibootmgr
    pkgs.mokutil
    pkgs.ddcutil
    ddcBrightness
    shimSync
  ];

  # Mantiene la segunda entrada sincronizada en cada activación. Al usar el
  # systemd-boot del sistema actual no depende del orden interno de Lanzaboote.
  system.activationScripts.nixosShim = {
    deps = [ "etc" ];
    text = "${shimSync}/bin/nixos-shim-sync";
  };

  # Un único proceso conserva el estado, agrupa ráfagas de input y evita que
  # cada paso de la rueda bloquee esperando varios intercambios DDC.
  systemd.user.services.ddc-brightness = {
    description = "Control de brillo DDC/CI del monitor principal";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session-pre.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${ddcBrightness}/bin/ddc-brightness daemon";
      Restart = "on-failure";
      RestartSec = "1s";
      RuntimeDirectory = "ddc-brightness";
      RuntimeDirectoryMode = "0700";
    };
  };

  # La RTX 3060 usa el módulo de kernel propietario de NVIDIA: libfunnel
  # necesita sus capacidades DRM de sincronización explícita para PipeWire.
  # NixOS incorpora también nvidia-smi al PATH del sistema.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    open = false;
    modesetting.enable = true;
  };
}
