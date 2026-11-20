-- Mantiene el micrófono físico MAONO al 100 % sin sondeos ni procesos extra.
-- WirePlumber ya está corriendo: este hook solo reacciona a los eventos del
-- nodo, así que no añade coste mientras se juega.

local cutils = require("common-utils")
local log = Log.open_topic("s-custom-maono-mic-volume")
log:info("MAONO microphone volume hook loaded")

local prefijo = "alsa_input.usb-MAONO_AU-AM200"

local function esMicrofono(node)
  local nombre = node.properties["node.name"] or ""
  return nombre:find(prefijo, 1, true) ~= nil
end

local function canalesAlMaximo(canales)
  if type(canales) ~= "table" or #canales == 0 then
    return false
  end
  for _, valor in ipairs(canales) do
    if math.abs(valor - 1.0) > 0.0001 then
      return false
    end
  end
  return true
end

local function fijarVolumen(node)
  if not esMicrofono(node) then
    return
  end

  local props = nil
  for p in node:iterate_params("Props") do
    props = cutils.parseParam(p, "Props")
    if props then
      break
    end
  end

  local valores = {}
  for _, valor in ipairs((props and props.channelVolumes) or {}) do
    valores[#valores + 1] = tostring(valor)
  end
  log:debug(node, "Props volume=" .. tostring(props and props.volume)
    .. " channels=" .. table.concat(valores, ","))

  if props
    and props.volume ~= nil
    and math.abs(props.volume - 1.0) < 0.0001
    and canalesAlMaximo(props.channelVolumes)
  then
    return
  end

  local param = {
    "Spa:Pod:Object:Param:Props", "Props",
    volume = 1.0,
  }

  if props then
    if props.mute ~= nil then
      param.mute = props.mute
    end
    if props.channelVolumes ~= nil and #props.channelVolumes > 0 then
      local canales = { "Spa:Float" }
      for _ = 1, #props.channelVolumes do
        canales[#canales + 1] = 1.0
      end
      param.channelVolumes = Pod.Array(canales)
    end
    if props.channelMap ~= nil and #props.channelMap > 0 then
      local mapa = { "Spa:Enum:AudioChannel" }
      for _, canal in ipairs(props.channelMap) do
        mapa[#mapa + 1] = canal
      end
      param.channelMap = Pod.Array(mapa)
    end
  end

  node:set_param("Props", Pod.Object(param))
  log:info(node, "MAONO microphone volume set to 100%")
end

SimpleEventHook {
  name = "custom/maono-mic-volume",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "node.name", "matches", "alsa_input.usb-MAONO_AU-AM200*", type = "pw" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-params-changed" },
      Constraint { "event.subject.param-id", "=", "Props" },
      Constraint { "node.name", "matches", "alsa_input.usb-MAONO_AU-AM200*", type = "pw" },
    },
  },
  execute = function(event)
    fijarVolumen(event:get_subject())
  end,
}:register()
