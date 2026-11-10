# site-gateway-os: RHEL 10 image mode (bootc) OS image, from the Box1 golden path
# (box1-org/box1-templates, templates/rhel-image-vm).

# Build-time check of the site broker (box1-docs#126): start the pinned AMQ Broker image
# with the same start script the site uses and require MQTT on 1883. The final image
# copies the result, so this stage runs in every build. Same digest as the quadlet's
# box1-ci/site-amq-broker mirror (box1-workloads-dev ci/site-gateway/site-images.yaml).
FROM registry.redhat.io/amq7/amq-broker-rhel9@sha256:e77cb86f876b3ba2c4f853e8044b2ab5864346bc4b17e788a0da1287e7c8ec69 AS broker-check
COPY rootfs-site/usr/libexec/box1/site-broker-start /tmp/site-broker-start
RUN export ARTEMIS_INSTANCE_DIR=/tmp/site-broker \
 && (bash /tmp/site-broker-start > /tmp/site-broker.log 2>&1 &) \
 && for i in $(seq 1 90); do \
      if (exec 3<>/dev/tcp/127.0.0.1/1883) 2>/dev/null; then echo "MQTT listener up after ${i}x2 s"; break; fi; sleep 2; \
    done \
 && (exec 3<>/dev/tcp/127.0.0.1/1883) \
 && grep -q 'protocols=MQTT' /tmp/site-broker/etc/broker.xml \
 && ! grep -Eq 'name="(amqp|stomp|hornetq)"' /tmp/site-broker/etc/broker.xml \
 && grep -Eo '<acceptor name="[a-z]+">[^<]*' /tmp/site-broker/etc/broker.xml \
 && date -u +%FT%TZ > /tmp/site-broker-verified \
 || { cat /tmp/site-broker.log; exit 1; }

# The base is pinned by its multi-arch index digest, so the same file builds arm64
# (local Mac, local/) and amd64 (OpenShift) images. Refresh with:
#   skopeo inspect --raw docker://registry.redhat.io/rhel10/rhel-bootc:10.2 | sha256sum
FROM registry.redhat.io/rhel10/rhel-bootc:10.2@sha256:80485ddb9025df594891c36e23f865c63910739c10d37f41ae7247b0c64c2884

ARG SOURCE_REVISION=unknown

# Packages come from the RHEL CDN with the cluster's Simple Content Access
# entitlement, supplied only at build time as secrets (never stored in a layer):
#   --secret id=entitlement-cert,src=.../entitlement.pem
#   --secret id=entitlement-key,src=.../entitlement-key.pem
# build/repos/rhel10-cdn.repo holds the repository definitions (no credentials).
# qemu-guest-agent is required: KubeVirt delivers admin SSH keys through it.
# cloud-init reads per-instance identity from a NoCloud disk only (box1-docs#140);
# rootfs-cloud-init/etc/cloud/cloud.cfg.d/90-box1.cfg limits it to writing files.
RUN --mount=type=secret,id=entitlement-cert,target=/run/secrets/entitlement/entitlement.pem,required=true \
    --mount=type=secret,id=entitlement-key,target=/run/secrets/entitlement/entitlement-key.pem,required=true \
    --mount=type=bind,source=build/repos,target=/run/box1-repos \
    dnf -y --disableplugin=subscription-manager,product-id --setopt=reposdir=/run/box1-repos \
        --setopt=install_weak_deps=False install \
        qemu-guest-agent cloud-init \
        java-21-openjdk-headless greenboot \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/lib/rhsm /var/log/dnf* /var/log/hawkey.log /var/log/rhsm /var/log/qemu-ga

# The Red Hat build of the OpenTelemetry collector (box1-docs#132), installed without its
# scriptlets: its SELinux module install is a second policy-store commit, which made the
# later setsebool fail on the cluster's buildah ("Failed to commit changes to booleans").
# The image runs the binary under its own unit (site-otel-collector.service, DynamicUser),
# so the package's user, unit and policy module are not needed.
RUN --mount=type=secret,id=entitlement-cert,target=/run/secrets/entitlement/entitlement.pem,required=true \
    --mount=type=secret,id=entitlement-key,target=/run/secrets/entitlement/entitlement-key.pem,required=true \
    --mount=type=bind,source=build/repos,target=/run/box1-repos \
    dnf -y --disableplugin=subscription-manager,product-id --setopt=reposdir=/run/box1-repos \
        --setopt=install_weak_deps=False --setopt=tsflags=noscripts install opentelemetry-collector \
 && rpm -q --scripts opentelemetry-collector \
 && dnf clean all \
 && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/lib/rhsm /var/log/dnf* /var/log/hawkey.log /var/log/rhsm

COPY rootfs/ /
# cloud-init configuration, the box1-site user, its credential directory and the
# sshd-keygen override (box1-docs#140).
COPY rootfs-cloud-init/ /
# Site services, quadlets, greenboot checks and the collector config (box1-docs#126-#133).
COPY rootfs-site/ /
# The image's own Containerfile, from which box1-site-facts reads the bundle digest.
COPY Containerfile /usr/share/site-gateway-os/Containerfile
COPY --from=broker-check /tmp/site-broker-verified /usr/share/site-gateway-os/broker-verified

# The site applications (gateway, ops, simulator) from box1-org/site-gateway, as its
# gated bundle, pinned by digest. Releases of site-gateway propose the new digest here.
COPY --from=registry.apps.ocp.box1.org/box1-ci/site-gateway-bundle@sha256:8e9d01383c43e37cbf30b083be311866dc9806158fa09062ede88f9afb41edb6 / /usr/lib/box1/site-gateway/

# virt_qemu_ga_manage_ssh lets qemu-guest-agent write ~/.ssh/authorized_keys, which
# KubeVirt accessCredentials needs; it is off by default in RHEL.
RUN rm -rf /run/secrets/entitlement /run/box1-repos /run/rhsm \
 && printf 'NAME=%s\nREVISION=%s\n' "site-gateway-os" "${SOURCE_REVISION}" > /usr/lib/box1-image-release \
 && chmod 0755 /usr/libexec/site-gateway-os/heartbeat /usr/libexec/box1/registry-setup \
 && chmod 0440 /etc/sudoers.d/90-box1-wheel && visudo -cf /etc/sudoers.d/90-box1-wheel \
 && chmod 0440 /etc/sudoers.d/92-box1-status && visudo -cf /etc/sudoers.d/92-box1-status \
 && chown -R root:root /usr/share/box1 \
 && chmod go-w /usr /usr/share \
 && chmod 0755 /usr/share/box1 /usr/share/box1/ssh /usr/share/box1/ssh/authorized_keys \
 && for d in /usr /usr/share /usr/share/box1 /usr/share/box1/ssh /usr/share/box1/ssh/authorized_keys; do \
      test "$(stat -c %U "$d")" = root && test -z "$(find "$d" -maxdepth 0 -perm /022)" \
        || { echo "sshd StrictModes would refuse $d: $(stat -c '%A %U' "$d")"; exit 1; }; \
    done \
 && chmod 0644 /usr/share/box1/ssh/authorized_keys/box1-status /etc/ssh/sshd_config.d/40-box1-status.conf \
 && systemd-sysusers --dry-run /usr/lib/sysusers.d/box1-status.conf \
 && ssh-keygen -q -t ed25519 -N '' -f /tmp/box1-build-hostkey \
 && /usr/sbin/sshd -T -h /tmp/box1-build-hostkey -C user=box1-status,host=build,addr=127.0.0.1 \
      | grep -qx 'authorizedkeysfile .ssh/authorized_keys /usr/share/box1/ssh/authorized_keys/%u' \
 && rm -f /tmp/box1-build-hostkey /tmp/box1-build-hostkey.pub \
 && grep -q '^restrict,command="sudo /usr/bin/bootc status --format json" ssh-ed25519 ' /usr/share/box1/ssh/authorized_keys/box1-status \
 && setsebool -P virt_qemu_ga_manage_ssh on \
 && systemctl set-default site-gateway-os.target \
 && systemctl enable box1-registry-setup.service \
 && systemctl disable bootc-fetch-apply-updates.timer \
 && rpm -q qemu-guest-agent \
 && rpm -q cloud-init \
 && for unit in cloud-init-main cloud-init-local cloud-init-network cloud-init cloud-config cloud-final; do \
      if [ -e /usr/lib/systemd/system/$unit.service ]; then systemctl enable $unit.service || exit 1; fi; \
    done \
 && systemctl is-enabled cloud-init-local.service cloud-final.service \
 && python3 -c 'import yaml; c = yaml.safe_load(open("/etc/cloud/cloud.cfg.d/90-box1.cfg")); assert c["datasource_list"] == ["NoCloud", "None"] and c["network"] == {"config": "disabled"}' \
 && test ! -e /etc/box1 \
 && grep -qx 'ConditionPathExists=' /usr/lib/systemd/system/sshd-keygen@.service.d/zz-box1-keygen.conf \
 && systemd-sysusers --dry-run /usr/lib/sysusers.d/box1-site.conf \
 && chmod 0755 /usr/libexec/box1/site-secrets /usr/libexec/box1/site-facts /usr/libexec/box1/site-broker-start \
      /etc/greenboot/check/required.d/*-site-*.sh \
 && systemctl enable site-gateway.service site-ops.service site-simulator.service box1-site-secrets.service \
      box1-site-facts.timer site-otel-collector.service \
 && systemctl is-enabled greenboot-healthcheck.service greenboot-set-rollback-trigger.service \
 && rpm -q java-21-openjdk-headless greenboot podman opentelemetry-collector \
 && java -XX:-UsePerfData -version \
 && for m in gateway ops simulator; do test -f /usr/lib/box1/site-gateway/$m/quarkus-app/quarkus-run.jar || exit 1; done \
 && grep -Ec '^COPY --from=\S+/box1-ci/site-gateway-bundle@sha256:[a-f0-9]{64} ' /usr/share/site-gateway-os/Containerfile | grep -qx 1 \
 && mkdir -p /tmp/quadlet-gen \
 && /usr/libexec/podman/quadlet -v /tmp/quadlet-gen \
 && test -f /tmp/quadlet-gen/site-postgres.service && test -f /tmp/quadlet-gen/site-broker.service \
 && cp /tmp/quadlet-gen/site-postgres.service /tmp/quadlet-gen/site-broker.service /etc/systemd/system/ \
 && systemd-analyze verify --man=no site-gateway-os.target site-gateway.service site-ops.service \
      site-simulator.service site-postgres.service site-broker.service box1-site-secrets.service \
      box1-site-facts.service box1-site-facts.timer site-otel-collector.service \
 && rm -rf /tmp/quadlet-gen /etc/systemd/system/site-postgres.service /etc/systemd/system/site-broker.service \
 && { /usr/bin/opentelemetry-collector components 2>&1 | grep -E '^[a-z_]+:$|^    - name:' | tr '\n' ' '; echo; true; } \
 && mkdir /var/lib/box1-site-otel \
 && BOX1_SITE_ID=site_build BOX1_INSTANCE=build /usr/bin/opentelemetry-collector validate \
      --config=/usr/share/site-gateway-os/otel-collector.yaml \
 && rmdir /var/lib/box1-site-otel \
 && bootc container lint

LABEL org.opencontainers.image.source="https://github.com/box1-org/site-gateway-os" \
      org.opencontainers.image.revision="${SOURCE_REVISION}" \
      org.opencontainers.image.title="site-gateway-os" \
      containers.bootc="1"

