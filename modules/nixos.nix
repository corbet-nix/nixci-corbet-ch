# SPDX-License-Identifier: MIT OR Apache-2.0
#
# NixOS backend for the client catalogue. Here the system IS nix, so installing the clients into
# `environment.systemPackages` is correct rather than a duplication of a distro package manager.
#
# THE CLUSTER SIDE IS NOT HERE AND WILL NOT BE. `nixci.forges` / `nixci.servers` / `nixci.caches` /
# `nixci.controllers` / `nixci.runners` / `nixci.jobs` render Kubernetes objects through a nixidy
# evaluation, which is a different module system with a different set of options; a NixOS host
# composing this file gets the client surface and nothing else. That is the boundary rather than a
# gap -- see ./cluster.nix.
#
# EVERY ATTRIBUTE IS FORCE-EVALUATED, not merely looked up, and the reason is measured rather than
# theoretical: nixpkgs converts a renamed package into `<oldName> = throw "renamed to ...";`, which
# keeps the key present and only fails when the value is forced -- which is exactly what building
# `environment.systemPackages` does. So an existence check here would ship a host configuration that
# evaluates and then fails to build. `tryEval` turns a stale mapping into a skip plus a warning
# instead of taking the whole system evaluation down: ../lib/clients.nix is a data table, and one
# stale row in it should not be able to make a machine unbuildable.
#
# A `null` ATTRIBUTE IS NOT A STALE ROW, and the two are reported separately on purpose. Null means
# the catalogue KNOWS there is no nixpkgs derivation -- verified and recorded -- so the honest thing
# on this platform is to say the selection cannot be satisfied here. A stale row means the catalogue
# believed there was one and there is not, which is a bug in the catalogue. Collapsing them into one
# message would send somebody to fix a file that is correct.
#
# NOTHING IS CATALOGUED YET, so this backend installs nothing on every host that composes it. It
# exists ahead of the first entry because the alternative is writing it under time pressure on the
# day somebody assigns one -- and because a plane whose backends do not exist is a plane nobody can
# evaluate the cost of using.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixci.clients;

  resolve = t: lib.getAttrFromPath (lib.splitString "." t.nixpkgs) pkgs;

  packaged = lib.filter (t: (t.nixpkgs or null) != null) cfg.selected;
  unpackaged = lib.filter (t: (t.nixpkgs or null) == null) cfg.selected;

  evaluated = map
    (t: { inherit t; try = builtins.tryEval (builtins.seq (resolve t) true); })
    packaged;

  installable = map (r: r.t) (lib.filter (r: r.try.success) evaluated);
  stale = lib.filter (r: !r.try.success) evaluated;
in
{
  imports = [ ./clients.nix ];

  config = {
    environment.systemPackages = lib.unique (map resolve installable);

    warnings =
      map
        (r: "nixci: nixpkgs attribute `${r.t.nixpkgs}` (catalogue entry `${r.t.name}`, pacman name `${r.t.arch}`) no longer resolves -- lib/clients.nix's mapping is stale, most likely a nixpkgs rename. The client was NOT installed.")
        stale
      ++ map
        (t: "nixci: `${t.name}` has no nixpkgs derivation at all (pacman name `${t.arch}`), so it cannot be installed on NixOS from this catalogue and was skipped. This is recorded knowledge rather than a stale mapping -- see lib/clients.nix's own entry. The selection is published at `nixci.clients.unavailableOnNixos` for a consumer that wants to package it itself.")
        unpackaged;
  };
}
