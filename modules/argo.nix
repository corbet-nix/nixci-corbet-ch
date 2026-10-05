# SPDX-License-Identifier: MIT OR Apache-2.0
# Argo Workflows + Argo Events as a forge-agnostic scheduler, declared as nixidy applications.
#
# This is the second scheduler next to a forge-bound CI server: templates live in the cluster,
# triggers are generic (cron, webhook, API), and nothing here knows which git platform a repository
# lives on. The module renders two Helm releases (the vendor charts, pinned by version and content
# hash) and, optionally, one EventBus in the namespace where workflows run.
#
# ── SHAPE ─────────────────────────────────────────────────────────────────────────────────────
#
#   argo-workflows (ns `argo-workflows`)   workflow controller + argo-server (ClusterIP only)
#   argo-events    (ns `argo-events`)      events controller + minimal EventBus for the workflow ns
#   workflow ns    (default `ci-argo`)     where Workflows run, with a ServiceAccount and a Role
#                                          created by the chart (controller.workflowNamespaces)
#
# The argo-server Service is ClusterIP: no Ingress, no public exposure; reach it over the private
# network or `kubectl port-forward`. The chart's default auth mode is `client` (a bearer token is
# required), which this module keeps.
#
# CRDs are the chart's minified form (`crds.full = false`: schemas preserve unknown fields). That
# avoids the chart's pre-install hook Job and keeps the render a set of plain objects. Both CRD
# sets are large, so server-side apply is on, with server-side diff (see nixci/cluster.nix for the
# 262144-byte last-applied annotation limit this works around).
#
# Hash maintenance: `chartHash` is the NAR hash of the untarred chart directory, i.e.
# `helm pull --repo <repo> <chart> --version <v> --untar && nix hash path <chart>`.
{ config, lib, ... }:
let
  cfg = config.nixci.argo;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge types;

  resourcesType = types.submodule {
    options = {
      requests = mkOption { type = types.attrsOf types.str; default = { }; };
      limits = mkOption { type = types.attrsOf types.str; default = { }; };
    };
  };

  mkResources = requests: limits: mkOption {
    type = resourcesType;
    default = { inherit requests limits; };
    description = "Container resource requests and limits.";
  };

  chart = repo: name: version: hash: lib.helm.downloadHelmChart {
    inherit repo version;
    chart = name;
    chartHash = hash;
  };
in
{
  options.nixci.argo = {
    project = mkOption {
      type = types.str;
      default = "default";
      description = "Argo CD AppProject the applications belong to.";
    };

    createNamespaces = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the applications create their own namespaces. Set false when another layer (for
        example a tenancy module) anchors the namespaces; the workflow namespace is then also
        expected to exist.
      '';
    };

    workflowNamespace = mkOption {
      type = types.str;
      default = "ci-argo";
      description = "The namespace Workflows, EventSources, Sensors and the EventBus live in.";
    };

    workflows = {
      enable = mkEnableOption "Argo Workflows (controller and a cluster-internal argo-server)";
      namespace = mkOption { type = types.str; default = "argo-workflows"; };
      chartVersion = mkOption { type = types.str; default = "2.0.11"; description = "argo-workflows chart version (app v4.1.4)."; };
      chartHash = mkOption { type = types.str; default = "sha256-GXNb9Y33Cic5uE8C9qBDNz8n/fJmBF6MszBYq1FxHZo="; };
      serviceAccountName = mkOption { type = types.str; default = "argo-workflow"; description = "ServiceAccount workflows run as, in the workflow namespace."; };
      server.enable = mkOption { type = types.bool; default = true; description = "Run argo-server (ClusterIP, client auth)."; };
      resources = {
        controller = mkResources { cpu = "50m"; memory = "128Mi"; } { cpu = "500m"; memory = "512Mi"; };
        server = mkResources { cpu = "25m"; memory = "64Mi"; } { cpu = "250m"; memory = "256Mi"; };
      };
      values = mkOption {
        type = types.attrs;
        default = { };
        description = "Extra chart values, merged over the module's own.";
      };
    };

    events = {
      enable = mkEnableOption "Argo Events (controller and a minimal EventBus)";
      namespace = mkOption { type = types.str; default = "argo-events"; };
      chartVersion = mkOption { type = types.str; default = "2.4.27"; description = "argo-events chart version (app v1.9.11)."; };
      chartHash = mkOption { type = types.str; default = "sha256-Ukdoy13K2xDJ/iC2OlB4QJ1feqnpXp+Oxe0acKhGVAo="; };
      resources.controller = mkResources { cpu = "25m"; memory = "64Mi"; } { cpu = "250m"; memory = "256Mi"; };
      sensorServiceAccountName = mkOption {
        type = types.str;
        default = "argo-events-sensor";
        description = ''
          ServiceAccount for Sensors in the workflow namespace; it may create and read Workflows
          there (the workflow ServiceAccount itself deliberately cannot).
        '';
      };
      eventBus = {
        enable = mkOption { type = types.bool; default = true; description = "Render an EventBus named `default` in the workflow namespace."; };
        replicas = mkOption { type = types.ints.positive; default = 1; description = "JetStream replicas."; };
        jetstreamVersion = mkOption { type = types.str; default = "2.10.29"; };
      };
      values = mkOption { type = types.attrs; default = { }; };
    };
  };

  config = mkMerge [
    (mkIf cfg.workflows.enable {
      applications.argo-workflows = {
        inherit (cfg) project;
        namespace = cfg.workflows.namespace;
        createNamespace = cfg.createNamespaces;
        syncPolicy.syncOptions.serverSideApply = true;
        annotations."argocd.argoproj.io/compare-options" = "ServerSideDiff=true";

        helm.releases.argo-workflows = {
          chart = chart "https://argoproj.github.io/argo-helm" "argo-workflows"
            cfg.workflows.chartVersion cfg.workflows.chartHash;
          includeCRDs = true;
          values = lib.recursiveUpdate
            {
              crds = { install = true; keep = true; full = false; };
              images.pullPolicy = "IfNotPresent";
              controller = {
                replicas = 1;
                workflowNamespaces = [ cfg.workflowNamespace ];
                resources = cfg.workflows.resources.controller;
                # Workflows submitted without a ServiceAccount run as the dedicated one.
                workflowDefaults.spec.serviceAccountName = cfg.workflows.serviceAccountName;
              };
              workflow = {
                # Naming the namespace here as well makes the chart's per-namespace list a single
                # entry; otherwise it also renders same-named objects for the release namespace,
                # which nixidy (keyed by object name) refuses as conflicting definitions.
                namespace = cfg.workflowNamespace;
                serviceAccount = { create = true; name = cfg.workflows.serviceAccountName; };
                rbac.create = true;
              };
              server = {
                enabled = cfg.workflows.server.enable;
                replicas = 1;
                serviceType = "ClusterIP";
                resources = cfg.workflows.resources.server;
              };
            }
            cfg.workflows.values;
        };
      };
    })

    (mkIf cfg.events.enable {
      applications.argo-events = {
        inherit (cfg) project;
        namespace = cfg.events.namespace;
        createNamespace = cfg.createNamespaces;
        syncPolicy.syncOptions.serverSideApply = true;
        annotations."argocd.argoproj.io/compare-options" = "ServerSideDiff=true";

        helm.releases.argo-events = {
          chart = chart "https://argoproj.github.io/argo-helm" "argo-events"
            cfg.events.chartVersion cfg.events.chartHash;
          includeCRDs = true;
          values = lib.recursiveUpdate
            {
              crds = { install = true; keep = true; };
              controller = {
                replicas = 1;
                resources = cfg.events.resources.controller;
              };
            }
            cfg.events.values;
        };

        # The bus is namespaced to where EventSources and Sensors live, not to the controller.
        yamls = [
          ''
            apiVersion: v1
            kind: ServiceAccount
            metadata:
              name: ${cfg.events.sensorServiceAccountName}
              namespace: ${cfg.workflowNamespace}
          ''
          ''
            apiVersion: rbac.authorization.k8s.io/v1
            kind: Role
            metadata:
              name: ${cfg.events.sensorServiceAccountName}
              namespace: ${cfg.workflowNamespace}
            rules:
              - apiGroups: [argoproj.io]
                resources: [workflows, workflowtemplates]
                verbs: [create, get, list, watch]
          ''
          ''
            apiVersion: rbac.authorization.k8s.io/v1
            kind: RoleBinding
            metadata:
              name: ${cfg.events.sensorServiceAccountName}
              namespace: ${cfg.workflowNamespace}
            roleRef:
              apiGroup: rbac.authorization.k8s.io
              kind: Role
              name: ${cfg.events.sensorServiceAccountName}
            subjects:
              - kind: ServiceAccount
                name: ${cfg.events.sensorServiceAccountName}
                namespace: ${cfg.workflowNamespace}
          ''
        ] ++ lib.optionals cfg.events.eventBus.enable [
          ''
            apiVersion: argoproj.io/v1alpha1
            kind: EventBus
            metadata:
              name: default
              namespace: ${cfg.workflowNamespace}
            spec:
              jetstream:
                version: "${cfg.events.eventBus.jetstreamVersion}"
                replicas: ${toString cfg.events.eventBus.replicas}
                # Streams default to 3 replicas, which a smaller bus refuses ("replicas > 1 not
                # supported in non-clustered mode"), so the stream follows the bus size.
                streamConfig: |
                  maxMsgs: 1000000
                  maxAge: 72h
                  maxBytes: 1GB
                  replicas: ${toString cfg.events.eventBus.replicas}
          ''
        ];
      };
    })
  ];
}
