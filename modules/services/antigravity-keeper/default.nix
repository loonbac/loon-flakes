{ config, lib, pkgs, ... }:

let
  cfg = config.services.antigravity-keeper;
  keeper = pkgs.callPackage ../../../pkgs/antigravity-account-keeper { };

  # The session unit keeps the active account on one that offers every required
  # model. No account is named: it only moves when the active one cannot serve them.
  # The renewal timer never receives this, so it can never change the active account.
  baseEnvironment = [
    "HOME=/home/loonbac"
    "PATH=/run/current-system/sw/bin"
  ];

  sessionEnvironment = baseEnvironment
    ++ lib.optional (cfg.requiredModels != [ ])
      "ANTIGRAVITY_REQUIRED_MODELS=${lib.concatStringsSep "," cfg.requiredModels}";
in
{
  options.services.antigravity-keeper = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable periodic background renewal for Antigravity OAuth accounts.";
    };

    requiredModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "claude-opus-5-5" "claude-sonnet-5-5" ];
      description = ''
        Antigravity model ids the active account must offer. A model id without
        effort suffix matches the suffixed ids ("claude-opus-5-5" matches
        "claude-opus-5-5-high"). When the active account lacks one of them, the
        session unit activates another account that covers them. No account is
        named anywhere, so a quota failover by the plugin is never pinned back.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ keeper ];

    # Periodic renewal only. It never touches activeAccountId, so a quota
    # failover is never overridden behind the user's back by the timer.
    systemd.user.services.antigravity-keeper = {
      description = "Periodic background renewal for Antigravity OAuth accounts";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${keeper}/bin/antigravity-account-keeper";
        Environment = baseEnvironment;
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
      };
    };

    systemd.user.timers.antigravity-keeper = {
      description = "Periodic timer for Antigravity OAuth account renewal";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnStartupSec = "2m";
        OnUnitActiveSec = "20m";
        Persistent = true;
        AccuracySec = "1m";
      };
    };

    # Runs once per user session: keeps the active account on one that offers every
    # required model, and reports the gap when no account does.
    systemd.user.services.antigravity-keeper-session = {
      description = "Keep a model-compatible Antigravity account active for this session";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${keeper}/bin/antigravity-account-keeper";
        Environment = sessionEnvironment;
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
      };
    };
  };
}
