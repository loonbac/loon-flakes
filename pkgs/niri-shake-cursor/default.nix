# niri-shake-cursor: agranda el cursor temporalmente al "sacudir" el mouse
# (estilo macOS "shake to find cursor") para niri.
#
# Parcheado para este setup:
#   - Escribe el tamaño en ~/.config/niri/cursor-size.kdl (override que el
#     config principal de niri incluye), en vez de editar el config gestionado.
#   - normalSize=32 (coincide con el config), largeSize=64.
# Necesita que el usuario esté en el grupo "input" para leer /dev/input/.
{ lib, buildGoModule }:

buildGoModule {
  pname = "niri-shake-cursor";
  version = "0.1.0";

  src = ./.;

  # Sin dependencias externas: solo stdlib de Go.
  vendorHash = null;

  meta = {
    description = "macOS-style shake to find cursor para niri";
    license = lib.licenses.mit;
    mainProgram = "niri-shake-cursor";
  };
}
