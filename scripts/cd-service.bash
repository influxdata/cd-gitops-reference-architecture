#!/bin/bash

set -eu -o pipefail

# service to build; strip leading "cd-app-" to avoid passing CI JOB name directly from config.yml
readonly service="$(echo "${1:?App required}" | sed 's,^cd-service-,,')"

# get current branch and commit sha, and force branch name to valid docker tag character set
# allow forcing branch name regardless of current branch using FORCE_CI_* variables
readonly branch_name="${FORCE_CI_BRANCH_NAME:-$(git rev-parse --abbrev-ref HEAD | tr -d '\n' | tr -c '[:alnum:].-' _)}"
readonly git_sha="${FORCE_CI_GIT_SHA:-$(git rev-parse HEAD)}"

# pull image if it exists, ignore if it does not
docker pull "docker.example.com/app-cd-${service}:${branch_name}" || true

docker build --pull \
  --cache-from "docker.example.com/app-cd-${service}:${branch_name}" \
  -t "docker.example.com/app-cd-${service}:${git_sha}" \
  --build-arg BIN_IMAGE=docker.example.com/app-bins:${git_sha} \
  -f "apps/${service}/Dockerfile.cd" .

docker tag \
  "docker.example.com/app-cd-${service}:${git_sha}" \
  "docker.example.com/app-cd-${service}:${branch_name}"

docker push "docker.example.com/app-cd-${service}:${git_sha}"
docker push "docker.example.com/app-cd-${service}:${branch_name}"

# Construct a JSON object for this image's Tag and Digest.
# I was not able to retrieve the digest when calling docker images against a specific tag,
# so get all the tags and digests for the given image and grep for the matching tag.
jq --null-input --sort-keys \
  --arg tagDigest "$(docker images "docker.example.com/app-cd-${service}" --format '{{.Tag}} {{.Digest}}' | grep "^${git_sha}")" \
  --arg imgPrefix "docker.example.com/app-cd-$service" \
  --arg serviceKey "$SERVICEKEY" \
  '$tagDigest | split(" ") as $td | {
    ($serviceKey): {
      Tag: ($imgPrefix + ":" + $td[0]),
      Digest: ($imgPrefix + "@" + $td[1]),
    }
  }' | tee "/artifacts/$SERVICEKEY.json"
