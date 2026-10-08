{ lib, python3 }:

# El generador del panel de nueva pestaña, empaquetado con su plantilla al lado.
#
# La plantilla tiene que quedar junto al script porque el generador la lee con una
# ruta relativa a su propio archivo. Empaquetarlos juntos evita depender del
# directorio de trabajo de quien lo invoque, que en un servicio systemd no existe.
let
  runtime = python3.withPackages (_: [ ]);
in
python3.pkgs.buildPythonApplication {
  pname = "newtab-dashboard";
  version = "1.0.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/newtab-dashboard $out/bin
    cp generate.py newtab.template.html $out/share/newtab-dashboard/
    cat > $out/bin/newtab-dashboard <<EOF
    #!${runtime}/bin/python3
    import runpy, sys
    sys.argv = ["newtab-dashboard"] + sys.argv[1:]
    runpy.run_path("$out/share/newtab-dashboard/generate.py", run_name="__main__")
    EOF
    chmod +x $out/bin/newtab-dashboard
    runHook postInstall
  '';

  meta = {
    description = "Panel de nueva pestaña con el estado del router adaptativo";
    license = lib.licenses.mit;
    mainProgram = "newtab-dashboard";
  };
}
