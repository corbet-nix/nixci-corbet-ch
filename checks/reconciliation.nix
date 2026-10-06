# SPDX-License-Identifier: MIT OR Apache-2.0
{ pkgs, lib ? pkgs.lib }:
let
  evaluate = values: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/reconciliation.nix
      {
        system.stateVersion = "25.11";
        users.users.replicator = { isSystemUser = true; group = "replicator"; };
        users.groups.replicator = { };
        nixci.reconciliation = values;
      }
    ];
  }).config;
  values = {
    enable = true;
    binary = "/opt/ccid/pinned/ccid";
    user = "replicator";
    binarySha256 = lib.concatStrings (lib.replicate 64 "a");
    toolRevision = lib.concatStrings (lib.replicate 40 "a");
    repositories.widget = {
      policyFile = "/etc/forge-policy.json";
      destinations = [ "secondary" ];
      intervalSeconds = 900;
      timeoutSeconds = 120;
      pauseSeconds = 5;
    };
  };
  enabled = evaluate values;
  service = enabled.systemd.services.ccid-forge-reconcile;
  # NixOS assertion messages can refer to failure-only diagnostic attributes.
  # Keep successful assertions lazy instead of evaluating every message.
  valid = config: lib.all (entry: entry.assertion
    || !(lib.hasPrefix "nixci.reconciliation" entry.message)) config.assertions;
  refused = extra: !(valid (evaluate (values // extra)));
  results = [
    (!((evaluate { }).systemd.services ? ccid-forge-reconcile))
    (valid enabled)
    (service.serviceConfig.User == "replicator")
    (service.serviceConfig.KillMode == "control-group")
    (service.serviceConfig.TimeoutStartSec == 185)
    (service.serviceConfig.StateDirectoryMode == "0700")
    (enabled.systemd.timers.ccid-forge-reconcile.timerConfig.OnUnitInactiveSec == 60)
    (refused { repositories = { }; })
    (service.serviceConfig.LimitCORE == 0)
    (service.serviceConfig.MemoryMax == "1G")
    (service.serviceConfig.TasksMax == 64)
    (service.serviceConfig.TemporaryFileSystem == [ "/tmp:rw,nosuid,nodev,size=1G,mode=1777" ])
    (refused { user = "undeclared-user"; })
    (refused { credentials."https://forge.example/path" = { username = "robot"; passwordCommand = [ "/bin/credential" ]; }; })
    (refused { gitAskpass = "/bin/askpass"; credentials."https://forge.example" = { username = "robot"; passwordCommand = [ "/bin/credential" ]; }; })
  ];
in
assert lib.all (result: result) results;
pkgs.runCommand "nixci-reconciliation" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python3 ${./reconciliation_test.py} ${../.}
  touch "$out"
''
