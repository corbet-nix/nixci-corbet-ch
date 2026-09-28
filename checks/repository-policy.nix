# SPDX-License-Identifier: MIT OR Apache-2.0
{ pkgs, lib ? pkgs.lib }:
let
  fixture = {
    forges = {
      hub = { kind = "github"; url = "https://hub.example.org"; };
      mirror = { kind = "forgejo"; url = "https://forge.example.org"; };
      lab = { kind = "gitlab"; url = "https://lab.example.org"; };
      bucket = { kind = "bitbucket"; url = "https://bucket.example.org"; };
    };
    ci = {
      primary = { driver = "github-actions"; forge = "hub"; execution = "free-hosted"; capabilities = [ "linux-x86_64" ]; };
      backup = { driver = "crow"; forge = "mirror"; execution = "owned"; capabilities = [ "linux-x86_64" ]; };
    };
    repositories.widget = {
      ci = "primary";
      visibility = "public";
      sensitive = false;
      attributes.distribution = "public";
      locations = { hub = "team/widget"; mirror = "backup/widget"; lab = "group/subgroup/widget"; bucket = "workspace/widget"; };
      cloneFallbacks = [ "mirror" "lab" "bucket" ];
      executionFallbacks = [ "backup" ];
    };
    placementRules = [{ name = "public-source"; attributes.distribution = "public"; require = [ "hub" ]; }];
  };
  eval = values: (lib.evalModules {
    modules = [ ../modules/repositories.nix { nixci.delivery = values; } ];
  }).config.nixci.delivery;
  good = eval fixture;
  rejects = mutation: !(builtins.tryEval (builtins.deepSeq (eval (lib.recursiveUpdate fixture mutation)).json true)).success;
  mutations = [
    { ci.primary.execution = "paid"; }
    { ci.primary.forge = "mirror"; }
    { ci.primary.capabilities = [ ]; }
    { forges.hub.url = "https://token@hub.example.org"; }
    { repositories.widget.visibility = "private"; }
    { repositories.widget.sensitive = true; }
    { repositories.widget.locations.hub = "team/../widget"; }
    { repositories.widget.cloneFallbacks = [ "hub" ]; }
    { repositories.widget.executionFallbacks = [ "absent" ]; }
    { repositories.widget.promotion = "automatic"; }
    { repositories.other = fixture.repositories.widget; }
    { placementRules = [{ name = "denied"; attributes.distribution = "public"; forbid = [ "mirror" ]; }]; }
  ];
  changed = eval (lib.recursiveUpdate fixture {
    repositories.widget = { ci = "backup"; cloneFallbacks = [ "hub" ]; executionFallbacks = [ ]; };
  });
in
assert (eval { }).policy.repositories == { };
assert (eval { }).admissionEnvironment == { };
assert (eval { admission = { memoryReserveMiB = 8192; ioFullAvg10 = 10; }; }).admissionEnvironment == {
  CI_MIN_AVAILABLE_MB = "8192"; CI_MAX_IO_PSI_AVG10 = "10";
};
assert !(builtins.tryEval (builtins.deepSeq (eval { admission.ioFullAvg10 = 0; }).admissionEnvironment true)).success;
assert good.primaryUrls.widget == "https://hub.example.org/team/widget";
assert changed.primaryUrls.widget == "https://forge.example.org/backup/widget";
assert (builtins.fromJSON good.json).repositories.widget.clone_fallbacks == [ "mirror" "lab" "bucket" ];
assert lib.all rejects mutations;
pkgs.writeText "ccid-repository-policy.json" good.json
