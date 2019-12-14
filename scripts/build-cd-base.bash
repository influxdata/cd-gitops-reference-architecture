#!/bin/bash

# This script is called from Dockerfile.cd to build all of the necessary commands in one base image,
# so that we amortize compile costs.
# Then, downstream images can simply copy their binary from this base image.

set -eux

if [ -z "$APP_BIN_DEST" ]; then
	# Requiring the output as an explicit argument,
	# so the script can be run in container or on workstation.
	>&2 echo '$APP_BIN_DEST must be set as destination directory for built binaries.'
	exit 1
fi

# Sanity checks.
if [ ! -f go.mod ]; then
	>&2 echo 'This script must be run from the root of the app repository.'
	exit 1
fi
modheader="$(head -n 1 go.mod)"
if [ "$modheader" != 'module example.com/app' ]; then
	>&2 echo 'go.mod detected, but it does not appear to be the app module.'
	exit 1
fi

# All of the commands we are going to build, as a bash array.
# There are some that we will never build, so we whitelist required builds instead of using ./cmd/... .
cmds=(
	foo
	bar
	baz
)

# Common go flags to the upcoming go build commands.
export CGO_ENABLED=0 GOOS=linux GO111MODULE=on

# GOFLAGS is special.
# We always want -mod=vendor in this script.
# We want to hardcode an empty buildid so that builds are bit-for-bit identical.
# See https://github.com/golang/go/issues/33772.
# After upgrading to Go 1.13, it will probably make sense to add -trimpath.
export GOFLAGS='-mod=vendor -ldflags=-buildid='

# Helpful log output to see the exact version of Go used.
go version

# Build ./cmd/foo for foo in $cmds (https://stackoverflow.com/a/12744170).
# And build it as one command, to maximize concurrency.
# When we switch to Go 1.13, we can use "-o $dir" to emit all the executables,
# but until then, we build once to warm the cache and then emit the individual binaries.
# Run with time just for simple insight on how long this takes.
time go build "${cmds[@]/#/./cmd/}"

# Again, this can be refactored away after we move to Go 1.13.
for cmd in ${cmds[@]}; do
	time go build -o "$APP_BIN_DEST/$cmd" "./cmd/$cmd"
done

# If you run this script on your workstation, you probably don't want to blow away your go cache.
# But if you run it in a Docker container, the cache just wastes disk space / image size.
# (Variable expansion with defaulting, to avoid an unset variable error.)
if [ -n "${CLEAN_GOCACHE:-}" ]; then
	go clean -cache
fi
