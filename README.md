# site-gateway-os

RHEL 10 image for edge site gateways

A **RHEL 10 image mode (bootc)** virtual machine created from the Box1 golden path (`box1-org/box1-templates`, template `rhel-image-vm`). The operating system is a container image built from this repository. Change the OS by committing here, and apply approved releases in the VM.

```
Containerfile          rhel10/rhel-bootc:10.2 (pinned) + packages + rootfs/ + bootc container lint
rootfs/                files layered onto the OS: site-gateway-os.target (default boot target),
                       an example service, bootc update plumbing, console kargs, sudoers
build/repos/           RHEL CDN repositories for dnf (no credentials)
.tekton/               Pipelines-as-Code: PR build check, and release
local/                 build and boot an arm64 copy on an Apple Silicon Mac
```

## Make a change

1. Edit the `Containerfile` or `rootfs/`. For example, add a systemd unit with `WantedBy=site-gateway-os.target`, or add packages to the `dnf install` line.
2. Open a PR. `site-gateway-os-validate` builds the image and runs `bootc container lint`.
3. Merge it. `site-gateway-os-release` runs these steps:
   1. builds and pushes `box1-ci/site-gateway-os@<digest>`;
   2. runs the TPA and ACS scans, in observe mode, and links the reports from the run's results;
   3. builds a new install disk, `box1-ci/site-gateway-os-disk`;
   4. opens and merges a box1-workloads-dev PR that records the digest on the VirtualMachine as `box1.org/os-image-digest`;
   5. moves `box1-ci/site-gateway-os:development` to that digest;
   6. checks the VM.
4. Apply the release in the VM:

```sh
virtctl ssh -n site-gateway-os-dev cloud-user@vm/site-gateway-os
sudo bootc upgrade --check     # what would change
sudo bootc upgrade --apply     # stage it and reboot
sudo bootc status              # booted / rollback digests (compare with box1.org/os-image-digest)
sudo bootc rollback --apply    # return to the previous image
```

Releases never reboot the VM on their own: `bootc-fetch-apply-updates.timer` is disabled.

## Access

- **SSH:** `cloud-user` (passwordless sudo) accepts the public keys in the GitOps Secret `workloads/site-gateway-os/admin-access.yaml` in box1-workloads-dev. KubeVirt delivers them through qemu-guest-agent, and changes reach the running VM without a restart.
- **Serial console:** `virtctl console site-gateway-os -n site-gateway-os-dev`, or open the VM in the OpenShift console. No account has a password, so use the console for boot output and use SSH to log in.

## Where things are

| What | Where |
| --- | --- |
| VM, disk and access (desired state) | `box1-org/box1-workloads-dev`: `workloads/site-gateway-os/`, synced by Argo CD Application `site-gateway-os` |
| OS images | `box1-ci/site-gateway-os` (update channel `:development`) and `box1-ci/site-gateway-os-disk` |
| Registry access for `bootc upgrade` | At boot, `box1-registry-setup.service` installs the service CA and a pull token from two VM disks (`serviceca`, `regtoken`) |
| Per-instance identity (cloud-init) | Optional. A VM with a `cloudinitdisk` NoCloud volume (`secretRef: <instance>-cloud-init`) gets `/etc/box1/site.env` (0644) and `/etc/box1/credentials/keycloak-client-secret` (0400, user `box1-site`), rewritten at every boot. Without the disk, cloud-init writes nothing. `rootfs-cloud-init/` holds its configuration, which runs only `write_files`; treat write access to the Secret as root in the guest. See box1-docs `runbooks/vm-cloud-init-identity.md` |
| Shared build tasks | `box1-org/box1-gitops`: `platform/pipelines/tasks/bootc-*.yaml`; see `GOLDEN-PATH.md` |

## The edge site (box1-docs#126–#133)

On an instance with site identity (`/etc/box1/site.env` from cloud-init) the image runs a complete edge site; on a VM
without it (for example this repository's own VM) none of the site units start and the greenboot site checks pass.

| Unit | What | Where |
| --- | --- | --- |
| `site-broker.service` (quadlet) | AMQ Broker 7.14.1, MQTT only, `box1-ci/site-amq-broker@sha256:e77cb86f…` | 127.0.0.1:1883, data `/var/lib/box1-site/broker` |
| `site-postgres.service` (quadlet) | PostgreSQL 16, `box1-ci/site-postgresql@sha256:640273e1…` | 127.0.0.1:5432, data `/var/lib/box1-site/postgres` |
| `site-gateway`, `site-ops`, `site-simulator` | the `site-gateway` bundle (`/usr/lib/box1/site-gateway/`) on `java-21-openjdk-headless`, user `box1-site` | 127.0.0.1:8080 / 8081 / 8082 |
| `box1-site-secrets.service` | database password, generated once, root-only env files | `/var/lib/box1-site/secrets` |
| `box1-site-facts.timer` | booted/staged/rollback digests, greenboot result, bundle digest for the heartbeat | `/run/box1/site-facts.json` |
| `site-otel-collector.service` | Red Hat build of OpenTelemetry: journald, host and gateway metrics → `box1-collector` | `/usr/share/site-gateway-os/otel-collector.yaml` |
| greenboot `/etc/greenboot/check/required.d/*-site-*.sh` | PostgreSQL, MQTT listener, site-gateway ready (database, migrations, MQTT; never Kafka), site-ops | rollback after 3 failed boots |

- The quadlet images are mirrored into `box1-ci` by digest (box1-gitops `platform/pipelines/ci/site-images.yaml`)
  and pulled with the pull token `box1-registry-setup` installs; the image contains no registry credential.
- Site data under `/var` survives reboots, `bootc upgrade` and `bootc rollback`; a rebuild from the instance loses it.
- Every build starts the pinned AMQ Broker image with `site-broker-start` and requires MQTT on 1883, generates and
  verifies the quadlet and site units (`systemd-analyze verify`), and validates the collector config with the
  collector binary.
- `greenboot-default-health-checks` is not installed: its repository DNS check would roll back a site that reboots
  while disconnected. The collector RPM is installed without its scriptlets (its SELinux module commit breaks the
  later `setsebool -P` on the cluster's buildah); the image runs it under its own unit.
- Operations: box1-docs `runbooks/edge-sites.md` and site-gateway `docs/runbook.md`.

## Build locally (Apple Silicon)

```sh
REGISTRY_AUTH_FILE=/path/to/auth.json ENTITLEMENT_DIR=/path/to/ent local/build-local.sh
local/run-local.sh
```

You need a `registry.redhat.io` auth file and the cluster's entitlement certificate (`entitlement.pem` and `entitlement-key.pem`), both under `/Users` or `/private`. These are build inputs only; they are never copied into this repository or the image.
