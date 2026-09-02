{ pkgs, ... }:

let
  gentleAi = pkgs.callPackage ../../../pkgs/gentle-ai { };
  engram = pkgs.callPackage ../../../pkgs/engram { };
  piStack = pkgs.callPackage ../../../pkgs/pi { inherit gentleAi; };
  bootstrap = pkgs.callPackage ../../../pkgs/gentle-ai-bootstrap {
    inherit gentleAi engram piStack;
  };
in
{
  # Nix owns the executable and the complete Pi dependency closure. The
  # bootstrap below only initializes mutable per-user configuration.
  environment.systemPackages = [ gentleAi engram piStack bootstrap ];

  # Reconcile ~/.pi and ~/.gentle-ai at login without npm, network access, or
  # overwriting user credentials, models, sessions, or Engram's database.
  systemd.user.services.gentle-ai-bootstrap = {
    description = "Initialize the reproducible Gentle-AI, Pi and Engram stack";
    wantedBy = [ "default.target" ];
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
