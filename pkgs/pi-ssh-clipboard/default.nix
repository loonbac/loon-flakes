{ lib
, stdenvNoCC
, makeWrapper
, python3
, wl-clipboard
, curl
, xclip
}:

stdenvNoCC.mkDerivation {
  pname = "pi-ssh-clipboard";
  version = "1.0.0";

  src = ./.;
  nativeBuildInputs = [ makeWrapper python3 ];
  doCheck = true;

  postPatch = ''
    substituteInPlace server.py \
      --replace-fail '@wl_paste@' '${wl-clipboard}/bin/wl-paste'
    substituteInPlace xclip-bridge.sh \
      --replace-fail '@real_xclip@' '${xclip}/bin/xclip' \
      --replace-fail '@curl@' '${curl}/bin/curl'
  '';

  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python server_test.py
    ${python3}/bin/python -m py_compile server.py
    ${stdenvNoCC.shell} -n xclip-bridge.sh
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 server.py "$out/libexec/pi-ssh-clipboard/server.py"
    install -Dm755 xclip-bridge.sh "$out/bin/xclip"
    makeWrapper ${python3}/bin/python "$out/bin/pi-ssh-clipboard-server" \
      --add-flags "$out/libexec/pi-ssh-clipboard/server.py"
    runHook postInstall
  '';

  meta = {
    description = "Private Wayland image clipboard bridge for Pi over SSH";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
