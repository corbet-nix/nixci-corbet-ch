# SPDX-License-Identifier: MIT OR Apache-2.0
#
# The client catalogue: what a PERSON installs on a host in order to drive this platform.
#
# IT IS EMPTY, AND THE EMPTINESS IS A STATE RATHER THAN A GAP. The plane exists -- the policy
# module, both host backends, the checks and the option surface all resolve -- and it claims no
# package, because assigning a package to a repository belongs to whoever owns the package set. A
# catalogue that guessed would quietly take a command out of the repository that has it today,
# where it is already declared, verified and installed on real hosts. Adding the first entry is one
# attribute in one group here and nothing else.
#
# ── THE THREE GROUPS, AND WHY THEY ARE THREE ───────────────────────────────────────────────────
#
#   `forge`   drives a FORGE from a shell: repositories, issues, pull requests, releases. It talks
#             to the thing that holds the code, and it is useful on a host that runs no pipeline at
#             all.
#   `ci`      drives a CI SERVER: list pipelines, trigger one, read a log, set a repository secret.
#             It talks to the thing that decides what runs, over that server's own API, and it is
#             useless without one to point at.
#   `cache`   pushes to or pulls from an ARTIFACT CACHE. Not a client of either of the above: it
#             speaks to the store, usually with a signing key or a push token, and it is the one
#             group here that a machine which never opens a browser still needs.
#
# THE PLACEMENT RULE, so the next candidate is decidable rather than argued:
#
#   Does the tool exist in order to drive a forge, a CI server or an artifact cache -- over that
#   system's own protocol?
#     yes -> it belongs here
#     no  -> it belongs to whichever repository owns the thing it actually is
#
# "IT IS USED IN A PIPELINE" IS NOT THE TEST, and that clause is the load-bearing one: a compiler,
# a linter, a container tool and a deployment CLI all run inside pipelines, and if being used by CI
# were the test this catalogue would swallow the whole development toolchain. The test is whether
# the tool's subject IS the platform.
#
# A COMMAND THAT DRIVES A CLUSTER IS NOT A CI CLIENT EITHER, by an existing ruling in this family:
# a plugin that talks to the Kubernetes API belongs with the development tooling, not with whichever
# repository happens to own the service running in the cluster. That is why there is no `controller`
# group here to mirror the cluster catalogue's -- a controller's control plane is Kubernetes.
#
# ── FIELDS, for the day an entry lands ─────────────────────────────────────────────────────────
#
#   `arch`      pacman package name.
#   `aur`       true when it is only in the AUR. The two lists must never intersect: `pacman -S`
#               resolves a transaction ATOMICALLY, so one AUR name in a pacman list fails the whole
#               converge with "target not found" and takes every unrelated package with it.
#   `nixpkgs`   nixpkgs attribute path (dotted for a nested attribute), or an explicit `null` when
#               no derivation exists at all. Never an empty string, which would read as a name.
#   `binary`    the command actually installed. Recorded separately because it disagrees with the
#               package name often enough that assuming otherwise is how a wrapper gets written
#               against a command that does not exist.
#   `drives`    which system the tool talks to -- a forge, a CI server, a cache. The reference runs
#               THIS WAY ROUND on purpose: a client points at a kind of system, and no entry in
#               ../lib/systems.nix names a package. Packages get reassigned between repositories by
#               somebody who is not reading the cluster catalogue, and an entry there that named one
#               would break the platform every time that happened.
#   `note`      what it is, and every non-obvious thing about installing it.
{ ... }:
{
  forge = { };
  ci = { };
  cache = { };
}
