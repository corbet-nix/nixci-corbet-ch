# SPDX-License-Identifier: MIT OR Apache-2.0
#
# nixci's client policy: the selection surface for ../lib/clients.nix, and the package-name lists a
# host's own reconciler consumes. Installs nothing itself.
#
# THIS MODULE IS ALSO THE ARCH BACKEND, and there is deliberately no second file behind
# `systemManagerModules.default`. On Arch there is nothing here to install FROM -- the lists below
# are published and the host's own pacman reconciler consumes them -- so an `arch.nix` whose entire
# body was `imports = [ ./clients.nix ];` would be a file that exists to be an indirection.
#
#   nixarch.packages.pacman = config.nixci.clients.archPackages;
#   nixarch.packages.aur    = config.nixci.clients.aurPackages;
#
# PUBLISHED, NOT WIRED, and that is a choice rather than an omission: a host almost always
# concatenates several catalogues into one reconciler list, and a module that assigned into a
# FOREIGN namespace would both hard-depend on that namespace existing and take the concatenation
# point away from the one file that can see every catalogue at once.
#
# EVERY GROUP IS EMPTY TODAY. `types.enum [ ]` accepts no value at all, so a selection into an empty
# group is refused at eval rather than silently resolving to nothing -- which is the behaviour that
# makes an empty catalogue a state rather than a trap.
#
# ONE NAMESPACE. Everything declared here lives under `nixci`, like every repo in this family; the
# client surface is nested at `nixci.clients` so it cannot collide with the cluster surface
# (`nixci.forges` / `nixci.servers` / `nixci.caches` / `nixci.controllers` / `nixci.runners` /
# `nixci.jobs`) that shares the namespace.
{ config, lib, ... }:
let
  cfg = config.nixci.clients;
  cat = import ../lib/clients.nix { };

  mkGroup = what: table: lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames table));
    default = [ ];
    description =
      "Which ${what}. "
      + (if table == { }
      then "NOTHING IS CATALOGUED IN THIS GROUP -- it is declared and empty on purpose (see lib/clients.nix), so any selection here is refused."
      else "Available: ${lib.concatStringsSep ", " (lib.attrNames table)}.");
  };

  # Each resolved entry carries its own catalogue KEY back out as `name` -- without it, everything
  # downstream that needs to say WHICH selection a resolved attrset came from would have to
  # re-derive it by matching on `arch`, which is a different string for every entry.
  resolve = table: k: table.${k} // { name = k; };

  # Groups are hand-listed rather than generated from `lib.attrNames cat`, matching the siblings.
  # The fragility that invites -- a group added to the catalogue and never wired into an option --
  # is closed by a check instead of by cleverness: ../checks/clients-eval.nix asserts that every
  # catalogue group has a matching option on this module.
  selected = lib.flatten [
    (map (resolve cat.forge) cfg.forge)
    (map (resolve cat.ci) cfg.ci)
    (map (resolve cat.cache) cfg.cache)
  ];

  fromAur = t: t.aur or false;
  hasNixpkgs = t: (t.nixpkgs or null) != null;
in
{
  options.nixci.clients = {
    forge = mkGroup
      "forge clients -- they drive the thing that holds the code: repositories, issues, releases"
      cat.forge;

    ci = mkGroup
      "CI server clients -- they drive the thing that decides what runs, over its own API"
      cat.ci;

    cache = mkGroup
      "artifact cache clients -- they push to or pull from the store, and speak to neither of the above"
      cat.cache;

    # ── Computed, read-only ─────────────────────────────────────────────────────────────────────
    selected = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      internal = true;
      description = ''
        The resolved catalogue entries for every name selected above, in one flat list -- the
        canonical "what did this host actually ask for" that every backend derives from. Backends
        read THIS rather than re-deriving a selection from one platform's own package split: the
        pacman/AUR distinction is meaningless on NixOS, and filtering by it there would silently
        drop an entry.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that come from an official Arch repository, as pacman names. For the host's own
        reconciler:

          nixarch.packages.pacman = config.nixci.clients.archPackages;
      '';
    };

    aurPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections that must be built from the AUR, kept SEPARATE from `archPackages` because
        `pacman -S` cannot resolve an AUR name: it fails the whole transaction with "target not
        found", taking every other package in the same converge with it.

          nixarch.packages.aur = config.nixci.clients.aurPackages;
      '';
    };

    nixosPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Selections as nixpkgs attribute paths (dotted for a nested attribute). Entries whose
        catalogue `nixpkgs` is `null` -- no derivation exists at all -- are absent rather than
        present as an empty string, so a consumer reading it gets names it can resolve. Published
        for introspection; ../modules/nixos.nix is what installs them, and it force-evaluates each
        one rather than trusting that the attribute exists.
      '';
    };

    unavailableOnNixos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Catalogue names selected on this host that have NO nixpkgs derivation at all. Published
        rather than merely warned about, because a consumer that wants the tool anyway needs a
        machine-readable list to point its own packaging at.
      '';
    };

    binaries = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        catalogue name -> the command actually installed, for every selection. Published because
        the two disagree often enough that a consumer writing a wrapper, an alias or a launcher
        against the PACKAGE name gets a command that does not exist.
      '';
    };
  };

  config = {
    nixci.clients.selected = selected;
    nixci.clients.archPackages = lib.unique (map (t: t.arch) (lib.filter (t: !(fromAur t)) selected));
    nixci.clients.aurPackages = lib.unique (map (t: t.arch) (lib.filter fromAur selected));
    nixci.clients.nixosPackages = lib.unique (map (t: t.nixpkgs) (lib.filter hasNixpkgs selected));
    nixci.clients.unavailableOnNixos =
      lib.unique (map (t: t.name) (lib.filter (t: !(hasNixpkgs t)) selected));
    nixci.clients.binaries = lib.listToAttrs (map (t: lib.nameValuePair t.name t.binary) selected);
  };
}
