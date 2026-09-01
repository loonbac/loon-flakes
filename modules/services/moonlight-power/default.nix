# This module has no wantedBy target.  Moonlight power mode is opt-in per
# session and must never be turned on by login, logout, or reboot.
{ pkgs, ... }:

let
  moonlightPower = pkgs.callPackage ../../../pkgs/moonlight-power { };
  laptopPowerProfile = pkgs.callPackage ../../../pkgs/laptop-power-profile { };
  systemctl = "${pkgs.systemd}/bin/systemctl";
in
{
  environment.systemPackages = [ moonlightPower laptopPowerProfile ];

  systemd.services.laptop-power-profile = {
    description = "Select performance profile from AC power state";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${laptopPowerProfile}/bin/laptop-power-profile apply";
    };
  };

  # The kernel emits ac_adapter events whenever the charger is connected or
  # removed, so the profile changes immediately without polling.
  services.acpid = {
    enable = true;
    # Keep charger transitions in the journal; this Dell is currently showing
    # intermittent AC online/offline events and the history helps diagnose it.
    logEvents = true;
    acEventCommands = "${systemctl} --no-block restart laptop-power-profile.service";
  };

  systemd.services.moonlight-power-root = {
    description = "Moonlight low-power hardware controls";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "moonlight-power";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      # Test redirection in the package cannot be enabled through this unit.
      Environment = "MOONLIGHT_POWER_TESTING=0";
      ExecStart = "${moonlightPower}/bin/moonlight-power-root apply";
      ExecStop = "${moonlightPower}/bin/moonlight-power-root restore";
      ExecStopPost = "${systemctl} restart laptop-power-profile.service";
    };
  };

  systemd.user.services.moonlight-power-user = {
    description = "Moonlight low-power session controls";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # ExecStop relaunches only the processes present in the snapshot. Keep
      # those detached processes alive after the oneshot helper exits.
      KillMode = "process";
      UMask = "0077";
      ExecStart = "${moonlightPower}/bin/moonlight-power user-on";
      ExecStop = "${moonlightPower}/bin/moonlight-power user-off";
    };
  };

  # This is intentionally the full command line, rather than an allowance for
  # systemctl in general.  No arbitrary root helper, shell, path, or unit can
  # be selected by the user.
  security.sudo.extraRules = [
    {
      users = [ "loonbac" ];
      commands = [
        {
          command = "${systemctl} start moonlight-power-root.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${systemctl} stop moonlight-power-root.service";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
