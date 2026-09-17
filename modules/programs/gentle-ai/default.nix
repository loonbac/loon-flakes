{ config, lib, pkgs, ... }:

let
  cfg = config.programs.gentle-ai;
  core = cfg.core;
  useGentleAiDevRuntime = core.gentleAi.source != null;
  gentlePiSource =
    if core.gentlePi.mode == "release" then
      "npm:gentle-pi" + lib.optionalString (core.gentlePi.ref != null) "@${core.gentlePi.ref}"
    else
      "git:github.com/Gentleman-Programming/gentle-pi"
      + lib.optionalString (core.gentlePi.ref != null) "@${core.gentlePi.ref}";
  gentlePiPackageSubpath =
    if core.gentlePi.mode == "release" then
      "npm/node_modules/gentle-pi"
    else
      "git/github.com/Gentleman-Programming/gentle-pi";

  gga = pkgs.callPackage ../../../pkgs/gga { };
  gentleAiRuntimeUpdater = pkgs.callPackage ../../../pkgs/gentle-ai-runtime-updater {
    source = core.gentleAi.source;
  };
  piLauncher = pkgs.callPackage ../../../pkgs/pi-launcher {
    inherit useGentleAiDevRuntime;
  };
  gentleAiLauncher = pkgs.callPackage ../../../pkgs/gentle-ai-launcher {
    inherit gentlePiPackageSubpath useGentleAiDevRuntime;
  };
  engramUpdater = pkgs.callPackage ../../../pkgs/engram-updater {
    sourceMode = core.engram.mode;
    sourceRef = core.engram.ref;
  };
  engramLauncher = pkgs.callPackage ../../../pkgs/engram-launcher {
    inherit engramUpdater;
  };
  betterClaudeCodeUi = pkgs.callPackage ../../../pkgs/pi/better-claude-code-ui { };
  gptFastModeShared = pkgs.callPackage ../../../pkgs/pi/gpt-fast-mode-shared { };
  bootstrap = pkgs.callPackage ../../../pkgs/gentle-ai-bootstrap {
    inherit
      engramLauncher
      gentleAiLauncher
      gentleAiRuntimeUpdater
      gentlePiPackageSubpath
      gentlePiSource
      piLauncher
      useGentleAiDevRuntime
      ;
    gentleAiRuntimeSource = core.gentleAi.source;
    engramSourceMode = core.engram.mode;
    engramSourceRef = core.engram.ref;
    inherit betterClaudeCodeUi gptFastModeShared;
  };
  stackUpdate = pkgs.callPackage ../../../pkgs/gentle-stack-update {
    inherit
      engramLauncher
      gentleAiLauncher
      gentleAiRuntimeUpdater
      gentlePiPackageSubpath
      piLauncher
      ;
    gentleAiBootstrap = bootstrap;
  };
in
{
  options.programs.gentle-ai = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the Pi-focused Gentle AI stack.";
    };

    core = {
      gentlePi = {
        mode = lib.mkOption {
          type = lib.types.enum [ "release" "git" ];
          default = "release";
          description = "Select gentle-pi from npm or its upstream Git repository.";
        };

        ref = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "main";
          description = ''
            npm version/tag in release mode, or branch/tag/commit in git mode.
            Null means npm latest in release mode and the default moving branch
            in git mode.
          '';
        };
      };

      gentleAi.source = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "github.com/gentleman-programming/gentle-ai/v2/cmd/gentle-ai@main";
        description = ''
          Optional Go install target for a Gentle AI branch, tag, or commit.
          Null uses gentle-pi's checksum-verified companion runtime. A value
          uses gentle-pi's official development-binary environment override
          without writing a local dev-binary.json file.
        '';
      };

      engram = {
        mode = lib.mkOption {
          type = lib.types.enum [ "release" "git" ];
          default = "release";
          description = ''
            Select a checksummed GitHub release or build Engram from a Git ref.
            This selects only the Engram binary; Pi manages the unversioned
            npm:gentle-engram plugin through its own extension channel.
          '';
        };

        ref = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "v2.0.0-rc.11";
          description = ''
            Exact release tag when mode is release, or branch/tag/commit when
            mode is git. Null means the latest stable release in release mode
            and main in git mode.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = core.gentlePi.ref == null || core.gentlePi.ref != "";
        message = "programs.gentle-ai.core.gentlePi.ref must be null or non-empty.";
      }
      {
        assertion =
          core.gentlePi.ref == null
          || builtins.match "^[0-9A-Za-z._/+~-]+$" core.gentlePi.ref != null;
        message = "programs.gentle-ai.core.gentlePi.ref contains unsupported characters.";
      }
      {
        assertion = core.gentleAi.source == null || core.gentleAi.source != "";
        message = "programs.gentle-ai.core.gentleAi.source must be null or a non-empty Go install target.";
      }
      {
        assertion = core.engram.ref == null || core.engram.ref != "";
        message = "programs.gentle-ai.core.engram.ref must be null or non-empty.";
      }
      {
        assertion =
          core.engram.mode != "release"
          || core.engram.ref == null
          || builtins.match "^v[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?$" core.engram.ref != null;
        message = "programs.gentle-ai.core.engram.ref must be a version tag such as v2.0.0-rc.11 in release mode.";
      }
    ];

    # Only these launchers and core reconcilers belong to the Gentle layer.
    # The custom Pi UI, notifications, providers and fallbacks remain separate
    # inputs to the local bootstrap and are not modeled as Gentle components.
    environment.systemPackages = [
      engramLauncher
      engramUpdater
      gentleAiLauncher
      gentleAiRuntimeUpdater
      gga
      piLauncher
      bootstrap
      stackUpdate
    ];

    # A system service running as loonbac is intentional: NixOS switch tracks
    # and restarts changed system units, while already-active user oneshots are
    # only reloaded. This makes an edited source declaration take effect during
    # the same rebuild without requiring a login or a manual user-unit restart.
    systemd.services.gentle-ai-bootstrap = {
      description = "Reconcile the declared Gentle AI core for Pi";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "loonbac";
        Group = "users";
        ExecStart = "${bootstrap}/bin/gentle-ai-bootstrap";
        RemainAfterExit = true;
        WorkingDirectory = "/home/loonbac";
        Environment = [
          "HOME=/home/loonbac"
          "PI_CODING_AGENT_DIR=/home/loonbac/.pi/agent"
          "GENTLE_AI_NIXOS_REPO=/home/loonbac/.nixos"
        ];
      };
    };
  };
}
