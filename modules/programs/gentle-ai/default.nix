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
  # Wrapper over the mutable npm-global prefix that holds `gentle-pi`
  # (Path A: `npm i -g gentle-pi`). The bootstrap reconciles the prefix; the
  # launcher only adds upgrade/rollback and the main-channel build tools.
  gentleShellPackage = pkgs.callPackage ../../../pkgs/gentle-shell { };
  codegraphLauncher = pkgs.callPackage ../../../pkgs/codegraph-launcher { };
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
  # Pi compacts at `contextWindow - reserveTokens` and accepts the override only
  # as an exact `provider/model` key, so the threshold has to be derived from
  # the live catalogue instead of written by hand.
  piCompactionThreshold = pkgs.callPackage ../../../pkgs/pi-compaction-threshold { };
  gptFastModeShared = pkgs.callPackage ../../../pkgs/pi/gpt-fast-mode-shared { };
  piJevContextGuard = pkgs.callPackage ../../../pkgs/pi-jev-context-guard { };
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
    inherit gptFastModeShared piJevContextGuard;
    loonHome = config.loon.home;
    personalPiProviders = config.loon.personal.piProviders;
    personalJudges = config.loon.personal.judges;
    personalMcpServers = config.loon.personal.mcpServers;
    gentleShellEnable = cfg.gentleShell.enable;
    gentleShellChannel = cfg.gentleShell.channel;
    gentleShellVersion = cfg.gentleShell.version;
    inherit piCompactionThreshold;
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
          description = ''
            Exact release tag when mode is release, or branch/tag/commit when
            mode is git. Null means the latest stable release in release mode
            and main in git mode; set a ref only for an explicitly requested
            test or temporary pin.
          '';
        };
      };
    };

    # The Arch-like install of Gentle AI: the `gentle-pi` npm global that
    # provides the `gentle-shell` command, reconciled from Nix instead of
    # tracked by the Nix store. `channel`/`version` are the single source of
    # truth: the bootstrap converges the prefix on every activation, so a
    # channel changed by hand with `gentle-shell upgrade --channel` reverts at
    # the next rebuild unless it is also declared here.
    gentleShell = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install `gentle-pi` as a mutable npm-global prefix under
          ~/.local/share/loon-gentle-shell and expose the `gentle-shell`
          launcher. Disable to keep only the store-managed Gentle layer.
        '';
      };

      channel = lib.mkOption {
        type = lib.types.enum [ "release" "main" ];
        default = "release";
        description = ''
          Update channel of the managed prefix. `release` installs published
          `gentle-pi` versions; `main` builds Gentle Shell and Gentle AI from
          the latest upstream main commits (needs network, pnpm and Go, both
          provided by the wrapper).
        '';
      };

      version = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "4.7.0";
        description = ''
          Exact `gentle-pi` version to keep installed in release channel. Null
          follows the latest published version and never downgrades a version
          the user already upgraded by hand. Ignored in the main channel.
        '';
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
        message = "programs.gentle-ai.core.engram.ref must be a version tag such as v2.0.0 in release mode.";
      }
      {
        assertion = cfg.gentleShell.version == null || cfg.gentleShell.version != "";
        message = "programs.gentle-ai.gentleShell.version must be null or non-empty.";
      }
      {
        assertion =
          cfg.gentleShell.version == null
          || builtins.match "^[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?$" cfg.gentleShell.version != null;
        message = "programs.gentle-ai.gentleShell.version must be an npm version such as 4.7.0.";
      }
    ];

    # Only these launchers and core reconcilers belong to the Gentle layer.
    # The custom Pi UI, notifications, providers and fallbacks remain separate
    # inputs to the local bootstrap and are not modeled as Gentle components.
    environment.systemPackages = [
      codegraphLauncher
      engramLauncher
      engramUpdater
      gentleAiLauncher
      gentleAiRuntimeUpdater
      gga
      piLauncher
      piCompactionThreshold
      bootstrap
      stackUpdate
    ]
    ++ lib.optional cfg.gentleShell.enable gentleShellPackage;

    # A system service running as the primary user is intentional: NixOS
    # switch tracks and restarts changed system units, while already-active
    # user oneshots are only reloaded. This makes an edited source declaration
    # take effect during the same rebuild without requiring a login or a
    # manual user-unit restart. Who that user is comes from
    # `loon.username`/`loon.home`, so a fork installs its own identity
    # instead of loonbac's.
    systemd.services.gentle-ai-bootstrap = {
      description = "Reconcile the declared Gentle AI core for Pi";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = config.loon.username;
        Group = "users";
        ExecStart = "${bootstrap}/bin/gentle-ai-bootstrap";
        RemainAfterExit = true;
        WorkingDirectory = config.loon.home;
        Environment = [
          "HOME=${config.loon.home}"
          "PI_CODING_AGENT_DIR=${config.loon.home}/.pi/agent"
          "GENTLE_AI_NIXOS_REPO=${config.loon.home}/.nixos"
        ];
      };
    };
  };
}
