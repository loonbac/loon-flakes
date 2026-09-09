{
  lib,
  stdenvNoCC,
  fetchurl,
  copyDesktopItems,
  makeDesktopItem,
  x86_64Variant ? "generic",
}:

let
  metadata = builtins.fromJSON (builtins.readFile ./sources.json);
  revision = metadata.revision;
  shortRevision = builtins.substring 0 9 revision;

  variant =
    assert lib.assertOneOf "x86_64Variant" x86_64Variant [ "generic" "v3" ];
    x86_64Variant;
  sourceKey =
    if stdenvNoCC.hostPlatform.isx86_64 && variant == "v3"
    then "x86_64-linux-v3"
    else stdenvNoCC.hostPlatform.system;

  source =
    metadata.sources.${sourceKey}
      or (throw "citron-nextendo: unsupported platform ${stdenvNoCC.hostPlatform.system}");

  icon = fetchurl metadata.icon;

  inputRules = fetchurl metadata.inputRules;
in
stdenvNoCC.mkDerivation {
  pname = "citron-nextendo";
  version = "nightly-${shortRevision}${lib.optionalString (variant == "v3") "-v3"}";

  src = fetchurl source;
  dontUnpack = true;

  nativeBuildInputs = [ copyDesktopItems ];

  desktopItems = [
    (makeDesktopItem {
      name = "org.citron_emu.citron";
      desktopName = "Citron Nextendo";
      genericName = "Switch Emulator";
      comment = "Citron Neo with Nextendo Network online play";
      icon = "org.citron_emu.citron";
      exec = "citron %f";
      tryExec = "citron";
      categories = [ "Game" "Emulator" "Qt" ];
      keywords = [ "Nintendo" "Switch" "Nextendo" ];
      mimeTypes = [
        "application/x-nx-nro"
        "application/x-nx-nso"
        "application/x-nx-nsp"
        "application/x-nx-xci"
        "application/x-nx-dnsp"
        "application/x-nx-dxci"
      ];
      startupWMClass = "org.citron_emu.citron";
    })
  ];

  installPhase = ''
    runHook preInstall

    # El runtime universal incluido por upstream entiende su imagen DwarFS.
    # appimageTools de nixpkgs solo extrae SquashFS y no sirve para este asset.
    install -Dm755 "$src" "$out/bin/citron"
    install -Dm444 "${icon}" \
      "$out/share/icons/hicolor/scalable/apps/org.citron_emu.citron.svg"
    install -Dm444 "${inputRules}" \
      "$out/lib/udev/rules.d/72-citron-input.rules"

    runHook postInstall
  '';

  passthru = {
    inherit revision variant;
    releaseTag = metadata.releaseTag;
  };

  meta = {
    description = "Citron Neo fork with Nextendo Network online play";
    longDescription = ''
      Nextendo Network's Citron Neo fork, distributed as the upstream nightly
      AppImage. It contains no games, firmware, keys, or Nintendo code.
    '';
    homepage = "https://github.com/NextendoNetwork/citron-nextendo";
    license = lib.licenses.gpl3Plus;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "citron";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
