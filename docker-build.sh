#!/bin/bash
DOCKER_IMAGE=harbor.ioanalytica.com/io/devops/k3s-borg:0.9.7
docker buildx build --platform linux/amd64,linux/arm64 -t ${DOCKER_IMAGE} . --push
docker-squash.sh ${DOCKER_IMAGE} --platform linux/amd64,linux/arm64 -t ${DOCKER_IMAGE} --push

# end
