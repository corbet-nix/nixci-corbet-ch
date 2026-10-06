# SPDX-License-Identifier: MIT OR Apache-2.0
# Periodic policy reconciliation; credentials and placement stay with the consumer.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.nixci.reconciliation;
  absolute = types.strMatching "/.*";
  name = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*";
  state = "/var/lib/${cfg.stateDirectory}";
  credentialSettings = pkgs.writeText "ccid-reconciliation-credentials.json" (builtins.toJSON cfg.credentials);
  askpass = pkgs.writeShellScript "ccid-reconciliation-askpass" ''
    exec ${pkgs.python3}/bin/python3 ${../scripts/askpass.py} ${credentialSettings} "$@"
  '';
  settings = pkgs.writeText "ccid-forge-reconcile.json" (builtins.toJSON {
    binary = cfg.binary;
    binary_sha256 = cfg.binarySha256;
    tool_revision = cfg.toolRevision;
    state_directory = state;
    repositories = lib.mapAttrs (repository: entry: {
      inherit repository;
      policy_file = entry.policyFile;
      inherit (entry) destinations;
      interval_seconds = entry.intervalSeconds;
      timeout_seconds = entry.timeoutSeconds;
      pause_seconds = entry.pauseSeconds;
    }) cfg.repositories;
  });
  timeout = 30 + lib.foldl' (total: entry: total + entry.timeoutSeconds + entry.pauseSeconds + 30) 0 (lib.attrValues cfg.repositories);
in {
  options.nixci.reconciliation = {
    enable = mkEnableOption "bounded periodic ccid forge reconciliation";
    binary = mkOption { type = absolute; description = "Explicit pinned ccid executable or identity-verifying wrapper. Never downloaded by this module."; };
    binarySha256 = mkOption { type = types.strMatching "[0-9a-f]{64}"; description = "Required executable digest; verified sealed bytes are executed without reopening the cache path."; };
    toolRevision = mkOption { type = types.strMatching "[0-9a-f]{40}|[0-9a-f]{64}"; description = "Expected ccid source-revision, verified before Git requests."; };
    user = mkOption { type = name; description = "Existing account that owns reports and reads externally supplied credentials."; };
    stateDirectory = mkOption { type = name; default = "ccid-forge-reconcile"; description = "systemd StateDirectory name below /var/lib; owned by the configured user."; };
    environmentFile = mkOption { type = types.nullOr absolute; default = null; description = "Optional runtime environment file, not read or copied into the Nix store."; };
    gitAskpass = mkOption { type = types.nullOr absolute; default = null; description = "Optional existing Git askpass executable; this module supplies no credentials."; };
    credentials = mkOption {
      default = { };
      type = types.attrsOf (types.submodule {
        options = {
          username = mkOption { type = types.str; description = "Username for the exact HTTPS origin."; };
          passwordCommand = mkOption { type = types.listOf types.str; description = "External argv returning one password. Supply secret file paths, never plaintext secrets, in this declaration."; };
        };
      });
      description = "Optional askpass rules keyed by exact canonical HTTPS origin; incompatible with gitAskpass.";
    };
    tickSeconds = mkOption { type = types.ints.positive; default = 60; description = "Delay between completed scheduler passes; repository intervals still apply."; };
    memoryMax = mkOption { type = types.str; default = "1G"; description = "Memory bound shared by the scheduler and all Git processes."; };
    scratchSize = mkOption { type = types.strMatching "[1-9][0-9]*[KMGT]?"; default = "1G"; description = "Private tmpfs limit for disposable Git objects and credential output."; };
    repositories = mkOption {
      default = { };
      type = types.attrsOf (types.submodule {
        options = {
          policyFile = mkOption { type = absolute; description = "Explicit ccid policy JSON path; its primary is the only source."; };
          destinations = mkOption { type = types.listOf name; description = "Explicit allowed secondary forge identifiers."; };
          intervalSeconds = mkOption { type = types.ints.positive; description = "Minimum interval between attempts for this repository, including failures."; };
          timeoutSeconds = mkOption { type = types.ints.positive; description = "ccid's total reconciliation deadline."; };
          pauseSeconds = mkOption { type = types.ints.unsigned; description = "Pacing delay after this repository's attempt, including failures."; };
        };
      });
      description = "Allowlisted logical repository IDs. No discovery or implicit onboarding.";
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.repositories != { }; message = "nixci.reconciliation requires an explicit repository allowlist"; }
      { assertion = cfg.credentials == { } || cfg.gitAskpass == null; message = "nixci.reconciliation accepts credentials or gitAskpass, never both"; }
      { assertion = lib.all (origin: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]+)?" origin != null) (lib.attrNames cfg.credentials); message = "nixci.reconciliation credentials require canonical HTTPS origins without paths or userinfo"; }
      { assertion = lib.all (entry: entry.username != "" && !(lib.hasInfix "\n" entry.username) && !(lib.hasInfix "\r" entry.username) && entry.passwordCommand != [ ] && lib.all (arg: arg != "") entry.passwordCommand) (lib.attrValues cfg.credentials); message = "nixci.reconciliation credential commands and usernames must be explicit and nonempty"; }
      { assertion = builtins.hasAttr cfg.user config.users.users; message = "nixci.reconciliation.user must already exist"; }
      { assertion = lib.all (id: builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*" id != null) (lib.attrNames cfg.repositories); message = "nixci.reconciliation repository IDs must be plain names"; }
      { assertion = lib.all (entry: entry.destinations != [ ] && lib.unique entry.destinations == entry.destinations) (lib.attrValues cfg.repositories); message = "nixci.reconciliation destinations must be explicit, nonempty and unique"; }
    ];
    systemd.services.ccid-forge-reconcile = {
      description = "Reconcile explicitly allowed Git replicas without force or pruning";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ pkgs.git pkgs.openssh ];
      environment = { GIT_TERMINAL_PROMPT = "0"; }
        // lib.optionalAttrs (cfg.gitAskpass != null) { GIT_ASKPASS = cfg.gitAskpass; }
        // lib.optionalAttrs (cfg.credentials != { }) { GIT_ASKPASS = toString askpass; };
      serviceConfig = {
        Type = "oneshot";
        # A recorded pending replica must not make unrelated host activation
        # fail. Binary/state verification and invalid output still exit 1.
        SuccessExitStatus = [ 75 ];
        User = cfg.user;
        StateDirectory = cfg.stateDirectory;
        StateDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = "${pkgs.python3}/bin/python3 ${../scripts/reconcile.py} ${settings}";
        TimeoutStartSec = timeout;
        TimeoutStopSec = 15;
        KillMode = "control-group";
        # Mount scratch separately: timeouts alone cannot bound hostile packfiles.
        TemporaryFileSystem = [ "/tmp:rw,nosuid,nodev,size=${cfg.scratchSize},mode=1777" ];
        MemoryMax = cfg.memoryMax;
        MemorySwapMax = 0;
        TasksMax = 64;
        LimitFSIZE = cfg.scratchSize;
        LimitCORE = 0;
        CoredumpFilter = "0x0";
        ProtectProc = "invisible";
        RestrictSUIDSGID = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ state ];
        Nice = 10;
      } // lib.optionalAttrs (cfg.environmentFile != null) { EnvironmentFile = cfg.environmentFile; };
    };
    systemd.timers.ccid-forge-reconcile = {
      description = "Schedule bounded forge reconciliation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.tickSeconds;
        OnUnitInactiveSec = cfg.tickSeconds;
        Unit = "ccid-forge-reconcile.service";
      };
    };
  };
}
