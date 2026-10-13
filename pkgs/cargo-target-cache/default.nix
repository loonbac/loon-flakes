# Wrapper del comando `cargo` que mantiene el directorio de artefactos
# (`target/`) fuera del árbol de trabajo: cada workspace compila en
# `<cacheRoot>/<clave del workspace>`.
#
# Motivo: `target/` es salida descartable del compilador y puede pesar decenas
# de GB, llenando la partición donde vive el código. Los artefactos viven en el
# disco raíz, así que un repositorio en una partición chica solo guarda código.
#
# Lo instala el módulo modules/programs/rust, que además declara `cacheRoot` con
# tmpfiles. El detalle de comportamiento está documentado en
# cargo-target-cache.sh y verificado por tests/test-wrapper.sh.
{ writeShellApplication
, runCommand
, bash
, coreutils
, findutils
, gnugrep
, gnused
, cargo
, rustc
, cacheRoot ? "/var/cache/rust-target"
}:

let
  # `runtimeInputs` fija el toolchain de nixpkgs para el proceso y sus hijos:
  # el compilador siempre coincide con el cargo del wrapper, sin depender del
  # PATH de la sesión. `coreutils` aporta `tr`, `cut`, `cksum` y `mkdir`, que el
  # wrapper usa; sin él dependería de herramientas del PATH ambiente.
  cargoWrapper = writeShellApplication {
    name = "cargo";
    runtimeInputs = [ cargo coreutils rustc ];
    text = builtins.replaceStrings
      [ "@realCargo@" "@cacheRoot@" ]
      [ "${cargo}/bin/cargo" cacheRoot ]
      (builtins.readFile ./cargo-target-cache.sh);
  };

  focusedTests = runCommand "cargo-target-cache-focused-tests" {
    nativeBuildInputs = [ bash coreutils findutils gnugrep gnused ];
  } ''
    ${bash}/bin/bash ${./tests/test-wrapper.sh} ${cargoWrapper}/bin/cargo
    touch "$out"
  '';
in
cargoWrapper.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit cacheRoot;
    tests = (old.passthru.tests or { }) // {
      focused = focusedTests;
    };
  };
})
