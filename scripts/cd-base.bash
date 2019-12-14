#!/bin/bash

set -eu -o pipefail

# get current branch and commit sha, and force branch name to valid docker tag character set
# allow forcing branch name regardless of current banch using FORCE_CI_* variables
readonly branch_name="${FORCE_CI_BRANCH_NAME:-$(git rev-parse --abbrev-ref HEAD | tr -d '\n' | tr -c '[:alnum:].-' _)}"
readonly git_sha="${FORCE_CI_GIT_SHA:-$(git rev-parse HEAD)}"

# pull image if it exists, ignore if it does not
docker pull "docker.example.com/app-bins:${branch_name}" || true

docker build --pull \
  --cache-from "docker.example.com/app-bins:${branch_name}" \
  -t "docker.example.com/app-bins:${git_sha}" \
  -f Dockerfile.cd .

docker tag \
  "docker.example.com/app-bins:${git_sha}" \
  "docker.example.com/app-bins:${branch_name}"

docker push "docker.example.com/app-bins:${git_sha}"
docker push "docker.example.com/app-bins:${branch_name}"
