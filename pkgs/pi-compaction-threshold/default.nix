{ lib
, stdenvNoCC
, nodejs
, makeWrapper
, testers
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-compaction-threshold";
  version = "1.0.0";

  src = ./.;
  nativeBuildInputs = [ nodejs makeWrapper ];
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    node --test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 sync.mjs "$out/libexec/pi-compaction-threshold/sync.mjs"
    # `pi` se resuelve en tiempo de ejecución a propósito: el launcher de nixpkgs
    # es su dueño, y esta herramienta debe leer el catálogo que ese launcher exponga.
    makeWrapper ${nodejs}/bin/node "$out/bin/pi-compaction-threshold" \
      --add-flags "$out/libexec/pi-compaction-threshold/sync.mjs"
    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
  };

  meta = {
    description = "Red de seguridad contra desbordamiento de contexto para modelos de Pi";
    longDescription = ''
      Configura un margen de seguridad (90% de la ventana de contexto) para que la
      auto-compactación nativa de Pi actúe únicamente como red de salvaguarda ante
      desbordamientos si el context guard de Jev falla o no está presente.
      La política de cadencia de compactación efectiva la decide Jev.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "pi-compaction-threshold";
  };
})
