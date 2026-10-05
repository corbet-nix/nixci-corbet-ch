# SPDX-License-Identifier: MIT OR Apache-2.0
# Placeholder values for the Argo module: both halves enabled with their defaults.
{
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";
  nixci.argo = {
    project = "default";
    workflows.enable = true;
    events.enable = true;
  };
}
