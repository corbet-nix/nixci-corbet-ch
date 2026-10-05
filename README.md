# nixci

**The machinery by which code becomes an artifact, declared: the forge it lives in, the server that
decides what runs, the runners that execute, and the cache that holds the results — split across a
control plane that holds the credentials and an execution plane where somebody else's code runs.**

It renders no Kubernetes object of its own. Everything expressible as an app is expressed in
[nixk3s](https://github.com/corbet-nix/nixk3s-corbet-ch)'s app grammar; what this repository adds
is the one thing that grammar cannot know — what a CI platform *is*, and which of its halves a
given piece of it belongs to.

## A git forge is part of CI

That is the organising idea, and it is worth stating before anything else because it is the one
people argue with. A forge is CI's **code-hosting half**: it holds the input, it fires the trigger,
and in every CI server described here it is also the identity provider — the OAuth login *is* the
repository connection, configured with one credential, inseparable by design.

The same is true of a forge somebody else runs. A platform that builds from a remote forge has
exactly the same relationship to it, and the only difference is who operates the machine. So this
repository models that too: a forge can be declared as a **reference**, which renders no object of
any kind and is still checked against by the servers and runners that depend on it. Refusing to
model it would not make the dependency go away — it would only make it invisible.

Full reasoning: [`studies/a-forge-is-cis-code-hosting-half.md`](studies/a-forge-is-cis-code-hosting-half.md).

## Repository placement

`lib.repositoryPolicy` (also `nixidyModules.repositoryPolicy`) supplies the
value-only `nixci.delivery` module. It generates the JSON consumed by
[`ccid forge`](https://github.com/corbet-libs/ccid/blob/main/docs/repository-policy.md).
The CI declaration selects the primary forge. Repositories declare one or more
locations, attribute constraints, ordered clone sources and execution fallbacks.
GitHub, Forgejo, GitLab, Bitbucket and other Git forges use the same policy surface.

```nix
nixci.delivery = {
  freeOnly = true;
  forges.upstream = { kind = "gitlab"; url = "https://git.example.org"; };
  ci.local = {
    driver = "crow";
    forge = "upstream";
    execution = "owned";
    capabilities = [ "linux-x86_64" ];
  };
  repositories.widget = {
    ci = "local";
    visibility = "private";
    sensitive = true;
    locations.upstream = "team/subgroup/widget";
  };
};
# config.nixci.delivery.json: validated ccid policy
# config.nixci.delivery.primaryUrls.widget: runner registration URL
```

No credentials or provider APIs are involved in evaluation. The module does not
create repositories or start mirrored CI triggers. Changing a writable primary
requires a reviewed policy change; execution failover cannot promote it. Free
hosted execution requires public, nonsensitive source. `freeOnly` defaults to true
and rejects paid declarations. Collected cqlt evidence remains distinct from
declared attributes. `checks/repository-policy.nix` covers valid four-forge
placement and invalid placement, privacy, cost, promotion and coverage inputs;
the `policy` ccid selector checks its generated JSON with the real runtime.

`nixci.delivery.admission` optionally supplies `memoryReserveMiB` and
`ioFullAvg10`. Both default to unset. `admissionEnvironment` renders the
corresponding ccid runtime variables, for a consumer to pass to its worker.
I/O admission uses Linux **full** PSI over ten seconds, rejects unavailable
measurements when enabled, and never treats swap occupancy as pressure.

## A forge-agnostic scheduler: Argo

`nixidyModules.argo` (`modules/argo.nix`) declares Argo Workflows and Argo Events as two nixidy
applications from the vendor Helm charts, pinned by version and content hash. A forge-bound CI
server needs the forge to start a job; this scheduler does not: templates live in the cluster and
triggers are cron, generic webhooks or the API. Options live under `nixci.argo` (`workflows.enable`,
`events.enable`, chart versions and hashes, namespaces, resources, an EventBus in the workflow
namespace). The argo-server Service is ClusterIP only. `examples/argo/values.nix` is rendered by the
`argo-render` check.

## The control/execution axis

The defining structure. One question decides everything: **does repo code run here?**

| | control plane | execution plane |
|---|---|---|
| holds | the forge, the CI server, the cache, the runner controllers, the schedules | every runner, and the warm builder |
| runs | nothing anybody pushed | pipeline steps — as processes in the pod, or as pods it creates |
| credentials | the forge's OAuth client secret, the admin token, the shared agent secret **in full** | one narrow credential, in its own object |
| reachable | yes, as a class — a forge and a server are for people | **no. Nothing. Every runner dials out** |

**This is structural, not documented.** A reader should not be able to accidentally give an
execution-plane workload an inbound address or a control-plane secret, so:

1. **A workload's plane is not declarable.** It is read from the catalogue, because which plane a
   piece of software belongs in is a property of the software.
2. **There is no `namespace` option anywhere.** A workload's namespace is its plane's namespace, and
   the two are defaultless platform options that must differ. A runner cannot be moved next to the
   server by editing one line, because there is no line.
3. **An execution-plane workload has no `exposure` and no `slot` option at all.** Writing either is
   *"the option does not exist"*. And no execution-plane catalogue entry declares a port — which is
   what makes the grammar render **no Service** for one, since it emits a Service only for an app
   with ports.
4. **A Secret name may not appear on both planes.** Eval fails, naming the Secret and both sides. A
   CI server and the runner it hands work to share one secret *value* and must never share one
   Secret *object*.
5. **The only thing that crosses is an outbound dial, and this module computes it.** A runner's
   server address is derived from the server it serves, the control namespace and the port that
   server's entry says agents dial. Nobody writes a cross-plane address by hand, so nobody writes one
   pointing the wrong way.

`checks/cluster-eval.nix` asserts (1)–(5) — including the ones that are *unknown options* rather
than refusals, in a set called `structurallyImpossible`, so re-adding an option would fail the check.
`checks/cluster-render.nix` then reads the rendered manifests back and asserts the two absences on
the bytes: no Service anywhere in the execution namespace, and no control-plane Secret name in any
execution-plane manifest.

## What this is

A catalogue and one option namespace, `nixci`, like every repository in this family.

**[`lib/systems.nix`](lib/systems.nix)** — what the platform can run, in five groups because it
genuinely contains five kinds of thing: `forges` (where the code lives), `servers` (the CI server),
`caches` (where artifacts land), `controllers` (software that reconciles runners into existence) and
`runners` (the only group that runs code somebody pushed). Each entry carries its own knowledge:
which ports it listens on, which directories it writes and *which of those it cannot lose*, how long
a cold start takes, which variable each credential arrives in, and which plane it belongs to.

**No vendor is hardcoded as the only option.** Two forges plus a reference, two CI servers, two
shapes of cache, and four runner systems — because running several runner systems at once is a real
state rather than a transitional one: a warm builder for the repositories that benefit from a hot
cache, an ephemeral pool for the ones whose pipelines are written for somebody else's CI.

**[`lib/clients.nix`](lib/clients.nix)** — what a person installs on a **host** to drive this
platform: `forge`, `ci` and `cache` clients. **It is empty, and the emptiness is a state rather than
a gap.** The policy module, both host backends and the checks all exist and resolve; what this
repository does not do is decide *which* packages, because assigning a package to a repository
belongs to whoever owns the package set. Adding the first one is one attribute in one file.

```nix
# Composed into a nixidy environment ALONGSIDE nixk3s's app grammar.
# Every value below is a fleet fact the consumer supplies; this repository ships none of them.
nixci.platform = {
  controlNamespace   = "…";   # no default: the two planes ARE these two namespaces
  executionNamespace = "…";   # must differ, and eval fails if it does not
  project = "…";
  origin  = "nixci";
};

# The code-hosting half. One we run, one somebody else runs.
nixci.forges = {
  our-forge = { forge = "forgejo"; version = "…"; slot = N; exposure = "public";
                state = { data.hostPath = "…"; config.hostPath = "…"; lfs.hostPath = "…"; }; };
  their-forge.forge = "github";              # renders nothing at all, and is still declared
};

# The CI server: above the forge it logs in through, holding every credential.
nixci.servers.ci = {
  server = "crow"; version = "…"; slot = N + 1;
  forge = "our-forge"; forgeUrl = "https://…";
  credentials = {                             # by name, never by value
    forgeClient = { secret = "…"; key = "…"; };
    forgeSecret = { secret = "…"; key = "…"; };
    agentSecret = { secret = "…"; key = "…"; };
  };
};

nixci.caches.artifacts = { cache = "nar-http"; version = "…"; slot = N + 2;
                           state.store.hostPath = "…"; };   # mounted read-only; the catalogue says so

# THE EXECUTION PLANE. No exposure. No slot. No namespace. No Service.
nixci.runners.builder = {
  runner = "crow-agent"; version = "…";
  serves = "ci";                              # the address is DERIVED from this
  state.workspaces.hostPath = "…";            # mandatory: losing it fails a running build
  caches = { nix.hostPath = "…"; cargo.hostPath = "…"; };   # optional: losing it costs time
  credentials.agentSecret = { secret = "…"; key = "…"; };   # a DIFFERENT Secret from the server's
};
```

## It consumes the app grammar; it does not reimplement Kubernetes

`modules/cluster.nix` **defines into `nixk3s.apps`** and renders nothing itself. An image-delivered
workload declares an image, ports, state, secrets and probes in the grammar's own vocabulary, and the
grammar renders the Application, the Namespace, the Deployment and the Service. Import the grammar
alongside this module — it is a hard requirement, and a version of this module that quietly rendered
its own Deployments when the grammar was absent would be the second implementation this repository
exists to not have.

Neither flake is an input of the other for a consumer. `nixk3s` and `nixidy` are **checks-only**
inputs here, so `nix flake check` can render this module through the real grammar and assert the
manifests that come out.

**Two things the grammar cannot express**, and this repository says so rather than working around it
silently. It renders a Deployment for every app, unconditionally, from a required `image` — so it
cannot express a **chart delivery** (a controller ships as its vendor's chart: custom resource
definitions, RBAC, webhooks and a Deployment, versioned together by people who are not us) and it
cannot express a **schedule** (which is not a running process at all). Both land on the renderer's
own `applications.<name>` with their object text taken as a **value**. `nixci.renderedDirectly` lists
every workload that took that route, so the untyped side is *countable* — a boundary nobody measures
becomes the architecture.

Those two also carry **server-side apply and server-side diff**, and that is not a preference: a
controller's custom resource definitions are large enough that a client-side apply overruns the
262144-byte annotation Kubernetes keeps the last-applied state in, and the apply simply fails.

## A cache has two faces, and this repository renders one of them

The `nar-http` entry is a static HTTP server pointed at a directory of build outputs. It is the
**read** face. The write face is the same directory, mounted read-write by a builder in the other
plane, which signs as it pushes — so the store mount is `readOnly` **in the catalogue**, not in the
declaration, and there is no `readOnly` option on a backing anywhere in this module. A cache server
that could rewrite the artifacts it serves would be a cache server that can rewrite history, and it
has no reason to hold a signing key at all.

The other entry is the token-minting shape, where a builder is given a scoped push token instead of
a copy of the signing key. That difference is a control-plane argument, which is why both live here.

## `state` and `caches` are two different things

The distinction is not size and not speed:

| | lose it and | backing it is |
|---|---|---|
| `state` | a running build fails, or data is gone | **mandatory** — eval fails if it is unbacked |
| `caches` | the next build is slow | **optional** |

And the wiring follows the backing: each cache carries the environment that points its toolchain at
the mount (`CARGO_HOME`, `GOMODCACHE`, `SCCACHE_DIR`, …), emitted **only when that cache is actually
backed**. Emitting it unconditionally produces the worst available outcome — the toolchain writes
into the container's own filesystem, reports healthy cache statistics, and throws all of it away at
the next restart, which is slower than having no cache at all because nothing tells you.
[`studies/a-warm-runner-is-a-single-writer.md`](studies/a-warm-runner-is-a-single-writer.md).

## The interlocks

Guards over *relationships*, all of which fail eval rather than warning, because each of them has a
failure mode where every object applies cleanly and the delivery tool reports the whole platform
healthy:

- a **CI server whose forge is not declared** — it comes up, serves a login page, and every sign-in
  fails at the redirect;
- a **runner pool with no controller** — the objects apply, nothing is Degraded, and no runner ever
  registers, because nothing is watching the resource that describes the pool;
- a **runner dialling a server that is not declared** — nothing else could supply that address,
  since this module derives it;
- an **external runner naming something to serve** — its control plane is a vendor's service on the
  internet, and a reference resolving to nothing reads as wiring that exists;
- a **forge ordered above the CI server that logs in through it** — an ordering is read by people,
  and a subsystem reads correctly only when the thing that is depended upon comes first. The refusal
  names both workloads and both numbers, because nothing here will move either one.

Which **range** those numbers may come from is a different question, answered by nixk3s's band model.
`nixci.platform.origin` is the one switch that hands the platform's slots to it.

## Public mechanism, private layout

**No address, no slot number, no namespace value, no node path, no hostname, no domain and no
repository name appears anywhere in this repository.** Every one of those is a fleet fact and is a
parameter the consumer supplies. `nixci.platform.controlNamespace` and `.executionNamespace` have
*no default* and evaluation fails naming them the moment a workload is declared: what a cluster calls
its CI namespaces is a value, and a default here would be this repository deciding it.

What is public is the mechanism: the catalogue, the knowledge in it, the render, the two planes and
the guards.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | `nixidyModules` (cluster), `nixosModules`/`systemManagerModules` (clients), `lib.*`, `checks`. |
| `lib/systems.nix` | The cluster catalogue: forges, servers, caches, controllers, runners — and the knowledge that makes each run, including which plane it belongs to. |
| `lib/clients.nix` | The client catalogue: three groups, declared and empty. This repository claims no host package. |
| `modules/cluster.nix` | The cluster surface: translates declarations into `nixk3s.apps`, renders the two things that grammar cannot express one level below it, and makes the plane separation structural. |
| `modules/clients.nix` | Client policy and the published package lists. Also *is* the Arch backend. |
| `modules/nixos.nix` | The NixOS backend: force-evaluates every attribute and installs it. |
| `checks/` | Three checks that really evaluate — see below. |
| `examples/all/values.nix` | Placeholder values that make the render check real. Nothing in it is a real fleet fact. |
| `experiments/verify-upstream-coordinates.sh` | Every image repository and chart coordinate, checked against the registry that serves it. |
| `studies/` | Written-up findings that changed a decision here. |

## Checks

`nix flake check` runs three, and none of them is syntax-only.

**`clients-eval`** evaluates the client policy module through `lib.evalModules` — an empty selection
resolves to empty lists on every plane a backend reads, every group is declared and refuses a name,
and a **tripwire** fails the moment a package is assigned, so the invariants that are vacuous today
cannot stay vacuous unnoticed. Then the cluster catalogue's own integrity, which is where all the
content actually is: that no execution-plane entry declares a port; that the runners are the
execution plane and nothing else is; that a chart entry carries coordinates and nothing
container-shaped; that a reference entry is empty of everything that would render an object; that no
entry carries a version anywhere; that state and cache names never collide; that every cache's
environment points inside its own mount; that every server names forge kinds that exist and the port
its agents dial; that every controller names runners that claim it back; and that only a runner which
dials a CI server names a server-address variable.

**`cluster-eval`** renders the module through the real grammar and the real renderer, in both
directions. The floor (an empty platform defines no app at all), the control (a complete platform on
both planes), and then twenty-six declarations that must each be **refused** — the cross-plane
Secret by both routes, one namespace for both planes, every interlock above, a reference carrying
state or a credential, a chart naming a version, an unbacked state directory, a cache key the
catalogue does not hold, a credential role the software does not read, two workloads on one slot, a
namespace anchored below the grammar — against a control that must render. Plus five that are not
refusals at all but **unknown options**, which is the whole claim of the design. Three refusals have
their *message* asserted by content, because `tryEval` can only say *that* something was refused.

**`cluster-render`** parses the manifests the platform actually produced and asserts them field by
field: that a plane decided every namespace; that both namespaces are anchored by grammar-rendered
workloads and carry the annotation that stops them being cascade-deleted; that the forge's SSH
listener agrees with the port it declares and its config directory is mounted where it writes; that
the cache's store mount is read-only; that a backed cache is mounted *and* wired while an unbacked
one is neither; that the runner's server address is the derived one; that server-side apply is on the
directly-rendered kinds and on neither ordinary workload; that no Service carries a pinned address,
an external IP or a node port; and the two central absences — no Service in the execution namespace,
and no control-plane Secret name in any execution-plane manifest.

## Status

**Pre-alpha.** The catalogue's knowledge is extracted from a production platform that runs a
self-hosted forge, a CI server with a warm builder, a signed artifact cache, a runner controller with
ephemeral pools, and a vendor's container agent — all of it across exactly the two namespaces this
model describes. This repository has not yet replaced that platform's own declarations.

The **client plane is deliberately empty**: the surface exists, the backends exist, and no package is
claimed.

## Related projects

Part of the same independently-usable module family:
[nixk3s](https://github.com/corbet-nix/nixk3s-corbet-ch) (the app grammar this consumes, and the
band model its slots answer to),
[nixdb](https://github.com/corbet-nix/nixdb-corbet-ch) (the database tier — the engine a CI server
points at when it outgrows its embedded one, and the repository that owns every database client), and
[nixapps](https://github.com/corbet-nix/nixapps-corbet-ch) (the ordinary self-hosted applications
that ship *from* this platform rather than being part of it).

## Licence

Outbound licence is `MIT OR Apache-2.0`. See `LICENSE-MIT` and `LICENSE-APACHE`; every source file carries `SPDX-License-Identifier: MIT OR Apache-2.0`.
