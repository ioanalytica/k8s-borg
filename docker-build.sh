#!/bin/bash
DOCKER_IMAGE=harbor.ioanalytica.com/io/devops/k3s-borg:latest
docker buildx build --platform linux/amd64 -t ${DOCKER_IMAGE} . --push

# end
