# Paquete local de Pi, empaquetado para que Nix sea dueño de los bytes. El
# home solo guarda un symlink estable, así que la identidad del paquete en
# settings.json no lleva hash de store y no se duplica al activar.
{ stdenv }:

stdenv.mkDerivation {
  pname = "pi-jev-context-guard";
  version = "0.1.0";
  src = ./.;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r package.json src "$out"/
    runHook postInstall
  '';

  meta.description = "pi extension: Jev judges context to decide when to compact, suggest a fresh session, or save a memory";
}
