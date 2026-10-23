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
    # `pi` is resolved at runtime on purpose: the launcher in nixpkgs owns it,
    # and this tool must read whichever catalogue that launcher exposes.
    makeWrapper ${nodejs}/bin/node "$out/bin/pi-compaction-threshold" \
      --add-flags "$out/libexec/pi-compaction-threshold/sync.mjs"
    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
  };

  meta = {
    description = "Pin Pi's compaction threshold across every model of a context size";
    longDescription = ''
      Pi compacts when the context exceeds `contextWindow - reserveTokens`, and it
      accepts that reserve only as an exact `provider/model` entry. With the
      built-in reserve a million-token model carries almost the whole window
      before compacting, which re-sends a large prefix at the cache-miss price.

      This tool reads the live model catalogue and derives one override per model
      so the threshold stays constant as models come and go. It only adds or
      updates entries, never removing one.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "pi-compaction-threshold";
  };
})
