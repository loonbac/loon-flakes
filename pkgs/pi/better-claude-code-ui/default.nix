{ lib
, buildNpmPackage
}:

buildNpmPackage {
  pname = "better-claude-code-ui-loon";
  version = "0.1.7";

  src = ./.;
  npmDepsHash = "sha256-U6jzMGjSoaeC/G7H9WNyCEbeB9lyBQwpBjUfhRBToj4=";
  npmInstallFlags = [ "--ignore-scripts" "--legacy-peer-deps" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r extension theme node_modules package.json README.md LICENSE "$out/"

    runHook postInstall
  '';

  meta = {
    description = "Locally customized Better Claude Code UI for Pi";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
