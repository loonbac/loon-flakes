{ stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "pi-gpt-fast-mode-shared";
  version = "1.0.0";
  src = ./.;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/src"
    cp package.json "$out/package.json"
    cp src/index.ts "$out/src/index.ts"
    runHook postInstall
  '';
}
