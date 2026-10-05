# Periodic forge reconciliation

Import `nixosModules.reconciliation` to schedule the existing `ccid forge sync`
command. It is disabled by default and creates no repositories or credentials.

```nix
imports = [ inputs.nixci.nixosModules.reconciliation ];
nixci.reconciliation = {
  enable = true;
  binary = "/opt/ccid/verified-revision/ccid";
  user = "replicator"; # Must already be declared by the host.
  repositories.widget = {
    policyFile = "/etc/forge-policies/widget.json";
    destinations = [ "secondary" ];
    intervalSeconds = 900;
    timeoutSeconds = 120;
    pauseSeconds = 5;
  };
};
```

The `ccid-forge-reconcile.timer` starts one bounded oneshot service. A file lock
also prevents overlapping manual invocations. Each due repository runs
`forge sync --all-refs --to <destination> --apply`, with the primary from its
policy and an explicit deadline. Runs continue after an offline destination or
failed repository, return nonzero overall, and retain the failed state during
the configured retry interval. `pauseSeconds` paces attempts, including failures.
No automatic primary promotion, force push, pruning or ref deletion is added.
ccid refuses divergent refs and missing external LFS/submodule closures.

`tickSeconds` defaults to 60. `stateDirectory` defaults to the name
`ccid-forge-reconcile` below `/var/lib`; the service user owns it with mode 0700.
Each `<repository>.json` is atomically replaced and fsynced before and after an
attempt. It includes attempt times, pending/complete state, exit code and ccid's
full JSON result. `complete` describes the requested destinations; consult
`result.repository_complete` for completion across every declared replica.
An interrupted attempt remains pending. Reports are current observations, not
an append-only audit log. systemd bounds the entire pass and cleans descendants
if ccid overruns its own deadline.

Pin the executable by immutable path or set both `binarySha256` (SHA-256 hex) and
`toolRevision` (the expected `ccid source-revision`). The scheduler verifies the
pair once per pass before any Git request; mismatch leaves repositories pending.

Credentials remain host inputs. Set `environmentFile` to an existing runtime file,
`gitAskpass` to an existing program, or configure exact HTTPS origins:

```nix
nixci.reconciliation.credentials."https://forge.example" = {
  username = "robot";
  passwordCommand = [ "/absolute/credential-reader" "nonsecret-arguments" ];
};
```

The generic askpass handler answers only Git's matching origin and username
prompts. It executes the configured argv without a shell and suppresses command
errors; the password goes only to Git. Never place passwords in arguments or
Nix values: command paths and arguments are public store contents. `credentials`
and `gitAskpass` are mutually exclusive. The module does not provision tokens,
decrypt files at evaluation time, or install credential tools. Hosts can supply
HOME, SSH configuration and other ordinary settings through
`systemd.services.ccid-forge-reconcile.environment`.

`checks.<system>.reconciliation` evaluates the module and runs offline Python
fixtures for lock exclusion, partial failure and pacing, executable verification,
durable report handling and askpass origin/username boundaries.
