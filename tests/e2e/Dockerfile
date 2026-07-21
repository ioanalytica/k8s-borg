# syntax=docker/dockerfile:1
#
# Test layer on top of the agent image: adds bats and the test files, changes
# nothing else. The scripts under test are the ones the image actually ships —
# no copies, no rewrites — so a green run here is a statement about the
# artifact, not about the checkout.
#
#   built and run by tests/e2e/run.sh

ARG BASE=k8s-borg:test
FROM ${BASE}

# hadolint ignore=DL3018
RUN apk add --no-cache bats

COPY tests/e2e /tests/e2e

# The agent image's entrypoint starts the agent; here the container is a test
# runner and nothing else.
ENTRYPOINT []
CMD ["bats", "--print-output-on-failure", "/tests/e2e"]
