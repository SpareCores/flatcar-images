# A userspace iSCSI target (tgt) for scripts/boot-test-iscsi.sh. Base image pinned by digest.
FROM ubuntu@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b
RUN apt-get update && apt-get install --yes --no-install-recommends tgt && rm -rf /var/lib/apt/lists/*
