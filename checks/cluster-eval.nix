# SPDX-License-Identifier: MIT OR Apache-2.0
# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# platform with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# ── THE PART THAT IS NOT AN ASSERTION ──────────────────────────────────────────────────────────
#
# The most important refusals in this repository are not guards at all: giving an execution-plane
# workload an inbound address, or a namespace of its own, is an UNKNOWN OPTION. Those cases are in
# `structurallyImpossible` below and they fail with "the option does not exist" -- which is the
# difference between a boundary somebody has to remember and one nobody can cross. Asserted here so
# that adding the option back would break this check rather than quietly widening the surface.
#
# Three refusals additionally have their MESSAGE asserted by content, because `tryEval` can only say
# THAT something was refused: the cross-plane Secret refusal (it has to name the Secret and both
# sides), the ordering refusal (it has to name both workloads and both numbers, since a person has
# to move one), and the unbacked-directory refusal (it has to say which directories and where).
{ pkgs, lib, nixidy, appsModule, addressingModule, clusterModule }:
let
  base = {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
    nixci.platform = {
      controlNamespace = "example-ci";
      executionNamespace = "example-ci-runners";
    };
  };

  mkEnv = values: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule addressingModule clusterModule base values ];
  };

  renders = values:
    (builtins.tryEval (builtins.seq (mkEnv values).environmentPackage.drvPath true)).success;

  # The assertions themselves rather than the throw they eventually cause.
  failures = values:
    map (a: a.message)
      (lib.filter (a: !a.assertion) (mkEnv values).config.nixidy.assertions);

  sorted = lib.sort (a: b: a < b);

  ## ---------------------------------------------------------------------
  ## The floor: an empty platform renders nothing at all
  ## ---------------------------------------------------------------------

  emptyCfg = (mkEnv { }).config;

  ## ---------------------------------------------------------------------
  ## The control: a complete platform, on both planes, that must resolve
  ## ---------------------------------------------------------------------

  good = {
    nixci.platform.project = "example-ci";

    nixci.forges = {
      forge = {
        forge = "forgejo";
        version = "0.0.0";
        slot = 64;
        exposure = "public";
        createNamespace = true;
        state = {
          data.hostPath = "/example/state/forge/data";
          config.hostPath = "/example/state/forge/config";
          lfs.hostPath = "/example/state/forge/lfs";
        };
      };
      remote-forge.forge = "github";
    };

    nixci.servers.server = {
      server = "crow";
      version = "0.0.0";
      slot = 65;
      exposure = "nb";
      forge = "forge";
      forgeUrl = "https://forge.example.com";
      state.data.hostPath = "/example/state/ci-server";
      credentials = {
        forgeClient = { secret = "example-ci-secrets"; key = "forge-client"; };
        forgeSecret = { secret = "example-ci-secrets"; key = "forge-secret"; };
        agentSecret = { secret = "example-ci-secrets"; key = "agent-secret"; };
      };
    };

    nixci.caches.cache = {
      cache = "nar-http";
      version = "0.0.0";
      slot = 66;
      state.store.hostPath = "/example/artifacts/store";
    };

    nixci.controllers.controller = {
      controller = "arc";
      slot = 67;
      manifests = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: controller-gha-rs-controller\n  namespace: example-ci\n" ];
    };

    nixci.runners = {
      builder = {
        runner = "crow-agent";
        version = "0.0.0";
        createNamespace = true;
        serves = "server";
        state.workspaces.hostPath = "/example/build/workspaces";
        caches = {
          nix.hostPath = "/example/build/store";
          cargo.hostPath = "/example/build/cargo";
        };
        credentials.agentSecret = { secret = "example-runner-secrets"; key = "agent-secret"; };
      };

      pool = {
        runner = "gha-scale-set";
        serves = "remote-forge";
        controller = "controller";
        credentials.forgeToken = { secret = "example-pool-token"; key = "forge-token"; };
        manifests = [ "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: pool\n  namespace: example-ci-runners\n" ];
      };
    };

    nixci.jobs.nightly = {
      schedule = "0 4 * * *";
      manifests = [ "apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: nightly\n  namespace: example-ci\n" ];
    };
  };

  goodCfg = (mkEnv good).config;

  # woodpecker-agent carries the same single-writer catalogue fact as the warm Crow runner, but
  # has no state whose hostPath could accidentally force Recreate. It is therefore the focused
  # regression for the fact the old hand-written translator dropped.
  woodpeckerCfg = (mkEnv (lib.recursiveUpdate good {
    nixci.runners.woodpecker = {
      runner = "woodpecker-agent";
      version = "0.0.0";
      serves = "server";
      credentials.agentSecret = {
        secret = "example-woodpecker-agent";
        key = "agent-secret";
      };
    };
  })).config;

  ## ---------------------------------------------------------------------
  ## The failing direction: guards
  ## ---------------------------------------------------------------------

  mustFail = {
    # THE HEADLINE INVARIANT. One Secret named from both planes: the runner would be able to read
    # the forge's OAuth client secret and the server's admin token by mounting the object it was
    # already given.
    one-secret-named-from-both-planes =
      lib.recursiveUpdate good {
        nixci.runners.builder.credentials.agentSecret.secret = "example-ci-secrets";
      };

    # The same breach by the blunter route: a whole-Secret mount rather than a named key.
    control-secret-mounted-wholesale-in-the-execution-plane =
      lib.recursiveUpdate good { nixci.runners.builder.envFromSecrets = [ "example-ci-secrets" ]; };

    # The floor under the whole model: one namespace for both planes makes the credential split
    # unenforceable by anything, because both Secret sets are then in reach of both.
    one-namespace-for-both-planes =
      lib.recursiveUpdate good { nixci.platform.executionNamespace = "example-ci"; };

    # A CI server whose forge is not declared: it comes up, serves a login page, and every sign-in
    # fails at the redirect.
    server-authenticating-against-an-undeclared-forge =
      lib.recursiveUpdate good { nixci.servers.server.forge = "nonesuch"; };

    server-against-a-hosted-forge-with-no-url =
      lib.recursiveUpdate good { nixci.servers.server.forgeUrl = null; };

    # THE ORDERING GUARD: the server below the forge it logs in through.
    server-ordered-below-its-forge =
      lib.recursiveUpdate good { nixci.servers.server.slot = 63; };

    # Nothing else can supply the address -- it is derived from a declared server, on purpose.
    runner-dialling-an-undeclared-server =
      lib.recursiveUpdate good { nixci.runners.builder.serves = "nonesuch"; };

    pool-registering-against-an-undeclared-forge =
      lib.recursiveUpdate good { nixci.runners.pool.serves = "nonesuch"; };

    # THE CONTROLLER INTERLOCK. Everything applies, everything reports healthy, no runner appears.
    pool-with-no-controller =
      lib.recursiveUpdate good { nixci.controllers.controller.enable = false; };

    runner-naming-a-controller-that-cannot-reconcile-it =
      lib.recursiveUpdate good { nixci.runners.builder.controller = "controller"; };

    # A runner whose control plane is a vendor's service: there is nothing here to point it at, and
    # a reference resolving to nothing reads as wiring that exists.
    external-runner-naming-something-to-serve =
      lib.recursiveUpdate good {
        nixci.runners.vendor = {
          runner = "container-agent";
          serves = "server";
          credentials.agentToken = { secret = "example-vendor-token"; key = "token"; };
        };
      };

    # A reference renders no object at all, so every one of these is a claim about a machine
    # somebody else operates.
    reference-forge-carrying-state =
      lib.recursiveUpdate good {
        nixci.forges.remote-forge.state.data.hostPath = "/example/state/not-ours";
      };

    reference-forge-carrying-a-credential =
      lib.recursiveUpdate good {
        nixci.forges.remote-forge.credentials.anything = { secret = "x"; key = "y"; };
      };

    # The grammar renders this one in full, so verbatim objects would be a second untyped copy.
    image-delivered-workload-passing-verbatim-objects =
      lib.recursiveUpdate good {
        nixci.forges.forge.manifests = [ "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n" ];
      };

    # The chart's own version is inside the objects delivered; a second copy here is a pin nothing
    # keeps honest.
    chart-delivered-workload-naming-a-version =
      lib.recursiveUpdate good { nixci.controllers.controller.version = "0.0.0"; };

    image-delivered-workload-naming-neither-version-nor-image =
      lib.recursiveUpdate good { nixci.caches.cache.version = null; };

    # Every directory the software cannot lose must be backed. A forge missing its config directory
    # regenerates its instance secret on every restart and reports itself healthy throughout.
    workload-with-an-unbacked-state-directory =
      lib.recursiveUpdate good {
        nixci.forges.second-forge = {
          forge = "gitea";
          version = "0.0.0";
          slot = 69;
          state.data.hostPath = "/example/state/second-forge";
        };
      };

    state-with-no-backing =
      lib.recursiveUpdate good { nixci.forges.forge.state.data.hostPath = null; };

    state-with-both-backings =
      lib.recursiveUpdate good { nixci.forges.forge.state.data.claim = "example-forge-data"; };

    # A cache key that is not the catalogue's mounts a volume nothing reads and wires no
    # environment, which looks like a warm build and is a cold one.
    cache-key-the-catalogue-does-not-hold =
      lib.recursiveUpdate good { nixci.runners.builder.caches.maven.hostPath = "/example/build/maven"; };

    credential-role-the-software-does-not-read =
      lib.recursiveUpdate good {
        nixci.servers.server.credentials.nonesuch = { secret = "x"; key = "y"; };
      };

    missing-required-credential-role =
      lib.recursiveUpdate good {
        nixci.runners.builder.credentials = lib.mkForce { };
      };

    two-workloads-on-one-slot =
      lib.recursiveUpdate good { nixci.caches.cache.slot = 65; };

    two-workloads-creating-one-namespace =
      lib.recursiveUpdate good { nixci.servers.server.createNamespace = true; };

    # A Namespace created by a workload rendered below the grammar carries none of the grammar's
    # protection against being pruned -- and a CI namespace holds the forge's repositories.
    directly-rendered-workload-anchoring-a-namespace =
      lib.recursiveUpdate good { nixci.controllers.controller.createNamespace = true; };

    schedule-that-delivers-nothing =
      lib.recursiveUpdate good { nixci.jobs.nightly.manifests = [ ]; };
  };

  ## ---------------------------------------------------------------------
  ## The failing direction: the separation, which is not a guard
  ##
  ## Each of these is an UNKNOWN OPTION rather than a refused value. That is the whole claim of this
  ## repository's design, so it is checked rather than asserted in prose.
  ## ---------------------------------------------------------------------

  structurallyImpossible = {
    execution-plane-workload-given-an-exposure-class =
      lib.recursiveUpdate good { nixci.runners.builder.exposure = "public"; };

    execution-plane-workload-given-a-slot =
      lib.recursiveUpdate good { nixci.runners.builder.slot = 70; };

    execution-plane-workload-given-its-own-namespace =
      lib.recursiveUpdate good { nixci.runners.builder.namespace = "example-somewhere-else"; };

    control-plane-workload-given-its-own-namespace =
      lib.recursiveUpdate good { nixci.servers.server.namespace = "example-somewhere-else"; };

    # A warm runner is the single writer of its own store. There is no replica count anywhere in
    # this module, in either plane, so a second copy cannot be asked for here at all.
    workload-given-a-replica-count =
      lib.recursiveUpdate good { nixci.runners.builder.replicas = 2; };
  };

  wronglyRendered =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) mustFail));
  wronglyAccepted =
    lib.attrNames (lib.filterAttrs (_: v: v) (lib.mapAttrs (_: renders) structurallyImpossible));

  ## ---------------------------------------------------------------------
  ## Messages, read as text
  ## ---------------------------------------------------------------------

  firstMatching = values: needle:
    let msgs = lib.filter (m: lib.hasInfix needle m) (failures values); in
    if msgs == [ ] then "" else lib.head msgs;

  crossPlaneMessage = firstMatching mustFail.one-secret-named-from-both-planes "example-ci-secrets";
  orderingMessage = firstMatching mustFail.server-ordered-below-its-forge "authenticates through";
  unbackedMessage = firstMatching mustFail.workload-with-an-unbacked-state-directory "second-forge";

  ## ---------------------------------------------------------------------
  ## Positive resolution
  ## ---------------------------------------------------------------------

  addressed = (mkEnv (lib.recursiveUpdate good {
    nixci.platform.origin = "nixci";
    nixk3s.addressing = {
      enable = true;
      bands.example-ci = { base = 64; size = 16; };
      bindings.nixci = "example-ci";
    };
  })).config;

  results = {
    # ── The floor ─────────────────────────────────────────────────────────────────────────────
    "an empty platform defines no app in the grammar at all" =
      emptyCfg.nixk3s.apps == { };

    "an empty platform reports nothing on either plane, nothing rendered, and no slot" =
      emptyCfg.nixci.controlPlane == [ ] && emptyCfg.nixci.executionPlane == [ ]
      && emptyCfg.nixci.renderedByGrammar == [ ] && emptyCfg.nixci.renderedDirectly == [ ]
      && emptyCfg.nixci.notRendered == [ ] && emptyCfg.nixci.slots == { }
      && emptyCfg.nixci.controlSecrets == [ ] && emptyCfg.nixci.executionSecrets == [ ];

    "the public platform project still resolves to the delivery default" =
      emptyCfg.nixci.platform.project == "default";

    "an empty platform raises no assertion of its own -- an unused module must be silent" =
      lib.all (a: a.assertion) emptyCfg.nixidy.assertions;

    # ── The control ───────────────────────────────────────────────────────────────────────────
    "a complete platform on both planes renders" = renders good;

    "the two planes are exactly the workloads their catalogue entries put there" =
      sorted goodCfg.nixci.controlPlane == [ "cache" "controller" "forge" "nightly" "remote-forge" "server" ]
      && sorted goodCfg.nixci.executionPlane == [ "builder" "pool" ];

    "the render split is countable: images through the grammar, charts and schedules below it" =
      sorted goodCfg.nixci.renderedByGrammar == [ "builder" "cache" "forge" "server" ]
      && sorted goodCfg.nixci.renderedDirectly == [ "controller" "nightly" "pool" ]
      && goodCfg.nixci.notRendered == [ "remote-forge" ];

    "the three routes are disjoint and together account for every declared workload" =
      lib.intersectLists goodCfg.nixci.renderedByGrammar goodCfg.nixci.renderedDirectly == [ ]
      && lib.length
        (goodCfg.nixci.renderedByGrammar ++ goodCfg.nixci.renderedDirectly
        ++ goodCfg.nixci.notRendered) == 8;

    "a declared platform's whole contribution to the render is exactly the workloads it renders" =
      sorted (lib.subtractLists (lib.attrNames emptyCfg.applications) (lib.attrNames goodCfg.applications))
      == sorted (goodCfg.nixci.renderedByGrammar ++ goodCfg.nixci.renderedDirectly);

    # ── THE PLANE SEPARATION, RESOLVED ────────────────────────────────────────────────────────
    "a workload's namespace is its PLANE's, and nothing declared it" =
      goodCfg.nixk3s.apps.server.namespace == "example-ci"
      && goodCfg.nixk3s.apps.forge.namespace == "example-ci"
      && goodCfg.nixk3s.apps.builder.namespace == "example-ci-runners"
      && goodCfg.applications.pool.namespace == "example-ci-runners";

    "an execution-plane workload declares NO PORTS, which is what makes the grammar render no Service" =
      goodCfg.nixk3s.apps.builder.ports == { }
      && goodCfg.nixk3s.apps.forge.ports.http.number == 3000
      && goodCfg.nixk3s.apps.server.ports.grpc.number == 9000;

    "the credential split is data: the two planes' Secret sets are disjoint" =
      sorted goodCfg.nixci.controlSecrets == [ "example-ci-secrets" ]
      && sorted goodCfg.nixci.executionSecrets == [ "example-pool-token" "example-runner-secrets" ]
      && lib.intersectLists goodCfg.nixci.controlSecrets goodCfg.nixci.executionSecrets == [ ];

    "no runner can appear in the slot report, because there is no slot option on that plane" =
      goodCfg.nixci.slots == { forge = 64; server = 65; cache = 66; controller = 67; }
      && goodCfg.nixci.slots == goodCfg.nixci.clusterSlots;

    "catalogue singleWriter reaches an otherwise stateless warm Woodpecker agent" =
      woodpeckerCfg.nixk3s.apps.woodpecker.singleWriter;

    # THE ONE THING THAT CROSSES, AND IT IS DERIVED. Not a value anybody supplied: the server's own
    # name, the control plane's namespace, the cluster domain, and the port its catalogue entry says
    # agents dial.
    "the runner's server address is computed from the declared server, not configured" =
      goodCfg.nixk3s.apps.builder.env.CROW_SERVER == "server.example-ci.svc.cluster.local:9000";

    # ── The knowledge reaches the objects ─────────────────────────────────────────────────────
    "the image is the catalogue repository plus THIS workload's version" =
      goodCfg.nixk3s.apps.forge.image == "codeberg.org/forgejo/forgejo:0.0.0";

    "each directory lands where the software writes it, backed by what the consumer supplied" =
      goodCfg.nixk3s.apps.forge.state.config.mountPath == "/etc/gitea"
      && goodCfg.nixk3s.apps.forge.state.config.hostPath == "/example/state/forge/config"
      && goodCfg.nixk3s.apps.builder.state.workspaces.mountPath == "/workspaces";

    # Whether the software may WRITE a directory is the catalogue's, not the declaration's -- there
    # is no `readOnly` option on a backing anywhere in this module.
    "a cache server serves its store READ-ONLY, and nothing in a declaration can change that" =
      goodCfg.nixk3s.apps.cache.state.store.readOnly
      && !goodCfg.nixk3s.apps.forge.state.data.readOnly;

    "a backed cache is mounted AND wired; one that is not backed is neither" =
      goodCfg.nixk3s.apps.builder.state.cargo.mountPath == "/caches/cargo"
      && goodCfg.nixk3s.apps.builder.env.CARGO_HOME == "/caches/cargo"
      && !(goodCfg.nixk3s.apps.builder.state ? sccache)
      && !(goodCfg.nixk3s.apps.builder.env ? SCCACHE_DIR);

    # The forge coupling: four variables named for the forge KIND, three of them knowledge.
    "the forge coupling is templated on the forge the server actually names" =
      goodCfg.nixk3s.apps.server.env.CROW_FORGEJO == "true"
      && goodCfg.nixk3s.apps.server.env.CROW_FORGEJO_URL == "https://forge.example.com"
      && goodCfg.nixk3s.apps.server.secrets.forgeClient.env.CROW_FORGEJO_CLIENT == "forge-client";

    "a credential arrives as a reference, under the variable the SOFTWARE names, never as a value" =
      goodCfg.nixk3s.apps.server.secrets.forgeSecret.secret == "example-ci-secrets"
      && goodCfg.nixk3s.apps.builder.secrets.agentSecret.env.CROW_AGENT_SECRET == "agent-secret";

    # A chart-delivered workload renders no container, so its credential is published by NAME rather
    # than injected into an environment that does not exist.
    "a chart's credential is published rather than pretended to be wired" =
      goodCfg.nixci.chartCredentials.pool.forgeToken == "example-pool-token"
      && !(goodCfg.nixk3s.apps ? pool)
      && goodCfg.applications.pool.yamls != [ ];

    "the cross-plane binding derives the controller's namespace and account, and the pool names neither" =
      goodCfg.nixci.crossPlaneBindings.pool == {
        controller = "controller";
        namespace = "example-ci";
        serviceAccount = "controller-gha-rs-controller";
      };

    "chart coordinates are published WITHOUT a version -- a version here would be a second pin" =
      goodCfg.nixci.charts.controller == {
        repo = "oci://ghcr.io/actions/actions-runner-controller-charts";
        name = "gha-runner-scale-set-controller";
      }
      && !(goodCfg.nixci.charts.controller ? version);

    "what fires on a timer in the control plane is one readable list" =
      goodCfg.nixci.schedules == { nightly = "0 4 * * *"; };

    "a probe watches the port the catalogue calls primary, with the software's own timing" =
      goodCfg.nixk3s.apps.forge.probes.readiness.port == "http"
      && goodCfg.nixk3s.apps.forge.probes.readiness.path == "/api/healthz"
      && goodCfg.nixk3s.apps.cache.probes.readiness.path == "/nix-cache-info";

    "everything rendered below the grammar carries server-side apply and server-side diff" =
      goodCfg.applications.controller.syncPolicy.syncOptions.serverSideApply == "ServerSideApply=true"
      && goodCfg.applications.nightly.compareOptions.serverSideDiff == "ServerSideDiff=true";

    # ── The band model ────────────────────────────────────────────────────────────────────────
    "with the band model in the render, grammar-rendered workloads carry the declaring origin" =
      addressed.nixk3s.apps.server.origin == "nixci"
      && addressed.nixk3s.apps.server.slot == 65;

    "and a runner is stamped with the origin and NO number, which is right for a workload with no Service" =
      addressed.nixk3s.apps.builder.origin == "nixci"
      && addressed.nixk3s.apps.builder.slot == null;

    "without that switch the grammar's apps name no origin at all -- those are the band model's terms" =
      goodCfg.nixk3s.apps.server.origin == null && goodCfg.nixk3s.apps.server.slot == null;

    # ── The failing direction ─────────────────────────────────────────────────────────────────
    "every guard fires: nothing in the must-fail set renders" =
      wronglyRendered == [ ];

    "the separation is structural: every plane-crossing declaration is an unknown option" =
      wronglyAccepted == [ ];

    "the cross-plane refusal names the Secret and the workloads on both sides of it" =
      lib.hasInfix "example-ci-secrets" crossPlaneMessage
      && lib.hasInfix "`server`" crossPlaneMessage
      && lib.hasInfix "`builder`" crossPlaneMessage;

    "the ordering refusal names both workloads and both numbers, because a person has to move one" =
      lib.hasInfix "`server`" orderingMessage
      && lib.hasInfix "`forge`" orderingMessage
      && lib.hasInfix "63" orderingMessage
      && lib.hasInfix "64" orderingMessage;

    "the unbacked-directory refusal says which directories the software writes, and where" =
      lib.hasInfix "/var/lib/gitea" unbackedMessage
      && lib.hasInfix "/etc/gitea" unbackedMessage;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then
  pkgs.writeText "nixci-cluster-eval" ''
    control renders, the floor holds, and every guard fires:
    ${lib.concatMapStringsSep "\n" (n: "  refused: ${n}") (lib.attrNames mustFail)}
    and these are not refusals at all -- they are unknown options:
    ${lib.concatMapStringsSep "\n" (n: "  impossible: ${n}") (lib.attrNames structurallyImpossible)}
  ''
else
  throw ''
    nixci: cluster-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
    ${lib.optionalString (wronglyRendered != [ ])
      "Declarations that rendered but had to be refused: ${lib.concatStringsSep ", " wronglyRendered}"}
    ${lib.optionalString (wronglyAccepted != [ ])
      "Declarations that evaluated but had to be unknown options: ${lib.concatStringsSep ", " wronglyAccepted}"}
  ''
