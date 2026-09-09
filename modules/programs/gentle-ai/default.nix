{ pkgs, ... }:

let
  gga = pkgs.callPackage ../../../pkgs/gga { };
  piLauncher = pkgs.callPackage ../../../pkgs/pi-launcher { };
  gentleAiLauncher = pkgs.callPackage ../../../pkgs/gentle-ai-launcher { };
  engramUpdater = pkgs.callPackage ../../../pkgs/engram-updater { };
  engramLauncher = pkgs.callPackage ../../../pkgs/engram-launcher {
    inherit engramUpdater;
  };
  betterClaudeCodeUi = pkgs.callPackage ../../../pkgs/pi/better-claude-code-ui { };
  bootstrap = pkgs.callPackage ../../../pkgs/gentle-ai-bootstrap {
    inherit piLauncher gentleAiLauncher engramLauncher betterClaudeCodeUi;
  };
  stackUpdate = pkgs.callPackage ../../../pkgs/gentle-stack-update {
    inherit piLauncher gentleAiLauncher engramLauncher;
    gentleAiBootstrap = bootstrap;
  };
in
{
  # Nix owns stable launchers and declarative configuration. Pi, its
  # extensions, and gentle-pi's verified Gentle AI binary live in writable
  # user storage so their supported update commands can replace them.
  environment.systemPackages = [
    engramLauncher
    engramUpdater
    gga
    piLauncher
    gentleAiLauncher
    bootstrap
    stackUpdate
  ];

  # Bootstrap only installs missing mutable components. Routine upgrades stay
  # explicit through `pi update` or `gentle-stack-update`.
  systemd.user.services.gentle-ai-bootstrap = {
    description = "Initialize the user-managed Gentle AI and Pi stack";
    wantedBy = [ "default.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${bootstrap}/bin/gentle-ai-bootstrap";
      RemainAfterExit = true;
      Environment = [
        "HOME=/home/loonbac"
        "PI_CODING_AGENT_DIR=/home/loonbac/.pi/agent"
        "GENTLE_AI_NIXOS_REPO=/home/loonbac/.nixos"
      ];
    };
  };
}
