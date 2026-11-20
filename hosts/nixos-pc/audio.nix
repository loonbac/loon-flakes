# Audio específico de este host: el micrófono USB MAONO debe nacer y quedarse
# al 100 %. No hay sondeo ni servicio extra: un hook de WirePlumber corre dentro
# del proceso que ya gestiona PipeWire y solo actúa cuando cambia el nodo.
{ ... }:

{
  services.pipewire.wireplumber.extraScripts."53-maono-mic-volume.lua" =
    builtins.readFile ./maono-mic-volume.lua;

  services.pipewire.wireplumber.extraConfig."53-maono-mic-volume" = {
    "wireplumber.components" = [
      {
        name = "53-maono-mic-volume.lua";
        type = "script/lua";
        provides = "hooks.custom.maono-mic-volume";
      }
    ];

    "wireplumber.profiles" = {
      main = {
        "hooks.custom.maono-mic-volume" = "required";
      };
    };

    "monitor.alsa.rules" = [
      {
        matches = [
          {
            "device.name" = "~alsa_card.usb%-MAONO_AU%-AM200.*";
          }
        ];
        actions.update-props = {
          "device.routes.default-source-volume" = 1.0;
        };
      }
    ];
  };
}
