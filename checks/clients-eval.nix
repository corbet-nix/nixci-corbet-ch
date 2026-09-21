# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates modules/clients.nix for real against `lib.evalModules` and asserts what it resolves,
# plus the integrity of both catalogues and the direction of the reference between them.
#
# Here for the reason every sibling states for its own version of this file: `nix flake check` does
# not evaluate `nixosModules`/`systemManagerModules` on its own, so a green check on this repository
# without it would prove nothing but flake syntax.
#
# ── WHAT IT PROVES TODAY, GIVEN AN EMPTY CLIENT CATALOGUE ──────────────────────────────────────
#
# Two of the sections below are real and one quantifies over an empty set, and the file says which
# is which rather than reading as though all of it were exercised:
#
#   - REAL: the resolution path terminates -- every plane a backend reads is published and empty;
#     every group is declared and refuses a name; and the CLUSTER catalogue's integrity, which is
#     where all the content in this repository actually is.
#   - EMPTY-SET: the pacman/AUR invariant and the nixpkgs-null handling. They hold vacuously and
#     they are kept, because the day an entry lands they become the checks that matter and
#     rediscovering them then is how a converge gets broken.
#
# THE TRIPWIRE is the point of the file in the meantime: `the client catalogue claims no package`
# fails the moment somebody adds one, so the empty-set assertions above cannot stay vacuous without
# anybody noticing, and this header cannot stay true without being edited.
#
# Deliberately pkgs-FREE beyond `pkgs.emptyFile` for the derivation shell. Every question here is a
# question about NAMES and LISTS. Whether a name is in a repository today, and whether a nixpkgs
# attribute still forces, are facts about the world that change without this repository changing --
# see ../experiments/verify-upstream-coordinates.sh.
{ pkgs, lib ? pkgs.lib }:
let
  clients = import ../lib/clients.nix { };
  systems = import ../lib/systems.nix { };

  evalWith = selection: (lib.evalModules {
    modules = [ ../modules/clients.nix { nixci.clients = selection; } ];
  }).config.nixci.clients;

  empty = evalWith { };

  clientGroups = lib.attrNames clients;
  clientEntries = lib.concatMap (g: lib.attrValues clients.${g}) clientGroups;

  # `evalModules` is lazy: `tryEval` alone forces only WHNF (the attrset exists), never the
  # type-checked value inside. `deepSeq` forces through, which is what actually runs the
  # listOf-enum merge that rejects a name.
  refuses = selection: group:
    (builtins.tryEval (builtins.deepSeq (evalWith selection).${group} true)).success == false;

  ## ---------------------------------------------------------------------
  ## The cluster catalogue's own integrity
  ##
  ## Structural facts the cluster module RELIES ON rather than checks per declaration: a shape that
  ## broke here would produce a module that type-checks and renders the wrong thing.
  ## ---------------------------------------------------------------------

  systemGroups = lib.attrNames systems;
  allEntries = lib.concatMap (g: lib.attrValues systems.${g}) systemGroups;
  entriesOfPlane = plane: lib.filter (e: e.plane == plane) allEntries;
  deliveredAs = d: lib.filter (e: e.delivery == d) allEntries;

  results = {
    # ── The client plane: the floor, which is real ────────────────────────────────────────────
    "an empty selection resolves to nothing selected" =
      empty.selected == [ ];

    "an empty selection produces empty lists on EVERY plane, not one populated by default" =
      empty.archPackages == [ ] && empty.aurPackages == [ ]
      && empty.nixosPackages == [ ] && empty.unavailableOnNixos == [ ]
      && empty.binaries == { };

    "every plane a backend reads is actually published" =
      lib.all (o: empty ? ${o})
        [ "selected" "archPackages" "aurPackages" "nixosPackages" "unavailableOnNixos" "binaries" ];

    "every catalogue group has a matching selection option on the module" =
      lib.all (g: empty ? ${g}) clientGroups;

    "all three kinds of client have a group, so none has to be invented later" =
      lib.sort (a: b: a < b) clientGroups == [ "cache" "ci" "forge" ];

    # THE TRIPWIRE. Every group is empty as a STATE: assigning a package to a repository is not this
    # repository's decision, so it claims none. The day one is assigned, this fails -- and the
    # assertions below it stop being vacuous, which is exactly when somebody has to read them.
    "the client catalogue claims no package, and every group refuses a name" =
      clientEntries == [ ]
      && refuses { forge = [ "anything" ]; } "forge"
      && refuses { ci = [ "anything" ]; } "ci"
      && refuses { cache = [ "anything" ]; } "cache";

    # ── The client plane: invariants that hold vacuously today ────────────────────────────────
    # One AUR name in a pacman list fails `pacman -S` ATOMICALLY and takes every unrelated package
    # in the same converge with it. Vacuous while the catalogue is empty; load-bearing the moment it
    # is not.
    "archPackages and aurPackages can never intersect" =
      lib.intersectLists empty.archPackages empty.aurPackages == [ ];

    "every entry names a pacman package, a command, and either a nixpkgs attribute or an explicit null" =
      lib.all
        (t: lib.isString (t.arch or null) && t.arch != ""
          && lib.isString (t.binary or null) && t.binary != ""
          && t ? nixpkgs && (t.nixpkgs == null || (lib.isString t.nixpkgs && t.nixpkgs != "")))
        clientEntries;

    # ── THE DIRECTION OF THE REFERENCE ────────────────────────────────────────────────────────
    # The cluster catalogue names software, ports and roles; it must never name a PACKAGE. If it
    # did, every reassignment of a package to another repository would break the platform -- and
    # packages get reassigned by somebody who is not reading that file.
    "no cluster catalogue entry names a client package, in any group" =
      lib.all (e: !(e ? arch) && !(e ? nixpkgs) && !(e ? binary)) allEntries;

    # ── The cluster catalogue's integrity ─────────────────────────────────────────────────────
    "the cluster catalogue holds exactly the five groups the module wires" =
      lib.sort (a: b: a < b) systemGroups
      == [ "caches" "controllers" "forges" "runners" "servers" ];

    "every entry names a plane and a delivery, and nothing else is a plane or a delivery" =
      lib.all (e: lib.elem e.plane [ "control" "execution" ]) allEntries
      && lib.all (e: lib.elem e.delivery [ "image" "chart" "reference" ]) allEntries;

    # THE STRUCTURAL CLAIM OF THIS WHOLE REPOSITORY, checked at the catalogue rather than at the
    # declaration: an execution-plane entry HAS no ports, so the app grammar cannot render a Service
    # for one however it is declared.
    "no execution-plane entry declares a port, so no runner can ever have an inbound address" =
      lib.all (e: e.ports == { }) (entriesOfPlane "execution")
      && entriesOfPlane "execution" != [ ];

    "the runners are the execution plane and nothing else is" =
      lib.all (e: e.plane == "execution") (lib.attrValues systems.runners)
      && lib.all (e: e.plane == "control")
        (lib.concatMap (g: lib.attrValues systems.${g})
          [ "forges" "servers" "caches" "controllers" ]);

    "every addressable entry names a primary port it actually declares" =
      lib.all
        (e: e.ports == { } || (e.primaryPort != null && (e.ports ? ${e.primaryPort})))
        allEntries;

    "a readiness probe only exists where there is a port to probe" =
      lib.all (e: e.readiness == null || e.ports != { }) allEntries;

    # An image entry is rendered by the grammar; a chart entry is not rendered at all, so anything
    # container-shaped on one would reach no object.
    "a chart entry carries chart coordinates and nothing container-shaped" =
      lib.all
        (e: e.chart != null && (e.chart ? repo) && (e.chart ? name) && !(e.chart ? version)
          && e.image == null && e.ports == { } && e.state == { } && e.caches == { }
          && e.env == { } && e.args == [ ] && e.readiness == null)
        (deliveredAs "chart");

    "a chart entry's credentials carry no environment variable, because nothing renders a container for it" =
      lib.all (e: lib.all (c: c.env == null) (lib.attrValues e.credentials)) (deliveredAs "chart");

    # A null repository here would render `:<version>` with no repository in front of it, which is
    # a pull error at the far end of a sync rather than an eval error here.
    "every image entry names an image repository, and no chart or reference names one" =
      lib.all (e: e.image != null) (deliveredAs "image")
      && lib.all (e: e.image == null) (deliveredAs "chart" ++ deliveredAs "reference");

    "an image entry's credentials all name the variable they arrive in" =
      lib.all (e: lib.all (c: c.env != null && c.env != "") (lib.attrValues e.credentials))
        (deliveredAs "image");

    # A reference renders nothing, so every field that would produce an object must be empty at the
    # catalogue level too -- not only refused per declaration.
    "a reference entry is empty of everything that would render an object" =
      lib.all
        (e: e.image == null && e.chart == null && e.ports == { } && e.state == { }
          && e.caches == { } && e.env == { } && e.args == [ ] && e.readiness == null
          && e.credentials == { })
        (deliveredAs "reference");

    "no entry carries a version anywhere, in any group" =
      lib.all (e: !(e ? version)) allEntries
      && lib.all (e: e.chart == null || !(e.chart ? version)) allEntries;

    "state and cache directory names never collide within one entry" =
      lib.all
        (e: lib.intersectLists (lib.attrNames e.state) (lib.attrNames e.caches) == [ ])
        allEntries;

    "every state directory names an absolute mount path and says whether it may be written" =
      lib.all
        (e: lib.all
          (s: lib.hasPrefix "/" s.mountPath && lib.isBool s.readOnly)
          (lib.attrValues e.state))
        allEntries;

    # A cache mount with no environment is legitimate (a package store the toolchain finds by path),
    # but a cache whose environment points outside its own mount is a directory nothing writes.
    "every cache's environment points inside the cache's own mount" =
      lib.all
        (e: lib.all
          (c: lib.all (v: lib.hasPrefix c.mountPath v) (lib.attrValues c.env))
          (lib.attrValues e.caches))
        allEntries;

    # ── The relationships between groups ──────────────────────────────────────────────────────
    "every server names forge kinds that exist, and the port its agents dial" =
      lib.all
        (e: lib.all (k: lib.any (f: f.key == k) (lib.attrValues systems.forges)) e.forges
          && (e.ports ? ${e.agentPort}))
        (lib.attrValues systems.servers);

    "a server's forge variables are all templated on the forge, so one entry describes any pairing" =
      lib.all
        (e: lib.hasInfix "{FORGE}" e.forgeEnableEnv && lib.hasInfix "{FORGE}" e.forgeUrlEnv)
        (lib.attrValues systems.servers);

    "exactly one forge in the catalogue is one somebody else runs, and it is the reference" =
      lib.all (f: f.hosted == (f.delivery != "reference")) (lib.attrValues systems.forges)
      && lib.length (lib.filter (f: !f.hosted) (lib.attrValues systems.forges)) == 1;

    "every controller manages runner kinds that exist, and names the account a pool binds back to" =
      lib.all
        (c: c.manages != [ ]
          && lib.all (r: systems.runners ? ${r}) c.manages
          && lib.hasInfix "{RELEASE}" c.serviceAccount)
        (lib.attrValues systems.controllers);

    "every runner that needs a controller names one that exists and claims it back" =
      lib.all
        (name:
          let r = systems.runners.${name}; in
          r.controller == null
          || ((systems.controllers ? ${r.controller})
          && lib.elem name systems.controllers.${r.controller}.manages))
        (lib.attrNames systems.runners);

    "a runner dials a server, a forge, or something outside this model -- and only one of the three" =
      lib.all (r: lib.elem r.dials [ "server" "forge" "external" ]) (lib.attrValues systems.runners);

    # A runner that dials a CI server must name the variable the address arrives in, because the
    # module DERIVES that address; one that does not must not, because there is nothing to derive.
    "only a runner that dials a CI server names a server-address variable" =
      lib.all
        (r: (r.dials == "server") == (r.serverAddressEnv != null))
        (lib.attrValues systems.runners);

    "a step runs as a process in the runner's own pod, or in a pod it creates, and the catalogue says which" =
      lib.all (r: lib.elem r.steps [ "process" "pod" ]) (lib.attrValues systems.runners);

    # The warm shape and the single-writer rule are the same fact: a process-backend runner shares
    # one filesystem with every step, so a second copy of it writes the same store.
    "a runner whose steps are processes in its own pod is the single writer of that pod's state" =
      lib.all (r: r.steps != "process" || r.singleWriter) (lib.attrValues systems.runners);

    "several runner systems are catalogued, because running more than one at once is a real state" =
      lib.length (lib.attrNames systems.runners) > 2;

    "every entry carries a note, and no note is empty" =
      lib.all (e: lib.isString (e.note or null) && lib.stringLength e.note > 200) allEntries;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else
  throw ''
    nixci: clients-eval check failed. Failing assertions:
    ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
  ''
