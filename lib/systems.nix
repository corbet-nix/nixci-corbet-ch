# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The cluster catalogue: what a continuous-integration platform can run. Five groups, because the
# platform genuinely contains five kinds of thing and flattening them would make the model lie:
#
#   `forges`       where the CODE lives, and the identity the rest of the platform logs in through.
#   `servers`      the CI server: the web UI, the API, and the endpoint agents dial.
#   `caches`       where the ARTIFACTS land, and what serves them back.
#   `controllers`  software that reconciles runners into existence. A workload itself; the runners
#                  it creates are somebody else's pods, in another namespace.
#   `runners`      what actually EXECUTES a pipeline step. The only group in this file that runs
#                  code somebody pushed.
#
# ── THE PLACEMENT RULE ─────────────────────────────────────────────────────────────────────────
#
#   Does the thing take code and turn it into an artifact -- host it, trigger on it, build it, or
#   serve the result?
#     yes -> it belongs here
#     no  -> it belongs to whichever repository owns the thing it actually is
#
# "Has a pipeline" is NOT the test. Almost every project in a fleet is BUILT by this platform, and
# if being built by it were the test this catalogue would swallow every repository there is. The
# test is whether the thing IS the machinery. An application that ships from a pipeline is an
# application; the pipeline is ours.
#
# A GIT FORGE IS PART OF CI, and it is the first group in this file on purpose. A forge is CI's
# code-hosting half: it is where a pipeline's input comes from, it is what fires the trigger, and
# in every CI server worth the name it is also the identity provider -- the OAuth login IS the
# repository connection. Whether that forge is a workload in the same cluster or somebody else's
# service on the internet is a property of the forge, not a change of subject: see the `hosted`
# field and the reference entry below, which is exactly that case written down.
#
# ── THE CONTROL/EXECUTION AXIS, WHICH IS THE STRUCTURE OF THIS WHOLE REPOSITORY ────────────────
#
# Every entry carries a `plane`, and it is a property of the SOFTWARE rather than a decision a
# consumer makes:
#
#   `control`    the forge, the CI server, the cache, a runner controller, a schedule. NO REPO CODE
#                RUNS HERE. These hold the platform's credentials: the forge's OAuth client secret,
#                the server's admin token, the shared agent secret in full.
#   `execution`  every runner, and the warm builder. Pipeline steps run here -- as processes in the
#                pod for a warm runner, as pods it creates for a scheduling one. THIS IS WHERE
#                UNTRUSTED CODE EXECUTES, so it holds one narrow credential and nothing else.
#
# TWO CONSEQUENCES ARE ENCODED RATHER THAN ADVISED, and ../modules/cluster.nix is where they bite:
#
#   1. AN EXECUTION-PLANE ENTRY DECLARES NO PORTS. Not "declares none today" -- may not have any.
#      A runner dials out; nothing dials in. The app grammar this repository renders through emits
#      a Service only for an app with ports, so an execution-plane workload renders no Service at
#      all, and there is no option anywhere that could give it one.
#   2. A CREDENTIAL IS SCOPED TO A PLANE by which entry names it. The server entry reads four; the
#      runner entry that talks to it reads exactly one, and it is not the same object.
#
# ── ONE PIECE OF SOFTWARE IS NOT ONE VERSION, so no entry below carries one ─────────────────────
#
# For the same reason the sibling catalogues state: a version is a value, and a platform that runs
# two versions of a runner side by side while a migration lands is an ordinary Tuesday. An entry is
# a KIND of software; `version` belongs to the declaration -- and for a chart-delivered entry it
# does not belong to the declaration either, because the chart's own version is inside the objects
# the consumer delivers, and a copy out here would be a second pin nothing keeps honest.
#
# ── FIELDS ─────────────────────────────────────────────────────────────────────────────────────
#
# Shared by every group:
#
#   `plane`        `control` or `execution`. See above. Not declarable anywhere.
#   `delivery`     HOW the thing arrives:
#                    `image`     one container image; the app grammar renders it in full.
#                    `chart`     its vendor's Helm chart -- custom resource definitions, RBAC,
#                                webhooks and a Deployment, versioned together by people who are
#                                not us. Rendered one level below the grammar, as whole objects.
#                    `reference` it is not deployed here at all. Declaring it renders NOTHING and
#                                buys the interlocks. This is how a forge somebody else runs is
#                                named without pretending we run it.
#   `image`        container image REPOSITORY, no tag -- the tag is the declaration's `version`.
#                  `null` for a chart and for a reference, which render no container at all. Every
#                  image-delivered entry names one, and ../checks/clients-eval.nix asserts that: a
#                  null there would render `:<version>` with no repository in front of it.
#   `chart`        `{ repo, name }` for a chart delivery, deliberately WITHOUT a version.
#   `ports`        named container-side ports, `<name> = <number>`. A container port is a property
#                  of the software rather than of any network -- the one kind of number a public
#                  catalogue may carry. EMPTY on every execution-plane entry, structurally.
#   `primaryPort`  which of those the readiness probe watches.
#   `state`        directories this software writes that it cannot lose, as
#                  `<name> = { mountPath, readOnly }`. WHERE it lands inside the container is
#                  knowledge and lives here; what BACKS it is a value and comes from the
#                  declaration. Every one of these must be backed or the declaration is refused.
#   `caches`       directories this software writes that are RECONSTRUCTIBLE, as
#                  `<name> = { mountPath, env }`. The difference from `state` is not size and not
#                  speed: losing one of these costs time and losing `state` costs data, so backing
#                  a cache is OPTIONAL and backing state is not. `env` is the wiring that points
#                  the toolchain at the mount, emitted only when the cache is actually backed --
#                  a variable naming a directory nothing mounted is worse than no variable.
#   `env`          plain environment the software needs to be CORRECT. Never sizing, never
#                  credentials, never an address of anything outside the container.
#   `args`         entrypoint arguments in the same spirit.
#   `readiness`    probe shape and timing. `path = null` means a TCP connect.
#   `credentials`  `<role> = { env, required }`. The role is what the credential IS; which Secret
#                  holds it and under which key is a value. `env` is the variable it arrives in, or
#                  `null` when the software is chart-delivered and the SECRET NAME is what its
#                  values take -- in which case nothing here renders it and the module publishes it
#                  instead of pretending.
#   `note`         what the entry is, and every non-obvious thing about running it.
#
# Group-specific:
#
#   `hosted`         (forges) false for a forge we do not run. See `delivery = "reference"`.
#   `key`            (forges) the token a CI server identifies this forge by. Substituted into the
#                    `{FORGE}` placeholder in a server entry's variable names, which is how one
#                    server entry describes its coupling to any forge instead of one per pair.
#   `forges`         (servers) forge keys this server can authenticate against.
#   `forgeEnableEnv` (servers) the variable that switches a forge on, `{FORGE}`-templated. Rendered
#   `forgeUrlEnv`    (servers) the variable carrying the forge's URL, `{FORGE}`-templated. The
#                    VALUE is a fleet fact; the variable name is knowledge.
#   `agentPort`      (servers) which declared port a runner dials. The module builds the in-cluster
#                    address from it, so no consumer ever writes a cross-plane address by hand.
#   `artifacts`      (caches) what kind of artifact this cache holds.
#   `manages`        (controllers) runner keys this controller reconciles.
#   `serviceAccount` (controllers) the ServiceAccount its chart creates, `{RELEASE}`-templated on
#                    the declaration's own name. A runner in the other plane must name it to bind
#                    back -- and must never have to name its NAMESPACE, which is derived.
#   `steps`          (runners) WHERE a pipeline step runs:
#                      `process` as a process inside this pod, sharing its warm filesystem;
#                      `pod`     in a pod this runner creates per job.
#   `dials`          (runners) what it connects OUT to: a `server` declared here, a `forge`
#                    declared here, or something `external` this repository does not model.
#   `controller`     (runners) which controller must be present, or null.
#   `serverAddressEnv` (runners) the variable carrying the CI server's agent endpoint. The module
#                    COMPUTES that address from the declared server -- it is the one thing crossing
#                    from the execution plane to the control plane, and it crosses outbound.
#   `singleWriter`   (runners) true when the runner owns a warm store no second copy may write.
{ ... }:
{
  # ── Forges: where the code lives, and what the CI server logs in through ─────────────────────
  forges = {
    forgejo = {
      plane = "control";
      delivery = "image";
      hosted = true;
      key = "forgejo";
      image = "codeberg.org/forgejo/forgejo";
      chart = null;

      ports = { http = 3000; ssh = 2222; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/var/lib/gitea"; readOnly = false; };
        config = { mountPath = "/etc/gitea"; readOnly = false; };
        lfs = { mountPath = "/var/lib/gitea/data/lfs"; readOnly = false; };
      };
      caches = { };

      env = {
        # Correctness, not policy: these two must agree with the ports declared above, and the
        # image's own defaults do not (the SSH listener in particular).
        FORGEJO__server__HTTP_PORT = "3000";
        FORGEJO__server__SSH_LISTEN_PORT = "2222";
      };
      args = [ ];

      readiness = {
        path = "/api/healthz";
        initialDelaySeconds = 10;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 6;
      };

      credentials = { };

      note = ''
        A self-hosted git forge, and in this model the CODE-HOSTING HALF OF CI rather than a
        neighbouring service: it holds the repositories a pipeline builds, it fires the webhook
        that starts one, and it is the OAuth provider the CI server authenticates through. Those
        three are one relationship, not three integrations -- in every server in the `servers`
        group below, the login and the repository connection are literally the same credential.

        THE PATHS ARE ITS ANCESTOR'S AND THAT IS NOT A MISTAKE. `/var/lib/gitea` and `/etc/gitea`
        are what this fork kept when it forked, and a deployment that "corrects" them to the
        project's own name mounts three empty directories and comes up as a brand new forge with no
        repositories in it, reporting itself healthy.

        `config` IS STATE, WHICH IS THE SURPRISE IN THIS ENTRY. The process GENERATES its instance
        secret and its internal token on first run and writes them into the configuration file it
        also generates. So an unbacked config directory is not "a fresh config next boot" -- it is
        a new instance secret every restart, which invalidates every session and every token the
        forge ever issued, including the CI server's. That is why it is listed as state rather than
        being treated as configuration a consumer supplies.

        LFS GETS ITS OWN DIRECTORY, deliberately, rather than being a subdirectory of `data`: large
        objects and the repository metadata have different growth curves and want different backup
        boundaries, and once they are one mount that choice cannot be made any more.

        THE PORTS ARE THE ROOTLESS VARIANT'S. That image runs as an ordinary user and listens on
        3000 and 2222; the privileged variant supervises itself as root and takes 22 for SSH. The
        two are not interchangeable and the environment above is written for the first.

        ITS WEBHOOKS REFUSE PRIVATE HOSTS BY DEFAULT, which is the single most common reason a
        self-hosted forge and a self-hosted CI server sit next to each other and never trigger. The
        CI server's webhook target is a cluster-internal name; the forge's outbound allow-list has
        to say so. That is policy rather than correctness -- it depends on who else can reach the
        forge -- so it is a value, and this note is where a consumer finds out it exists.
      '';
    };

    gitea = {
      plane = "control";
      delivery = "image";
      hosted = true;
      key = "gitea";
      image = "gitea/gitea";
      chart = null;

      ports = { http = 3000; ssh = 2222; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/var/lib/gitea"; readOnly = false; };
        config = { mountPath = "/etc/gitea"; readOnly = false; };
        lfs = { mountPath = "/var/lib/gitea/data/lfs"; readOnly = false; };
      };
      caches = { };

      env = {
        GITEA__server__HTTP_PORT = "3000";
        GITEA__server__SSH_LISTEN_PORT = "2222";
      };
      args = [ ];

      readiness = {
        path = "/api/healthz";
        initialDelaySeconds = 10;
        periodSeconds = 10;
        timeoutSeconds = 5;
        failureThreshold = 6;
      };

      credentials = { };

      note = ''
        The forge the entry above was forked from. It is here for a reason beyond completeness: it
        is the proof that the group is a GROUP. Everything the CI servers below need from a forge
        -- an OAuth client, a URL, a webhook -- they need from either of these, and the only thing
        that changes between them is the `key` this file records and the prefix on the environment
        variable scheme.

        Everything in the forked entry's note applies here, including the config-is-state finding
        and the rootless port pair, because both are properties this fork inherited unchanged.
      '';
    };

    github = {
      plane = "control";
      delivery = "reference";
      hosted = false;
      key = "github";
      image = null;
      chart = null;

      ports = { };
      primaryPort = null;
      state = { };
      caches = { };
      env = { };
      args = [ ];
      readiness = null;
      credentials = { };

      note = ''
        A forge somebody else runs. DECLARING IT RENDERS NOTHING -- no Deployment, no Service, no
        Application at all -- and that is the entire point of the `reference` delivery: a forge is
        part of CI whether or not the forge is ours, so the model has to be able to name one it
        does not deploy, without pretending to deploy it and without a second concept for the
        remote case.

        WHAT THE DECLARATION BUYS is everything except the objects. A runner that serves this forge
        can name it and be checked against it; a CI server can authenticate against it with the
        same four variables it would use for a self-hosted one; the platform's own report can say
        which forges it is wired to. Refusing to model it would not make the dependency go away, it
        would only make it invisible.

        IT CARRIES NO CREDENTIAL HERE. The token a runner uses to register against this forge is
        the RUNNER's credential, named on the runner's own declaration in the execution plane. The
        OAuth client a CI server uses is the SERVER's, named in the control plane. Neither belongs
        to the forge entry, and a shared one here would be the first crack in the plane split.

        THIS ENTRY WILL NOT GROW STATE, PORTS OR A PROBE. The module refuses all of them on a
        reference, because each would be a claim about a machine this repository does not run.
      '';
    };
  };

  # ── Servers: the web UI, the API, and the endpoint agents dial ───────────────────────────────
  servers = {
    crow = {
      plane = "control";
      delivery = "image";
      image = "codefloe.com/crowci/crow-server";
      chart = null;

      forges = [ "forgejo" "gitea" "github" ];
      forgeEnableEnv = "CROW_{FORGE}";
      forgeUrlEnv = "CROW_{FORGE}_URL";
      agentPort = "grpc";

      ports = { http = 8000; grpc = 9000; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/var/lib/crow"; readOnly = false; };
      };
      caches = { };

      env = {
        # Correctness: the listeners must agree with the ports declared above.
        CROW_SERVER_ADDR = ":8000";
        CROW_GRPC_ADDR = ":9000";
      };
      args = [ ];

      readiness = {
        # A TCP CONNECT, AND IT IS WEAKER THAN WHAT THIS SERVER CAN ANSWER. It serves an HTTP
        # health endpoint; the path differs between this fork and its upstream, and a catalogue
        # that guessed one would produce a workload that never becomes ready for a reason nobody
        # would look for. Said out loud rather than left as a silently weaker default: a consumer
        # that knows the path merges the better probe onto the rendered Deployment.
        path = null;
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = {
        forgeClient = { env = "CROW_{FORGE}_CLIENT"; required = true; };
        forgeSecret = { env = "CROW_{FORGE}_SECRET"; required = true; };
        agentSecret = { env = "CROW_AGENT_SECRET"; required = true; };
        adminToken = { env = "CROW_ADMIN_TOKEN"; required = false; };
      };

      note = ''
        A CI server: the web UI, the REST API, and the gRPC endpoint agents dial. It reads
        pipelines out of a repository, decides what to run, and hands the work to whatever is
        connected. IT RUNS NO PIPELINE STEP ITSELF, which is the whole reason it can sit in the
        control plane holding the platform's credentials.

        TWO PORTS, TWO AUDIENCES, ONE WORKLOAD. The HTTP port is for people and for the forge's
        webhooks; the gRPC port is for agents, and it is the endpoint the execution plane dials
        OUTBOUND. That direction is the load-bearing fact of this whole repository: nothing in the
        control plane ever opens a connection to a runner.

        THE FORGE COUPLING IS FOUR VARIABLES AND ONLY ONE OF THEM IS A VALUE. A switch that turns
        the forge on, a URL, an OAuth client id and an OAuth client secret. The first is knowledge
        and this module renders it; the second is a fleet fact and the consumer supplies it; the
        last two are credentials and arrive by reference. All four are named for the forge, which
        is why they are templated on `{FORGE}` rather than written out per pair.

        THE OAUTH CLIENT SECRET IS THE REASON THE PLANES EXIST. Whoever holds it can impersonate
        this server to the forge -- which means to every repository the forge holds. It unseals
        into the control plane and nowhere else, and the runner that this server hands work to
        holds nothing but the shared agent secret, in its own Secret object, in its own namespace.

        THE ADMIN TOKEN IS OPTIONAL AND IS NOT A LOGIN. It creates a machine account for the
        server's own API, which is how a platform provisions repository-scoped secrets without a
        browser. Optional because a platform that provisions by hand does not need one; named here
        because a platform that automates needs it and would otherwise put a human's session token
        in a Secret.

        ITS EMBEDDED DATABASE WRITES INTO THE `data` DIRECTORY, so a deployment that mounts nothing
        starts, works, and loses every build record, every repository activation and every stored
        secret at the next restart. Pointing it at a real database instead is a value, and it is
        the database tier's business rather than this repository's -- see the sibling that owns
        engines.
      '';
    };

    woodpecker = {
      plane = "control";
      delivery = "image";
      image = "woodpeckerci/woodpecker-server";
      chart = null;

      forges = [ "forgejo" "gitea" "github" ];
      forgeEnableEnv = "WOODPECKER_{FORGE}";
      forgeUrlEnv = "WOODPECKER_{FORGE}_URL";
      agentPort = "grpc";

      ports = { http = 8000; grpc = 9000; };
      primaryPort = "http";

      state = {
        data = { mountPath = "/var/lib/woodpecker"; readOnly = false; };
      };
      caches = { };

      env = {
        WOODPECKER_SERVER_ADDR = ":8000";
        WOODPECKER_GRPC_ADDR = ":9000";
      };
      args = [ ];

      readiness = {
        path = null;
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = {
        forgeClient = { env = "WOODPECKER_{FORGE}_CLIENT"; required = true; };
        forgeSecret = { env = "WOODPECKER_{FORGE}_SECRET"; required = true; };
        agentSecret = { env = "WOODPECKER_AGENT_SECRET"; required = true; };
      };

      note = ''
        The server the entry above forked from, and the second entry that makes this a group rather
        than a vendor with a wrapper. Same two ports, same two audiences, same four-variable forge
        coupling under a different prefix, same embedded-database-in-`state` finding.

        NO ADMIN TOKEN ROLE, and the absence is recorded rather than copied across. Its
        administrator list is a configuration value naming accounts, not a credential; a role
        declared here that the software does not read would render a `secretKeyRef` into a variable
        nothing looks at, which is the failure mode a catalogue exists to prevent.
      '';
    };
  };

  # ── Caches: where the artifacts land, and what serves them back ──────────────────────────────
  caches = {
    nar-http = {
      plane = "control";
      delivery = "image";
      image = "nginx";
      chart = null;

      artifacts = "nix-store";

      ports = { http = 80; };
      primaryPort = "http";

      state = {
        # READ-ONLY, AND THAT IS KNOWLEDGE RATHER THAN CAUTION -- see the note.
        store = { mountPath = "/usr/share/nginx/html"; readOnly = true; };
      };
      caches = { };

      env = { };
      args = [ ];

      readiness = {
        # The one honest health check for this workload: the file that MAKES a directory a binary
        # cache. A probe on `/` would pass on an empty directory, which is precisely the failure
        # (the mount did not land) that has to be caught.
        path = "/nix-cache-info";
        initialDelaySeconds = 3;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = { };

      note = ''
        A binary cache with no application in it: an ordinary static HTTP server pointed at a
        directory of build outputs. It is in this catalogue because a cache is the third thing a CI
        platform is made of -- code goes in, artifacts come out, and something has to hold them --
        not because it is interesting software.

        THIS WORKLOAD IS THE READ FACE AND ONLY THE READ FACE. The write face is a filesystem path
        that whoever builds copies into, signing as it goes. So the cache has two consumers with
        two completely different postures, and this entry is the one that must never be able to
        modify a byte: the store mount is read-only in the catalogue, not in the declaration, so a
        consumer cannot make it writable by supplying a different value.

        THE SIGNING KEY NEVER COMES NEAR IT. Signatures are made by the builder at push time; this
        workload serves bytes and verifies nothing. A cache server holding a signing key is a cache
        server that can rewrite history, and there is no reason for it to hold one.

        THE SAME DIRECTORY IS MOUNTED READ-WRITE BY A BUILDER IN THE OTHER PLANE. That is the one
        place the two planes touch through the filesystem instead of through the network, and it is
        deliberate: a push into a directory needs no API, no token service and no inbound port on
        the runner. It is also the one relationship in this repository whose two halves are two
        separate declarations -- the module does not join them, because both halves are values.

        AN EMPTY CACHE IS INDISTINGUISHABLE FROM A BROKEN MOUNT except by the probe above, which is
        why the probe is the entry's most load-bearing field. Nix asks for `nix-cache-info` first
        and treats a 404 as "this is not a cache", so a client of an unmounted cache silently falls
        back to building everything -- slowly, correctly, and with no error anywhere.
      '';
    };

    attic = {
      plane = "control";
      delivery = "image";
      image = "ghcr.io/zhaofengli/attic";
      chart = null;

      artifacts = "nix-store";

      ports = { http = 8080; };
      primaryPort = "http";

      state = { };
      caches = { };

      env = { };
      args = [ ];

      readiness = {
        path = null;
        initialDelaySeconds = 5;
        periodSeconds = 10;
        timeoutSeconds = 3;
        failureThreshold = 6;
      };

      credentials = {
        serverToken = { env = "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64"; required = true; };
      };

      note = ''
        The other shape a binary cache comes in, and it is here to keep the group from collapsing
        into one file server. Instead of a directory somebody copies into, it is a service with an
        API: clients push over HTTP with a TOKEN, it deduplicates what it stores, and it can expire
        what nothing references any more.

        THE INTERESTING DIFFERENCE IS THE CREDENTIAL, NOT THE STORAGE. In the entry above, pushing
        means holding the store's signing key -- one key, no expiry, and anyone who has it can sign
        anything for every consumer of that cache forever. Here the server holds one signing secret
        and MINTS scoped tokens from it, so a builder can be given the ability to push to one cache
        and nothing else. That is the whole argument for this shape, and it is a control-plane
        argument: the minting secret lives with the server, and the execution plane receives a
        derived token.

        `state` IS EMPTY AND THAT IS THE DESIGN. Its chunk store and its database are both outside
        this workload in every deployment worth running -- object storage for the chunks, a real
        engine for the metadata -- so there is nothing container-local that must survive a restart.
        Which engine, and where the bucket is, are values; the engine itself belongs to the
        database tier's catalogue, not to this one.

        ITS CONFIGURATION IS A FILE RATHER THAN ENVIRONMENT, which is why `env` is empty here while
        the entries above carry correctness variables. The file names the listen address, the
        storage backend and the database, and it is supplied by the consumer -- the one variable
        this entry does record is the secret the tokens are signed with, because that is a
        credential and belongs in a Secret rather than in a config file committed to git.

        ITS PUBLISHED IMAGE CARRIES NO VERSION TAGS AT ALL, and this is the one thing about the
        entry that costs an afternoon if it is not written down. The repository exists and is
        populated -- around a hundred and seventy tags at the last run of
        ../experiments/verify-upstream-coordinates.sh -- and every one of them is a COMMIT HASH.
        There is no `latest` and there is no release-shaped tag to guess, so the `version` on a
        declaration of this entry is a commit, chosen deliberately. Which is an unusually literal
        demonstration of why no entry in this catalogue carries a version of its own: for this one
        there is no such thing as "the" version to record.
      '';
    };
  };

  # ── Controllers: software that reconciles runners into existence ─────────────────────────────
  controllers = {
    arc = {
      plane = "control";
      delivery = "chart";
      image = null;

      chart = {
        repo = "oci://ghcr.io/actions/actions-runner-controller-charts";
        name = "gha-runner-scale-set-controller";
      };

      manages = [ "gha-scale-set" ];

      # `{RELEASE}` is the declaration's own name. A runner in the OTHER plane has to name this
      # account to bind back to it, and must never have to name its namespace -- that is derived
      # from this entry's plane, which is the point of the whole cross-plane binding.
      serviceAccount = "{RELEASE}-gha-rs-controller";

      ports = { };
      primaryPort = null;
      state = { };
      caches = { };
      env = { };
      args = [ ];
      readiness = null;
      credentials = { };

      note = ''
        A controller that turns a declared runner pool into ephemeral runner pods and removes them
        again when the job ends. IT IS A CONTROL-PLANE WORKLOAD WHOSE BLAST RADIUS IS THE EXECUTION
        PLANE, which is the most easily-missed thing in this catalogue: it runs no repo code, it
        holds no registration token, and it creates every pod that does.

        SO IT SITS IN ONE PLANE AND ACTS ON THE OTHER, and the binding that permits that is a role
        binding in the execution namespace naming this controller's ServiceAccount at its
        control-plane home. That is why `serviceAccount` is recorded here rather than left to a
        consumer: the account name is the chart's, derived from the release name, and a runner pool
        that names the wrong one fails by never being reconciled -- the objects exist, nothing is
        Degraded, and no runner ever appears.

        IT SHIPS CUSTOM RESOURCE DEFINITIONS, so it is chart-delivered and its Application carries
        server-side apply and server-side diff. That is a hard limit rather than a preference:
        definitions of this size overrun the 262144-byte annotation a client-side apply keeps the
        last-applied state in, and the apply simply fails. Server-side diff comes with it, because
        comparing a client-side reconstruction of a large resource against what the API server
        actually holds produces permanent phantom drift.

        ITS WATCH IS CLUSTER-WIDE by default, which is what makes one controller enough for every
        pool in the platform, and also what makes moving it between namespaces harmless to the
        pools it already manages.
      '';
    };
  };

  # ── Runners: the only group in this file that runs code somebody pushed ──────────────────────
  runners = {
    crow-agent = {
      plane = "execution";
      delivery = "image";
      image = "codefloe.com/crowci/crow-agent";
      chart = null;

      steps = "process";
      dials = "server";
      controller = null;
      singleWriter = true;
      serverAddressEnv = "CROW_SERVER";

      # STRUCTURALLY EMPTY. Every execution-plane entry declares no ports, so no Service is ever
      # rendered for one -- see this file's header and ../modules/cluster.nix.
      ports = { };
      primaryPort = null;

      state = {
        workspaces = { mountPath = "/workspaces"; readOnly = false; };
      };

      caches = {
        nix = { mountPath = "/nix"; env = { }; };
        cargo = { mountPath = "/caches/cargo"; env.CARGO_HOME = "/caches/cargo"; };
        sccache = { mountPath = "/caches/sccache"; env.SCCACHE_DIR = "/caches/sccache"; };
        ccache = { mountPath = "/caches/ccache"; env.CCACHE_DIR = "/caches/ccache"; };
        go = {
          mountPath = "/caches/go";
          env = { GOMODCACHE = "/caches/go/mod"; GOCACHE = "/caches/go/build"; };
        };
        npm = { mountPath = "/caches/npm"; env.npm_config_cache = "/caches/npm"; };
        uv = { mountPath = "/caches/uv"; env.UV_CACHE_DIR = "/caches/uv"; };
        bun = { mountPath = "/caches/bun"; env.BUN_INSTALL_CACHE_DIR = "/caches/bun"; };
        deno = { mountPath = "/caches/deno"; env.DENO_DIR = "/caches/deno"; };
      };

      env = {
        CROW_BACKEND = "local";
        CROW_BACKEND_LOCAL_TEMP_DIR = "/workspaces";
      };
      args = [ ];

      readiness = null;

      credentials = {
        agentSecret = { env = "CROW_AGENT_SECRET"; required = true; };
      };

      note = ''
        THE WARM BUILDER. Pipeline steps run as PROCESSES INSIDE THIS POD, sharing its filesystem
        and therefore its caches -- which is the entire reason this shape exists. A pod-per-step
        runner starts cold every time: a fresh store, an empty registry, nothing compiled. This one
        starts where the last build finished.

        WHICH MEANS IT RUNS UNTRUSTED CODE WITH THIS POD'S IDENTITY, and everything else about the
        entry follows from that sentence. It declares no ports, so nothing can reach it. It holds
        exactly one credential -- the shared secret it authenticates to the server with -- and it
        is a different Secret object from the server's, in a different namespace, so the forge
        OAuth secret and the admin token are not merely unmounted here, they are unreachable. A
        build secret that a particular pipeline needs is handed to that pipeline BY THE SERVER, at
        run time, and never mounted on the runner: otherwise every repository's CI can read every
        other repository's deploy key.

        IT IS THE SINGLE WRITER OF ITS WARM STORE, and this is the failure worth knowing before it
        happens rather than after. Two processes writing one package-manager store corrupt its
        database, and the corruption looks like an unrelated build failure days later. Nothing in
        this repository can render a second copy -- there is no replica option anywhere -- and
        declaring any state at all switches the rendered Deployment to replace-then-start rather
        than a rolling update, because a rolling update briefly runs two.

        `state` VERSUS `caches` IS THE REAL DISTINCTION IN THIS ENTRY. The workspace directory is
        state: it holds checkouts a running build is standing in, and yanking it mid-build fails
        the build. Everything under `caches` is reconstructible -- losing it costs a long first
        build and nothing else -- so backing them is optional, and the environment that points each
        toolchain at its mount is emitted ONLY when that cache is actually backed. A variable
        naming a directory nothing mounted is worse than no variable at all: the toolchain writes
        into the container's own filesystem and reports a cache hit rate that means nothing.

        THE SERVER ADDRESS IS COMPUTED, NOT CONFIGURED. The variable above is filled in by this
        module from the server this runner serves and the namespace that server's plane lives in.
        It is the only thing that crosses between the planes, it crosses outbound, and it is
        derived rather than supplied precisely so that nobody has to write a cross-plane address by
        hand and get it wrong in the safe-looking direction.
      '';
    };

    woodpecker-agent = {
      plane = "execution";
      delivery = "image";
      image = "woodpeckerci/woodpecker-agent";
      chart = null;

      steps = "process";
      dials = "server";
      controller = null;
      singleWriter = true;
      serverAddressEnv = "WOODPECKER_SERVER";

      ports = { };
      primaryPort = null;

      state = { };
      caches = { };

      env = {
        WOODPECKER_BACKEND = "local";
      };
      args = [ ];

      readiness = null;

      credentials = {
        agentSecret = { env = "WOODPECKER_AGENT_SECRET"; required = true; };
      };

      note = ''
        The agent the entry above forked from, recorded in the same process-backend shape so that
        the pair actually compares.

        THIS AGENT HAS SEVERAL BACKENDS AND THIS ENTRY RECORDS ONE. The backend decides where a
        step runs -- as a process here, as a container through a daemon socket, or as a pod it
        creates -- and they are not variations on a theme: they need different privileges,
        different volumes and different failure handling. The process backend is the one the warm
        shape depends on, so it is what is written down; a deployment that wants one of the others
        is declaring a different kind of workload and deserves its own entry rather than a flag.

        NO CACHES AND NO STATE RECORDED, unlike the fork above, and the emptiness is honest rather
        than lazy: which directories a warm process-backend agent should keep depends entirely on
        what the toolchain in its image is, and this catalogue has verified that mapping for the
        fork and not for this one. An entry that copied the other's mounts across would be
        asserting a layout nobody checked.
      '';
    };

    gha-scale-set = {
      plane = "execution";
      delivery = "chart";
      image = null;

      chart = {
        repo = "oci://ghcr.io/actions/actions-runner-controller-charts";
        name = "gha-runner-scale-set";
      };

      steps = "pod";
      dials = "forge";
      controller = "arc";
      singleWriter = false;
      serverAddressEnv = null;

      ports = { };
      primaryPort = null;
      state = { };
      caches = { };
      env = { };
      args = [ ];
      readiness = null;

      credentials = {
        # NO `env`: this is chart-delivered, so nothing here renders a container and the credential
        # is consumed by NAME through the chart's own values. The module publishes it rather than
        # pretending to inject it.
        forgeToken = { env = null; required = true; };
      };

      note = ''
        A pool of ephemeral runners for a remote forge's own CI system. One pool per repository,
        each job gets a fresh pod, and the pod is gone when the job ends.

        IT IS THE OTHER HALF OF A CROSS-PLANE PAIR. This is the execution-plane half; the
        controller that reconciles it lives in the control plane, and the two are bound by a role
        binding naming the controller's ServiceAccount at its own home. Declaring this without the
        controller is refused, because the failure otherwise is the worst kind: the objects apply
        cleanly, the delivery tool reports everything healthy, and no runner ever registers.

        THE POOL'S NAME IS A LABEL A WORKFLOW SELECTS ON, and it is unique per repository at the
        forge. Two pools cannot share a name for one repository, which makes replacing a pool a
        delete-then-create rather than a swap -- worth knowing before a migration, not during one.

        COLD BY CONSTRUCTION, and that is the trade rather than a defect: a fresh pod per job is
        the strongest isolation available here, and it is the right answer when the code being
        built is not yours. The warm entry above is the opposite trade, and a platform that runs
        both at once is running them for different repositories on purpose.

        ITS CREDENTIAL IS A REGISTRATION TOKEN FOR THE FORGE, and it belongs to this plane. Note
        what it is not: it is not the CI server's OAuth secret, and it is not shared with anything
        in the control plane. One narrow credential per pool is the whole reason a compromised job
        is a contained event.
      '';
    };

    container-agent = {
      plane = "execution";
      delivery = "chart";
      image = null;

      chart = {
        repo = "https://packagecloud.io/circleci/container-agent/helm";
        name = "container-agent";
      };

      steps = "pod";
      dials = "external";
      controller = null;
      singleWriter = false;
      serverAddressEnv = null;

      ports = { };
      primaryPort = null;
      state = { };
      caches = { };
      env = { };
      args = [ ];
      readiness = null;

      credentials = {
        agentToken = { env = null; required = true; };
      };

      note = ''
        A runner for a hosted CI service: it polls that service's control plane for work and runs
        each task as a pod in this cluster.

        `dials = "external"` IS THE POINT OF THIS ENTRY. Its control plane is neither a server in
        this catalogue nor a forge in it -- it is a vendor's, on the internet, and this repository
        models it as absence rather than inventing a group for it. So this runner names nothing it
        serves, and the module does not ask it to. Compare the remote forge entry, which is the
        same honesty applied to the other half of CI: the model names what it does not run instead
        of pretending the dependency is not there.

        IT DIALS OUT, LIKE EVERY RUNNER HERE. That is what makes it an execution-plane workload by
        the same rule as the rest, and what makes the plane split a property of the shape rather
        than of who the vendor is: nothing inbound, one credential, no control-plane secret.

        WHY A PLATFORM RUNS ONE OF THESE AT ALL, since it is the least self-hosted thing in the
        catalogue: because some repository's pipeline is written for that service and porting it is
        not free. Running several runner systems at once is a real state, not a transitional one,
        and a model that could only express one would be a model people work around.
      '';
    };
  };
}
