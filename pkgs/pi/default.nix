{ lib
, buildNpmPackage
, makeWrapper
, nodejs
, gentleAi
}:

buildNpmPackage rec {
  pname = "loon-gentle-pi-stack";
  version = "0.84.4";

  src = ./.;
  npmDepsHash = "sha256-RC4GROfVWYTY4KqkzUgJmDXpaylvM9TS/dWmnQggKXE=";
  npmDepsFetcherVersion = 2;
  npmInstallFlags = [ "--ignore-scripts" ];
  npmRebuildFlags = [ "--ignore-scripts" ];

  dontNpmBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/pi"
    cp -r node_modules package.json package-lock.json "$out/lib/pi/"

    # The pinned gentle-pi main snapshot carries parity with gentle-ai 2.6.0,
    # but its abandon serializer still emits the retired
    # evidence_records_present line.
    # The stable gentle-ai v2 binding is eight lines, so keep the pinned package
    # and remove only that stale serializer line from its TS/runtime pair until
    # the upstream npm package publishes the matching fix.
    for native_review_file in \
      "$out/lib/pi/node_modules/gentle-pi/lib/native-review-cli.ts" \
      "$out/lib/pi/node_modules/gentle-pi/runtime/native-review-cli.mjs"; do
      sed -i '/evidence_records_present=/d' "$native_review_file"
    done

    makeWrapper "${nodejs}/bin/node" "$out/bin/pi" \
      --add-flags "$out/lib/pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js" \
      --set GENTLE_PI_GENTLE_AI_DEV_BINARY "${gentleAi}/bin/gentle-ai"
    makeWrapper "${nodejs}/bin/node" "$out/bin/pi-engram" \
      --add-flags "$out/lib/pi/node_modules/gentle-engram/cli.js"

    runHook postInstall
  '';

  meta = {
    description = "Pinned Pi and Gentle-Pi stack with native Gentle Agents";
    homepage = "https://github.com/earendil-works/pi";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.linux;
  };
}
