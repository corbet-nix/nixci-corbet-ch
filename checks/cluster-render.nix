# SPDX-License-Identifier: MIT OR Apache-2.0
# Asserts what the platform actually RENDERS, by reading the manifests out of the rendered
# environment with a YAML parser.
#
# Why not just evaluate: a module that type-checks can still render a runner with a Service in front
# of it, a cache whose store is writable by the process serving it, or a forge whose configuration
# directory is not mounted. None of that is an eval error. The first is a reachable surface running
# code somebody pushed; the second lets the thing that serves signed artifacts rewrite them; the
# third silently invalidates every session and token the forge ever issued.
#
# THE CENTRAL ASSERTION IN THIS FILE IS AN ABSENCE, and it is checked twice, on the bytes rather
# than on the model: no Service exists anywhere in the execution namespace, and no control-plane
# Secret NAME appears anywhere in an execution-plane manifest. Those two are the whole claim of this
# repository, and a claim about a boundary is worth exactly as much as the test that reads the
# output and finds nothing there.
{ pkgs, lib, env }:

pkgs.runCommand "nixci-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
  # Not manifests, so they cannot be asserted from the tree: the reports that say which plane each
  # workload landed on and which side of the render split it took.
  controlPlane = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.controlPlane);
  executionPlane = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.executionPlane);
  byGrammar = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.renderedByGrammar);
  directly = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.renderedDirectly);
  notRendered = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.notRendered);
  controlSecrets = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.controlSecrets);
  executionSecrets = lib.concatStringsSep " " (lib.sort (a: b: a < b) env.config.nixci.executionSecrets);
} ''
  set -euo pipefail
  fail=0

  check() {
    if [ "$2" = "$3" ]; then
      echo "  ok   $1: $3"
    else
      echo "  FAIL $1: expected '$2', got '$3'"
      fail=1
    fi
  }

  present() {
    if [ -e "$2" ]; then echo "  ok   $1: rendered"; else echo "  FAIL $1: not rendered ($2)"; fail=1; fi
  }

  absent() {
    if [ -e "$2" ]; then echo "  FAIL $1: rendered but should not be ($2)"; fail=1; else echo "  ok   $1: correctly not rendered"; fi
  }

  y() { yq -r "$1" "$2"; }

  CONTROL_NS=example-ci
  EXEC_NS=example-ci-runners

  FORGE_D=$manifests/example-forge/Deployment-example-forge.yaml
  FORGE_S=$manifests/example-forge/Service-example-forge.yaml
  FORGE_NS=$manifests/example-forge/Namespace-example-ci.yaml
  SRV_D=$manifests/example-server/Deployment-example-server.yaml
  SRV_S=$manifests/example-server/Service-example-server.yaml
  CACHE_D=$manifests/example-cache/Deployment-example-cache.yaml
  CACHE_S=$manifests/example-cache/Service-example-cache.yaml
  BLD_D=$manifests/example-builder/Deployment-example-builder.yaml
  BLD_NS=$manifests/example-builder/Namespace-example-ci-runners.yaml
  WOOD_D=$manifests/example-woodpecker/Deployment-example-woodpecker.yaml
  CTL_SA=$manifests/example-controller/ServiceAccount-example-controller-gha-rs-controller.yaml
  CTL_D=$manifests/example-controller/Deployment-example-controller.yaml
  POOL_SA=$manifests/example-pool/ServiceAccount-example-pool.yaml
  CRON=$manifests/example-nightly/CronJob-example-nightly.yaml

  echo "== the whole rendered Deployment of the warm builder -- the execution plane, in full =="
  cat $BLD_D

  echo
  echo "== THE EXECUTION PLANE RENDERS NO SERVICE. Not one, anywhere, for any workload. =="
  absent "a Service for the warm builder" "$manifests/example-builder/Service-example-builder.yaml"
  absent "a Service for the Woodpecker agent" "$manifests/example-woodpecker/Service-example-woodpecker.yaml"
  absent "a Service for the runner pool"  "$manifests/example-pool/Service-example-pool.yaml"
  for svc in $(find -L $manifests -type f -name 'Service-*.yaml' | sort); do
    check "$(basename $svc): lands in the control namespace" "$CONTROL_NS" "$(y '.metadata.namespace' $svc)"
  done
  # And the same claim from the other side: nothing at all is rendered into the execution namespace
  # except the workloads that belong there.
  for f in $(find -L $manifests -type f -name '*.yaml' | sort); do
    ns=$(y '.metadata.namespace // ""' $f)
    kind=$(y '.kind' $f)
    if [ "$ns" = "$EXEC_NS" ] && [ "$kind" = "Service" ]; then
      echo "  FAIL a Service exists in the execution namespace: $f"; fail=1
    fi
  done
  echo "  ok   no Service exists in the execution namespace at all"

  echo
  echo "== NO CONTROL-PLANE SECRET NAME APPEARS IN AN EXECUTION-PLANE MANIFEST =="
  # The forge's OAuth client secret and the server's admin token live in this object. A build script
  # runs in the execution plane; this is the grep that says it cannot reach them.
  for f in $(find -L $manifests/example-builder $manifests/example-woodpecker $manifests/example-pool -type f | sort); do
    if grep -q 'example-ci-secrets' "$f"; then
      echo "  FAIL control-plane Secret named in an execution-plane manifest: $f"; fail=1
    fi
  done
  echo "  ok   no execution-plane manifest names the control plane's Secret"
  check "the runner's own Secret is a different object" "example-runner-secrets" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_AGENT_SECRET") | .valueFrom.secretKeyRef.name' $BLD_D)"
  check "and it arrives as a reference, never as a value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_AGENT_SECRET") | .value' $BLD_D)"
  check "the two planes' Secret sets are disjoint (control)"   "example-ci-secrets" "$controlSecrets"
  check "the two planes' Secret sets are disjoint (execution)" \
    "example-pool-token example-runner-secrets example-woodpecker-agent" "$executionSecrets"

  echo
  echo "== THE ONE THING THAT CROSSES THE PLANES, AND IT IS DERIVED RATHER THAN CONFIGURED =="
  check "the runner dials the server at an address nobody wrote down" \
    "example-server.example-ci.svc.cluster.local:9000" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_SERVER") | .value' $BLD_D)"

  echo
  echo "== a plane decides the namespace; no declaration did =="
  check "forge namespace"   "$CONTROL_NS" "$(y '.metadata.namespace' $FORGE_D)"
  check "server namespace"  "$CONTROL_NS" "$(y '.metadata.namespace' $SRV_D)"
  check "cache namespace"   "$CONTROL_NS" "$(y '.metadata.namespace' $CACHE_D)"
  check "builder namespace" "$EXEC_NS"    "$(y '.metadata.namespace' $BLD_D)"
  check "Woodpecker namespace" "$EXEC_NS" "$(y '.metadata.namespace' $WOOD_D)"
  check "pool namespace"    "$EXEC_NS"    "$(y '.metadata.namespace' $POOL_SA)"

  echo
  echo "== each namespace is anchored by a grammar-rendered workload, so it cannot be cascade-deleted =="
  present "control namespace"   "$FORGE_NS"
  present "execution namespace" "$BLD_NS"
  check "control ns Prune=false"   "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $FORGE_NS)"
  check "execution ns Prune=false" "Prune=false" "$(y '.metadata.annotations."argocd.argoproj.io/sync-options"' $BLD_NS)"
  absent "a namespace anchored below the grammar" "$manifests/example-controller/Namespace-example-ci.yaml"

  echo
  echo "== the forge: its own ports, its own directories, and the config directory that is STATE =="
  check "image is the catalogue repository plus this workload's version" \
    "codeberg.org/forgejo/forgejo:0.0.0" "$(y '.spec.template.spec.containers[0].image' $FORGE_D)"
  check "http port"  "3000" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "http") | .containerPort' $FORGE_D)"
  check "ssh port"   "2222" "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "ssh")  | .containerPort' $FORGE_D)"
  # Correctness environment, not policy: the listener must agree with the port declared above.
  check "ssh listener agrees with the declared port" "2222" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "FORGEJO__server__SSH_LISTEN_PORT") | .value' $FORGE_D)"
  check "data directory is the catalogue's"   "/var/lib/gitea" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data")   | .mountPath' $FORGE_D)"
  check "config directory is the catalogue's" "/etc/gitea" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "config") | .mountPath' $FORGE_D)"
  check "lfs directory is the catalogue's"    "/var/lib/gitea/data/lfs" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "lfs")    | .mountPath' $FORGE_D)"
  check "backing is the declaration's" "/example/state/forge/config" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "config") | .hostPath.path' $FORGE_D)"
  check "state must already exist -- an empty directory would be a brand new forge" "Directory" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .hostPath.type' $FORGE_D)"
  check "probe is the forge's own health endpoint" "/api/healthz" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $FORGE_D)"
  check "no liveness probe was synthesized" "null" "$(y '.spec.template.spec.containers[0].livenessProbe' $FORGE_D)"
  check "single writer: state forces Recreate, never a rolling update" "Recreate" "$(y '.spec.strategy.type' $FORGE_D)"
  check "one replica" "1" "$(y '.spec.replicas' $FORGE_D)"
  check "node-path state pins the pod, and the objects say so" "true" \
    "$(y '.metadata.labels."nixk3s.dev/node-pinned"' $FORGE_D)"

  echo
  echo "== the CI server: two ports, two audiences, and a forge coupling named for the forge =="
  check "http port for people and webhooks" "8000" \
    "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "http") | .containerPort' $SRV_D)"
  check "grpc port agents dial"             "9000" \
    "$(y '.spec.template.spec.containers[0].ports[] | select(.name == "grpc") | .containerPort' $SRV_D)"
  check "the Service targets both by name"  "http" "$(y '.spec.ports[] | select(.port == 8000) | .targetPort' $SRV_S)"
  check "forge switch is knowledge, and this module renders it" "true" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_FORGEJO") | .value' $SRV_D)"
  check "forge URL is a value, and the consumer supplied it" "https://forge.example.com" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_FORGEJO_URL") | .value' $SRV_D)"
  check "the OAuth client id is a reference under the variable named for the forge" "example-ci-secrets" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_FORGEJO_CLIENT") | .valueFrom.secretKeyRef.name' $SRV_D)"
  check "the OAuth client SECRET never appears as a value" "null" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_FORGEJO_SECRET") | .value' $SRV_D)"
  check "the admin token is a reference too" "admin-token" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CROW_ADMIN_TOKEN") | .valueFrom.secretKeyRef.key' $SRV_D)"
  absent "a rendered Secret object anywhere" "$manifests/example-server/Secret-example-ci-secrets.yaml"

  echo
  echo "== the cache: the READ face, and the store it serves is mounted read-only =="
  check "store mount is read-only" "true" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "store") | .readOnly' $CACHE_D)"
  check "probe is the file that MAKES a directory a cache" "/nix-cache-info" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet.path' $CACHE_D)"
  check "pinned by digest, which is what the grammar asks for" \
    "registry.example.com/example-org/example-nar-http:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000" \
    "$(y '.spec.template.spec.containers[0].image' $CACHE_D)"

  echo
  echo "== the warm builder: caches wired only where they are backed =="
  check "a backed cache is mounted"      "/caches/cargo" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "cargo") | .mountPath' $BLD_D)"
  check "and its toolchain is wired to it" "/caches/cargo" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "CARGO_HOME") | .value' $BLD_D)"
  check "a cache with two variables wires both" "/caches/go/mod" \
    "$(y '.spec.template.spec.containers[0].env[] | select(.name == "GOMODCACHE") | .value' $BLD_D)"
  # Counted rather than matched: a `select` that finds nothing prints an empty line, which would
  # also be what a genuinely broken query prints. A length of zero is the unambiguous statement.
  check "an unbacked cache is not mounted"  "0" \
    "$(y '[.spec.template.spec.containers[0].volumeMounts[] | select(.name == "sccache")] | length' $BLD_D)"
  check "and is not wired either -- a variable naming nothing is worse than no variable" "0" \
    "$(y '[.spec.template.spec.containers[0].env[] | select(.name == "SCCACHE_DIR")] | length' $BLD_D)"
  check "the workspace is state, so the builder is a single writer too" "Recreate" "$(y '.spec.strategy.type' $BLD_D)"
  check "no resource sizing was invented for it" "null" "$(y '.spec.template.spec.containers[0].resources' $BLD_D)"

  echo
  echo "== catalogue singleWriter reaches a stateless warm agent =="
  check "Woodpecker rolls by replacement even with no state volume to force it" \
    "Recreate" "$(y '.spec.strategy.type' $WOOD_D)"

  echo
  echo "== what the grammar cannot express passes through verbatim =="
  present "the controller's chart output" "$CTL_SA"
  present "the controller's Deployment"   "$CTL_D"
  check "verbatim content untouched" "example-controller-gha-rs-controller" \
    "$(y '.spec.template.spec.serviceAccountName' $CTL_D)"
  present "the schedule's own object" "$CRON"
  check "a schedule is a CronJob, and the grammar has no term for one" "CronJob" "$(y '.kind' $CRON)"
  absent "a Deployment for the schedule" "$manifests/example-nightly/Deployment-example-nightly.yaml"
  absent "a Deployment for the runner pool" "$manifests/example-pool/Deployment-example-pool.yaml"

  echo
  echo "== a large custom resource cannot be applied client-side: server-side apply and diff =="
  for app in example-controller example-pool example-nightly; do
    check "$app: SSA" "ServerSideApply=true" \
      "$(y '.spec.syncPolicy.syncOptions[0]' $manifests/apps/Application-$app.yaml)"
    check "$app: SSD" "ServerSideDiff=true" \
      "$(y '.metadata.annotations."argocd.argoproj.io/compare-options"' $manifests/apps/Application-$app.yaml)"
  done
  check "and NOT on an ordinary rendered workload" "null" \
    "$(y '.spec.syncPolicy.syncOptions' $manifests/apps/Application-example-forge.yaml)"

  echo
  echo "== a forge somebody else runs renders NO object of any kind =="
  absent "an Application for the remote forge" "$manifests/apps/Application-example-remote-forge.yaml"
  absent "a directory for the remote forge"    "$manifests/example-remote-forge"
  check "and it is still declared, and still reported" "example-remote-forge" "$notRendered"

  echo
  echo "== NO FLEET ADDRESS REACHES ANY OBJECT: a class is a label, never a number =="
  for svc in "$FORGE_S" "$SRV_S" "$CACHE_S"; do
    check "$(basename $svc): type"           "ClusterIP" "$(y '.spec.type' $svc)"
    check "$(basename $svc): no pinned IP"   "null"      "$(y '.spec.clusterIP' $svc)"
    check "$(basename $svc): no LB address"  "null"      "$(y '.spec.loadBalancerIP' $svc)"
    check "$(basename $svc): no externalIPs" "null"      "$(y '.spec.externalIPs' $svc)"
    check "$(basename $svc): no nodePort"    "null"      "$(y '.spec.ports[0].nodePort' $svc)"
  done
  check "the forge's exposure is a class on a label" "public" "$(y '.metadata.labels."nixk3s.dev/exposure"' $FORGE_D)"

  echo
  echo "== every Application lands in the platform's project, at its own plane's destination =="
  for app in example-forge example-server example-cache example-controller example-nightly example-builder example-woodpecker example-pool; do
    check "$app project" "example-ci" "$(y '.spec.project' $manifests/apps/Application-$app.yaml)"
  done
  check "a control-plane destination"   "$CONTROL_NS" "$(y '.spec.destination.namespace' $manifests/apps/Application-example-server.yaml)"
  check "an execution-plane destination" "$EXEC_NS"   "$(y '.spec.destination.namespace' $manifests/apps/Application-example-builder.yaml)"

  echo
  echo "== the planes and the render split are countable =="
  check "control plane"        "example-cache example-controller example-forge example-nightly example-remote-forge example-server" "$controlPlane"
  check "execution plane"      "example-builder example-pool example-woodpecker" "$executionPlane"
  check "rendered by the grammar" "example-builder example-cache example-forge example-server example-woodpecker" "$byGrammar"
  check "rendered below it"       "example-controller example-nightly example-pool" "$directly"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the platform's promises" >&2
    exit 1
  fi
  echo "all render assertions hold"
  cp -rL $manifests $out
''
