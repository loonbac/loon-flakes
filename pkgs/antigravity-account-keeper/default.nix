{ lib
, stdenvNoCC
, nodejs
, makeWrapper
}:

stdenvNoCC.mkDerivation {
  pname = "antigravity-account-keeper";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [
    nodejs
    makeWrapper
  ];

  doCheck = true;

  # Nothing to compile: the package only wraps the Node.js entry point.
  dontBuild = true;

  checkPhase = ''
    runHook preCheck
    node --test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 keeper.mjs "$out/libexec/antigravity-account-keeper/keeper.mjs"
    makeWrapper ${nodejs}/bin/node "$out/bin/antigravity-account-keeper" \
      --add-flags "$out/libexec/antigravity-account-keeper/keeper.mjs"
    runHook postInstall
  '';

  meta = {
    description = "Automatic background renewal of Google Antigravity OAuth accounts for Pi";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "antigravity-account-keeper";
  };
}
