{ lib
, buildGoModule
, fetchFromGitHub
}:

buildGoModule rec {
  pname = "cli-proxy-api";
  version = "8.0.4";

  src = fetchFromGitHub {
    owner = "router-for-me";
    repo = "CLIProxyAPI";
    rev = "v${version}";
    hash = "sha256-CQ4kjO8XaGdVGFkO9MvbPMO9PrO3sTKCN706mbzOj9g=";
  };

  vendorHash = "sha256-r3yWkdMcM40G9jV7MxW/qNv3E9WrHavFilW24quEf+8=";

  subPackages = [ "cmd/server" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=${version}"
    "-X main.Commit=v${version}"
    "-X main.DefaultConfigPath=/etc/cli-proxy-api/config.yaml"
  ];

  postInstall = ''
    mv $out/bin/server $out/bin/cli-proxy-api
    ln -s $out/bin/cli-proxy-api $out/bin/cliproxyapi
  '';

  meta = {
    description = "Proxy para Antigravity, ChatGPT Codex, Claude Code, Grok, etc. compatible con APIs de OpenAI/Gemini/Claude";
    homepage = "https://github.com/router-for-me/CLIProxyAPI";
    license = lib.licenses.mit;
    mainProgram = "cli-proxy-api";
    platforms = lib.platforms.linux;
  };
}
