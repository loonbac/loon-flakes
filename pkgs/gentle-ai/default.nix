{ lib
, buildGoModule
, fetchFromGitHub
, git
}:

buildGoModule rec {
  pname = "gentle-ai";
  version = "2.6.0";

  src = fetchFromGitHub {
    owner = "Gentleman-Programming";
    repo = "gentle-ai";
    tag = "v${version}";
    hash = "sha256-ETCwQerMww7ufxI9at2aB7FH0Hm3XclfCWH1ZRjv1sI=";
  };

  subPackages = [ "cmd/gentle-ai" ];
  vendorHash = "sha256-todsAjNOtV/fX4agsaqFwC0MHerMCVB0ufJk1sGSm/Y=";
  nativeBuildInputs = [ git ];
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = {
    description = "Ecosystem, frameworks, and workflows for AI coding agents";
    homepage = "https://github.com/Gentleman-Programming/gentle-ai";
    license = lib.licenses.mit;
    mainProgram = "gentle-ai";
    platforms = lib.platforms.linux;
  };
}
