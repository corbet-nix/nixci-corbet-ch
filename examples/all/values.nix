# SPDX-License-Identifier: MIT OR Apache-2.0
# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders the whole platform from here, so a module that stops evaluating, or that
# grows a required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, path, name, number, URL and image is invented for this
# file, and no credential appears in any form — only the NAMES of Secrets that would hold them.
#
# The declarations are chosen to cover the paths that differ in what gets RENDERED rather than
# merely in what evaluates, and above all to put BOTH PLANES in one render:
#
#   - a hosted forge, anchoring the control namespace, on node-path state, reachable to people;
#   - a forge somebody else runs, which renders nothing at all and is still declared;
#   - a CI server, above the forge it authenticates through, with the four-variable forge coupling
#     and four credential roles in one control-plane Secret;
#   - a cache, pinned by digest, whose store is mounted read-only because the catalogue says so;
#   - a runner controller, delivered as whole objects, in the CONTROL plane;
#   - a warm builder, anchoring the EXECUTION namespace, on its own Secret, with warm caches and a
#     server address nobody wrote down;
#   - a stateless Woodpecker warm agent, proving catalogue singleWriter alone forces Recreate;
#   - an ephemeral runner pool for the remote forge, bound back to the controller across the planes;
#   - a schedule, which is not a running process and so is delivered as an object.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  # A cluster fact the app grammar refuses to guess: which node holds the directories that node-path
  # state lives on. Set once here instead of on every workload.
  nixk3s.appPlatform.hostPathNodeSelector = { "kubernetes.io/hostname" = "example-node"; };

  # The band model, with the layout a consumer would supply. Every value is invented: the model
  # ships no band, no base and no binding, because which category owns which run of the number space
  # is the shape of somebody's fleet.
  nixk3s.addressing = {
    enable = true;
    bands.example-ci = {
      base = 64;
      size = 16;
      description = "the continuous-integration platform";
    };
    bindings.nixci = "example-ci";
  };

  nixci.platform = {
    # THE TWO NAMESPACES ARE THE SEPARATION. One Secret set unseals into each; the second one holds
    # nothing but what a runner needs to say hello.
    controlNamespace = "example-ci";
    executionNamespace = "example-ci-runners";
    project = "example-ci";
    # Hands the grammar-rendered workloads' slots to the band model above. Null (the default)
    # everywhere that model is not part of the render.
    origin = "nixci";
  };

  nixci.forges = {
    # The hosted forge: CI's code-hosting half, and the identity the server below logs in through.
    # It anchors the control namespace because it is rendered by the app grammar and therefore
    # stamps the protection a namespace holding repositories needs.
    example-forge = {
      forge = "forgejo";
      # Deliberately tag-only, so the render sees the grammar's unpinned-image warning fire as well
      # as the digest-pinned path further down.
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

    # A forge somebody else runs. Renders NO object of any kind; the pool below still names it, and
    # the platform's own report still says the dependency is there.
    example-remote-forge.forge = "github";
  };

  nixci.servers.example-server = {
    server = "crow";
    version = "0.0.0";
    # ABOVE the forge it authenticates through — declared in that order deliberately, because the
    # module refuses the inverted one.
    slot = 65;
    exposure = "nb";
    forge = "example-forge";
    # A value: the address a browser is redirected to for the OAuth handshake. The VARIABLE it
    # arrives in comes from the catalogue.
    forgeUrl = "https://forge.example.com";
    state.data.hostPath = "/example/state/ci-server";
    # FOUR ROLES, ONE CONTROL-PLANE SECRET. The forge's OAuth client secret and the admin token are
    # in here; neither is reachable from the execution plane, which has its own Secret below.
    credentials = {
      forgeClient = { secret = "example-ci-secrets"; key = "forge-client"; };
      forgeSecret = { secret = "example-ci-secrets"; key = "forge-secret"; };
      agentSecret = { secret = "example-ci-secrets"; key = "agent-secret"; };
      adminToken = { secret = "example-ci-secrets"; key = "admin-token"; };
    };
  };

  nixci.caches.example-cache = {
    cache = "nar-http";
    # A whole reference rather than a version: pinned by digest, which is what the grammar asks for
    # and what the forge above deliberately does not do.
    image = "registry.example.com/example-org/example-nar-http:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    slot = 66;
    # The read face of the cache. The same directory is mounted READ-WRITE by the builder below —
    # the one place the two planes touch through the filesystem rather than the network.
    state.store.hostPath = "/example/artifacts/store";
  };

  # A runner controller: a CONTROL-plane workload whose blast radius is the execution plane. Its
  # chart output stands in for the real thing; a consumer renders its own.
  nixci.controllers.example-controller = {
    controller = "arc";
    slot = 67;
    manifests = [
      ''
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: example-controller-gha-rs-controller
          namespace: example-ci
      ''
      ''
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: example-controller
          namespace: example-ci
        spec:
          replicas: 1
          selector:
            matchLabels:
              app.kubernetes.io/name: example-controller
          template:
            metadata:
              labels:
                app.kubernetes.io/name: example-controller
            spec:
              serviceAccountName: example-controller-gha-rs-controller
              containers:
                - name: manager
                  image: registry.example.com/example-org/example-controller:0.0.0
      ''
    ];
  };

  nixci.runners = {
    # THE WARM BUILDER. Steps run as processes in this pod. It anchors the execution namespace, it
    # holds ONE credential, and it renders no Service — there is no option here that could give it
    # one.
    example-builder = {
      runner = "crow-agent";
      version = "0.0.0";
      createNamespace = true;
      # The server's address is DERIVED from this name and the control plane's namespace. Nothing
      # in this file writes a cross-plane address down.
      serves = "example-server";
      state.workspaces.hostPath = "/example/build/workspaces";
      # Reconstructible. Backing one also wires the environment that points its toolchain at the
      # mount; the ones left out stay unwired rather than pointing at a directory nothing mounted.
      caches = {
        nix.hostPath = "/example/build/store";
        cargo.hostPath = "/example/build/cargo";
        go = { hostPath = "/example/build/go"; hostPathType = "DirectoryOrCreate"; };
      };
      # A DIFFERENT SECRET FROM THE SERVER'S, carrying the same shared value and nothing else. Name
      # the server's here instead and evaluation fails.
      credentials.agentSecret = { secret = "example-runner-secrets"; key = "agent-secret"; };
    };

    # No state or cache happens to force its rollout strategy. Recreate therefore proves that the
    # factory projected the catalogue's singleWriter fact, which the old translator dropped.
    example-woodpecker = {
      runner = "woodpecker-agent";
      version = "0.0.0";
      serves = "example-server";
      credentials.agentSecret = {
        secret = "example-woodpecker-agent";
        key = "agent-secret";
      };
    };

    # An ephemeral pool for the remote forge, reconciled by the controller in the OTHER plane.
    example-pool = {
      runner = "gha-scale-set";
      serves = "example-remote-forge";
      controller = "example-controller";
      credentials.forgeToken = { secret = "example-pool-token"; key = "forge-token"; };
      manifests = [
        ''
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: example-pool
            namespace: example-ci-runners
        ''
      ];
    };
  };

  # A schedule: not a running process, so the grammar has no term for it and its object is a value.
  nixci.jobs.example-nightly = {
    schedule = "0 4 * * *";
    manifests = [
      ''
        apiVersion: batch/v1
        kind: CronJob
        metadata:
          name: example-nightly
          namespace: example-ci
        spec:
          schedule: "0 4 * * *"
          jobTemplate:
            spec:
              template:
                spec:
                  restartPolicy: Never
                  containers:
                    - name: nightly
                      image: registry.example.com/example-org/example-nightly:0.0.0
      ''
    ];
  };
}
