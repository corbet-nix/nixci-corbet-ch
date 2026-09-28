# SPDX-License-Identifier: MIT OR Apache-2.0
{
  description = "nixci — the machinery by which code becomes an artifact, declared: the forge it lives in, the server that decides, the runners that execute and the cache that holds the results, split across a control plane and an execution plane";

  # NO INPUTS FOR CONSUMERS, the same reasoning the sibling catalogues state for themselves: this
  # flake is options plus a catalogue, taking `pkgs`/`config`/`lib` from whichever evaluation
  # composes it, so a real host or a real cluster render never puts a second nixpkgs -- or a sibling
  # flake's whole input closure -- into its own closure. Everything below is used by `checks` alone;
  # nothing this flake EXPORTS reaches into any of it.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The renderer the cluster module defines into. A real input rather than a name in a comment:
    # without it there is no module system to evaluate the cluster side against, and `nix flake
    # check` would pass by checking nothing.
    nixidy = {
      url = "github:arnarg/nixidy";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # THE APP GRAMMAR THIS REPOSITORY CONSUMES. Also checks-only, and that is the point being proven
    # rather than a shortcut: a consumer imports the grammar itself, and this input exists so `nix
    # flake check` can render the cluster module through the REAL grammar and assert the manifests
    # that come out -- rather than asserting that a module which merely mentions `nixk3s.apps`
    # evaluates.
    nixk3s = {
      url = "git+https://github.com/corbet-nix/nixk3s-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixidy.follows = "nixidy";
    };
  };

  outputs = { self, nixpkgs, nixidy, nixk3s }:
    let
      lib = nixpkgs.lib;
      forAllSystems = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      clusterModule = import ./modules/cluster.nix {
        catalogue = self.lib.systems;
        inherit (nixk3s.lib) mkConsumerModule;
      };
    in
    {
      # The cluster plane, both halves of it. Composed into a nixidy environment ALONGSIDE the app
      # grammar, which declares the options this module defines into -- see modules/cluster.nix's
      # own header.
      nixidyModules.nixci = clusterModule;
      nixidyModules.default = clusterModule;
      nixidyModules.repositoryPolicy = ./modules/repositories.nix;

      # The host plane, for the commands a person drives this platform with. Here the system is nix,
      # so the backend installs; on Arch there is nothing to install FROM, so the policy module IS
      # that backend and publishes package-name lists for the host's own reconciler.
      nixosModules.nixci = ./modules/nixos.nix;
      nixosModules.default = ./modules/nixos.nix;

      systemManagerModules.nixci = ./modules/clients.nix;
      systemManagerModules.default = ./modules/clients.nix;

      # Policy alone, for a consumer that wants the computed lists and will wire them itself, plus
      # the raw catalogues for inspection without re-reading the files.
      lib.clientsPolicy = ./modules/clients.nix;
      lib.repositoryPolicy = ./modules/repositories.nix;
      lib.cluster = clusterModule;
      lib.systems = import ./lib/systems.nix { };
      lib.clients = import ./lib/clients.nix { };

      # `nix flake check` evaluates none of the module outputs on its own, so a green check on this
      # repository without these three files would cover nothing but flake syntax.
      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # The cluster module, rendered through the real grammar and the real renderer, from the
          # placeholder values in examples/. Building the environment package forces the whole
          # manifest tree.
          env = nixidy.lib.mkEnv {
            inherit pkgs;
            modules = [
              nixk3s.nixidyModules.apps
              nixk3s.nixidyModules.addressing
              self.nixidyModules.nixci
              ./examples/all/values.nix
            ];
          };
        in
        {
          # 1. The host catalogue and its policy module, evaluated for real against
          # `lib.evalModules`: what a selection resolves to on every plane a backend reads, and the
          # tripwire that fires the moment a package is assigned without this file being revisited.
          clients-eval = import ./checks/clients-eval.nix { inherit pkgs; };
          repository-policy = import ./checks/repository-policy.nix { inherit pkgs; };

          # 2. The cluster module's own resolution and every guard it makes, in BOTH directions: an
          # empty platform renders nothing at all, a declared one resolves, and each refusal gets a
          # declaration that must be refused -- including the plane separation, which is asserted as
          # an unknown-option error rather than as a rule somebody remembered.
          cluster-eval = import ./checks/cluster-eval.nix {
            inherit pkgs lib nixidy;
            appsModule = nixk3s.nixidyModules.apps;
            addressingModule = nixk3s.nixidyModules.addressing;
            clusterModule = self.nixidyModules.nixci;
          };

          # 3. The manifests the platform actually PRODUCED, parsed and asserted field by field. A
          # module that type-checks can still render a runner with a Service in front of it, or a
          # cache whose store is writable, or a forge whose config directory is not mounted -- none
          # of that is an eval error and all of it is either an outage or a breach.
          cluster-render = import ./checks/cluster-render.nix { inherit pkgs lib env; };
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
