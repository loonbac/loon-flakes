# Credencial de Mistral Vibe Code para Pi.
#
# Mistral factura por tipo de credencial, no por endpoint: una API key de Studio
# consume la asignación de API, y el token de usuario del sign-in del CLI oficial
# consume la de Vibe Code, contra el mismo https://api.mistral.ai/v1.
#
# `vibe-token` hace ese sign-in una vez (OIDC, código + PKCE, cliente público),
# guarda los tokens en ~/.config/mistral-vibe/credentials.json con modo 0600,
# refresca bajo un lock —el refresh token rota en cada uso— y entrega al
# instante el bearer y las cabeceras de tenant que Pi necesita por request.
{ lib
, stdenvNoCC
, nodejs
, makeWrapper
, testers
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mistral-vibe-auth";
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
    install -Dm644 mistral-vibe-auth.mjs "$out/libexec/mistral-vibe-auth/vibe-token.mjs"
    makeWrapper ${nodejs}/bin/node "$out/bin/vibe-token" \
      --add-flags "$out/libexec/mistral-vibe-auth/vibe-token.mjs"
    runHook postInstall
  '';

  passthru.tests.version = testers.testVersion {
    package = finalAttrs.finalPackage;
    command = "vibe-token --version";
  };

  meta = {
    description = "Credencial de la asignación Vibe Code de Mistral para Pi";
    longDescription = ''
      Hace el sign-in OIDC del CLI oficial de Mistral (código + PKCE, cliente
      público), guarda los tokens con modo 0600 y entrega el bearer y las
      cabeceras de tenant que necesita Pi para facturar contra la asignación de
      Vibe Code en lugar de la de API. El refresh se serializa con un lock
      porque el refresh token es de un solo uso y rota.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "vibe-token";
  };
})
