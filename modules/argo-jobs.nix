# SPDX-License-Identifier: MIT OR Apache-2.0
# Exact staged repository jobs, shared with the Crow adapter.
{ config, lib, ... }:
let
  cfg = config.nixci.argo;
  inherit (lib) mkOption mkEnableOption mkIf types;
  resourcesType = types.submodule {
    options = {
      requests = mkOption { type = types.attrsOf types.str; default = { }; };
      limits = mkOption { type = types.attrsOf types.str; default = { }; };
    };
  };
in {
  options.nixci.argo.workflows = {
      jobRunner = {
        enable = mkEnableOption "a ccid WorkflowTemplate for exact staged jobs";
        name = mkOption { type = types.str; default = "ccid-job"; description = "WorkflowTemplate name."; };
        image = mkOption { type = types.str; description = "Runner image; required tools must already exist in it or in mounted paths."; };
        shell = mkOption { type = types.str; default = "bash"; description = "Existing shell used by the checksum-verifying launcher."; };
        environment = mkOption { type = types.attrsOf types.str; default = { }; description = "Runner environment, without credentials."; };
        volumes = mkOption { type = types.listOf types.attrs; default = [ ]; description = "Kubernetes volumes supplied by the deployment."; };
        volumeMounts = mkOption { type = types.listOf types.attrs; default = [ ]; description = "Runner mounts for staged inputs, tools and caches."; };
        securityContext = mkOption { type = types.attrs; default = { }; description = "Pod security context."; };
        resources = mkOption { type = resourcesType; description = "Explicit runner resource requests and limits."; };
        priorityClassName = mkOption { type = types.nullOr types.str; default = null; description = "Optional existing pod priority class."; };
      };
  };
  config = mkIf (cfg.workflows.enable && cfg.workflows.jobRunner.enable) {
    applications.argo-workflows = {
        yamls = lib.optional cfg.workflows.jobRunner.enable (builtins.toJSON {
          apiVersion = "argoproj.io/v1alpha1";
          kind = "WorkflowTemplate";
          metadata = { name = cfg.workflows.jobRunner.name; namespace = cfg.workflowNamespace; };
          spec = {
            entrypoint = "run";
            serviceAccountName = cfg.workflows.serviceAccountName;
            activeDeadlineSeconds = 1800;
            securityContext = cfg.workflows.jobRunner.securityContext;
            volumes = cfg.workflows.jobRunner.volumes;
            arguments.parameters = map (name: { inherit name; }) [ "request" "binary" "binary-sha256" ];
            templates = [{
              name = "run";
              container = {
                inherit (cfg.workflows.jobRunner) image resources volumeMounts;
                command = [ cfg.workflows.jobRunner.shell "-ceu" ];
                args = [ ''
                  set -o pipefail
                  printf '%s  %s\n' "$CCID_BINARY_SHA256" "$CCID_BINARY" | sha256sum --check --strict
                  request_file=$(mktemp)
                  trap 'rm -f -- "$request_file"' EXIT
                  printf '%s\n' "$CCID_JOB_REQUEST" > "$request_file"
                  "$CCID_BINARY" execute-job --request "$request_file"
                '' ];
                env = lib.mapAttrsToList (name: value: { inherit name value; }) cfg.workflows.jobRunner.environment ++ [
                  { name = "CCID_JOB_REQUEST"; value = "{{workflow.parameters.request}}"; }
                  { name = "CCID_BINARY"; value = "{{workflow.parameters.binary}}"; }
                  { name = "CCID_BINARY_SHA256"; value = "{{workflow.parameters.binary-sha256}}"; }
                ];
                securityContext = { allowPrivilegeEscalation = false; capabilities.drop = [ "ALL" ]; };
              };
            }];
          } // lib.optionalAttrs (cfg.workflows.jobRunner.priorityClassName != null) {
            podPriorityClassName = cfg.workflows.jobRunner.priorityClassName;
          };
        });

    };
  };
}
