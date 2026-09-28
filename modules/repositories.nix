# SPDX-License-Identifier: MIT OR Apache-2.0
# Value-only integration for ccid's repository policy. No provider credentials,
# scheduler, repository creation or implicit mirror promotion.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.nixci.delivery;
  str = description: mkOption { type = types.str; inherit description; };
  strings = description: mkOption { type = types.listOf types.str; default = [ ]; inherit description; };
  attrs = description: mkOption { type = types.attrsOf types.str; default = { }; inherit description; };
  forgeType = types.submodule {
    options = {
      kind = str "Forge provider name: github, forgejo, gitlab, bitbucket, or another Git forge.";
      url = (str "Canonical HTTPS base, including any installation prefix; no trailing slash.") // { example = "https://git.example.org"; };
    };
  };
  ciType = types.submodule {
    options = {
      driver = str "CI adapter name, independent of the forge provider.";
      forge = str "Declared forge from which this CI receives its primary trigger.";
      execution = mkOption {
        type = types.enum [ "owned" "free-hosted" "paid" ];
        description = "Execution cost boundary; free-hosted is only eligible for public nonsensitive repositories.";
      };
      capabilities = strings "Explicit coverage capabilities such as linux-x86_64 or darwin-aarch64; must be nonempty.";
    };
  };
  repoType = types.submodule {
    options = {
      ci = str "Primary CI declaration. Its forge is derived as the primary and trigger forge.";
      visibility = mkOption { type = types.enum [ "public" "private" "internal" ]; description = "Repository visibility, using cqlt's vocabulary."; };
      sensitive = mkOption { type = types.bool; description = "Whether source or execution inputs preclude public hosted execution."; };
      attributes = attrs "Declared project attributes used by placement rules; these are claims, not collected cqlt evidence.";
      locations = attrs "Forge declaration to complete namespace/repository path, including nested groups.";
      cloneFallbacks = strings "Ordered declared secondary forges permitted for exact-commit read fallback.";
      executionFallbacks = strings "Ordered CI declarations; their inventories must be resolved before any dispatch.";
      promotion = mkOption { type = types.enum [ "manual" ]; default = "manual"; description = "Primary promotion requires a reviewed declaration change; execution failover never promotes a mirror."; };
    };
  };
  ruleType = types.submodule {
    options = {
      name = str "Placement constraint name used in diagnostics.";
      attributes = attrs "Nonempty attribute match; every key/value must match for this rule to apply.";
      require = strings "Forges on which matching repositories must be explicitly placed.";
      forbid = strings "Forges on which matching repositories may not be placed.";
    };
  };
  has = set: name: builtins.hasAttr name set;
  fail = message: throw "nixci.delivery: ${message}; fix the consumer's repository policy.";
  unique = values: builtins.length values == builtins.length (lib.unique values);
  plain = value: value != "." && value != ".." && builtins.match "[A-Za-z0-9_.-]+" value != null;
  validPath = path: let parts = lib.splitString "/" path; in builtins.length parts >= 2 && lib.all plain parts && !(lib.hasSuffix ".git" path);
  validBase = url: builtins.match "https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9_.-]+)*" url != null
    && lib.all (part: part != "." && part != "..") (lib.splitString "/" url);
  ciForge = ci: if has cfg.ci ci then cfg.ci.${ci}.forge else fail "undeclared CI ${ci}";
  location = repo: forge:
    if !(has cfg.forges forge && has repo.locations forge) then fail "missing repository location ${forge}"
    else "${cfg.forges.${forge}.url}/${repo.locations.${forge}}";
  errors =
    lib.concatLists (lib.mapAttrsToList (name: forge:
      lib.optional (!(plain name && plain forge.kind && validBase forge.url)) "invalid forge ${name}") cfg.forges)
    ++ lib.concatLists (lib.mapAttrsToList (name: ci:
      lib.optional (!(has cfg.forges ci.forge)) "CI ${name} refers to undeclared forge ${ci.forge}"
      ++ lib.optional (cfg.freeOnly && ci.execution == "paid") "CI ${name} violates freeOnly"
      ++ lib.optional (ci.capabilities == [ ] || !(lib.all plain ci.capabilities)) "CI ${name} needs explicit coverage"
      ++ lib.optional (has cfg.forges ci.forge && has { github-actions = "github"; gitlab-ci = "gitlab"; bitbucket-pipelines = "bitbucket"; } ci.driver
        && cfg.forges.${ci.forge}.kind != { github-actions = "github"; gitlab-ci = "gitlab"; bitbucket-pipelines = "bitbucket"; }.${ci.driver}) "CI ${name} must use its native forge") cfg.ci)
    ++ lib.concatLists (lib.mapAttrsToList (name: repo:
      let
        primary = ciForge repo.ci;
        executors = [ repo.ci ] ++ repo.executionFallbacks;
      in
      lib.optional (!(plain name)) "invalid repository ID ${name}"
      ++ lib.optional (!(has repo.locations primary)) "${name} must live on primary CI's forge ${primary}"
      ++ lib.optional (!(lib.all (f: has cfg.forges f && validPath repo.locations.${f}) (lib.attrNames repo.locations))) "invalid location in ${name}"
      ++ lib.optional (!(unique ([ primary ] ++ repo.cloneFallbacks) && lib.all (has repo.locations) repo.cloneFallbacks)) "${name} clone fallbacks must name declared secondary locations once"
      ++ lib.optional (!(unique executors && lib.all (ci: has repo.locations (ciForge ci)) executors)) "${name} execution fallback locations are missing or duplicated"
      ++ lib.optional (lib.any (ci: cfg.ci.${ci}.execution == "free-hosted" && (repo.visibility != "public" || repo.sensitive)) executors) "${name} is not eligible for public free hosted execution"
      ++ lib.concatMap (rule: lib.optional
        (lib.all (key: (repo.attributes.${key} or null) == rule.attributes.${key}) (lib.attrNames rule.attributes)
          && (!(lib.all (has repo.locations) rule.require) || lib.any (has repo.locations) rule.forbid))
        "${name} violates placement rule ${rule.name}") cfg.placementRules
    ) cfg.repositories)
    ++ lib.concatMap (rule:
      lib.optional (rule.name == "" || rule.attributes == { }) "placement rule needs a name and attribute match"
      ++ lib.optional (!(lib.all (has cfg.forges) (rule.require ++ rule.forbid))) "placement rule refers to an undeclared forge"
      ++ lib.optional (lib.any (f: lib.elem f rule.forbid) rule.require) "placement rule both requires and forbids a forge") cfg.placementRules
    ++ lib.optional (!(unique (lib.concatLists (lib.mapAttrsToList (_: repo:
      lib.mapAttrsToList (forge: _: location repo forge) repo.locations) cfg.repositories)))) "two logical repositories claim the same location";
  checked = value: if errors == [ ] then value else fail (lib.concatStringsSep "; " errors);
in
{
  options.nixci.delivery = {
    admission = {
      memoryReserveMiB = mkOption { type = types.nullOr types.ints.positive; default = null; description = "Optional ccid runtime memory reserve. Unset leaves the worker's existing admission policy unchanged."; };
      ioFullAvg10 = mkOption { type = types.nullOr (types.addCheck types.number (n: n > 0 && n <= 100)); default = null; description = "Optional Linux full I/O PSI avg10 ceiling, in percent. The consumer chooses a measured or explicitly experimental threshold."; };
    };
    admissionEnvironment = mkOption { type = types.attrsOf types.str; readOnly = true; description = "ccid and legacy runtime admission variables, derived from explicit consumer limits."; };
    freeOnly = mkOption { type = types.bool; default = true; description = "Refuse paid CI declarations. Safe default; no hosted plan is provisioned by this module."; };
    forges = mkOption { type = types.attrsOf forgeType; default = { }; description = "Remote forge instances. These are references, not hosted workloads."; };
    ci = mkOption { type = types.attrsOf ciType; default = { }; description = "Available CI instances and their primary forge relationships."; };
    repositories = mkOption { type = types.attrsOf repoType; default = { }; description = "Logical repository IDs and explicitly declared placements."; };
    placementRules = mkOption { type = types.listOf ruleType; default = [ ]; description = "Attribute-based constraints over explicit repository placements."; };
    policy = mkOption { type = types.attrs; readOnly = true; description = "Validated ccid schema-1 policy value; serialize as JSON for ccid forge."; };
    json = mkOption { type = types.str; readOnly = true; description = "Validated ccid policy JSON. Contains no credentials."; };
    primaryUrls = mkOption { type = types.attrsOf types.str; readOnly = true; description = "Logical repository to its CI-derived primary URL, for runner registration and checks."; };
  };
  config.nixci.delivery = {
    admissionEnvironment = lib.optionalAttrs (cfg.admission.memoryReserveMiB != null) {
      CI_MIN_AVAILABLE_MB = toString cfg.admission.memoryReserveMiB;
    } // lib.optionalAttrs (cfg.admission.ioFullAvg10 != null) {
      CI_MAX_IO_PSI_AVG10 = toString cfg.admission.ioFullAvg10;
    };
    policy = checked {
      schema = 1;
      free_only = cfg.freeOnly;
      inherit (cfg) forges ci;
      repositories = lib.mapAttrs (_: repo: {
        inherit (repo) ci visibility sensitive attributes locations promotion;
        clone_fallbacks = repo.cloneFallbacks;
        execution_fallbacks = repo.executionFallbacks;
      }) cfg.repositories;
      placement_rules = cfg.placementRules;
    };
    json = builtins.toJSON cfg.policy;
    primaryUrls = checked (lib.mapAttrs (_: repo: location repo (ciForge repo.ci)) cfg.repositories);
  };
}
