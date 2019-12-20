# CD/GitOps Reference Architecture

This is a logical overview of the CD/GitOps architecture in use at InfluxData,
to deploy our Cloud offering on many regions in many cloud providers.

We refer to this as CD/GitOps because this is a fusion of Continuous Deployment --
as in, every commit to master is delivered to production automatically --
with GitOps as popularized by Weaveworks, where a git repository is the source of truth for what is running in production.

If this topic interests you and you're interested in expanding and applying these ideas:
[InfluxData is hiring](https://grnh.se/ygda3s)!

## Overview

There are two git repositories of interest, dubbed `app.git` and `cfg-app.git` (pronounced "config app").

`app.git` is your actual application code.
In our engineering team, this is a monorepo, but few details should change if you have multiple repos.

`cfg-app.git` is the repository that contains your Kubernetes configurations.
Our repository is primarily Jsonnet, and we commit the generated YAML,
so that we can confidently write and review Jsonnet changes without being surprised by the effects.
Few details should change if you choose to use Helm, Kustomize, or comparable tools.

There is a separate service, which we will call `cfgupdater` (pronounced "config updater"),
that is responsible for creating automatic commits into `cfg-app`.
We do not have an open source implementation of this `cfgupdater` yet,
but it is described in considerable detail in [cfgupdater.md](/cfgupdater.md).

We are using Argo CD to apply changes from the `cfg-app` repo into the target environments.
We expect that few details would change if you were using Weaveworks Flux or the future Argo Flux product.

For a graphical overview of how the pieces interact, refer to [flowchart.txt](/flowchart.txt).

## Overall Patterns

We have three Waves of deployment targets, dubbed `Staging`, `Internal`, and `Production`.
Each wave may contain many targets (a target Namespace or collection of Namespaces,
in a particular Kubernetes cluster, in a particular cloud provider).

After a set of images is **successfully** deployed to the Staging targets,
those images are promoted to the Internal environment;
and after those images are all successfully deployed, the images are again promoted to Production.

These three waves are what we believe suits our circumstances,
but the pattern could be applied to any reasonable number of waves.

## Application Repository Patterns

### Docker Images

We decided that we want to build and tag Docker images for every new push to master of our application.
However, we do not want to needlessly deploy services that did not have a material change.
In other words, a README update should not cause a new Docker image to be built,
and a modification to a common library should only result in new Docker images for services that depend on the library.

We achieved this with a two-pronged approach:
reproducible builds of our services, and aggressive Docker caching.

#### Reproducible Builds

Our application monorepo happens to be written in Go, which makes it easy to achieve reproducible builds.

In general, given the same source code at the same path, Go will produce the same binary, bit-for-bit.
But there are a couple details to be aware of:

- Go embeds a "build ID" that differs per host. Fix it to be the empty string with `GOFLAGS='-ldflags=-buildid='`.
- In Go 1.13 and newer, you can use `-trimpath` so that the source directory where you're building isn't included in the debug info.
    If you are using an older version of Go, just be sure that the source code is in the same absolute path on any machine building the source code.
- If you are building in module mode, a module update that doesn't result in a material change can still affect the build.
    That is, if you upgrade module `foo` from v1.0 to v1.1, and foo/bar changes even though you don't reference that package,
    the debug information will differ between the two builds because of referencing `"foo@v1.0"` in one build and `"foo@v1.1"` in the next.
    You can avoid this problem if you build from the vendor directory, by not using modules at all, or by using `go mod vendor` and building with `-mod=vendor`.

#### Aggressive Docker Caching

There are likely several other valid approaches to achieve our goal
of building a Docker image on every commit to the master branch of `app`,
with the image digest only changing when the binary content has changed.
Here's how we are solving the problem.

We first build a single Docker image that contains all the binaries we will be shipping with our services.
(See [`docker/Dockerfile.base`](/docker/Dockerfile.base), which refers to [`scripts/build-cd-base.bash`](/scripts/build-cd-base.bash).)
Our real application builds over a dozen Go binaries,
so we want to build them together to take advantage of the Go build cache.
We are experimenting with Buildkit so that we can use a
[cache mount](https://github.com/moby/buildkit/blob/b939973129b3d1795988e685f07a50a2afe8a401/frontend/dockerfile/docs/experimental.md#run---mounttypecache)
and further speed up builds.

Then, our applications' Dockerfiles use `COPY --from` to copy the binaries from the base image.
We provide the base image as a build argument,
so that the application's Dockerfile isn't tightly coupled to that base image.
Assuming the base image produces reproducible builds, then `COPY --from` will copy the same file
and produce the same Docker image -- if and only if the previous image is available on the machine building the newer image.

If you have a Dockerfile that produces the same effective layers,
but you build the image on two different hosts without a common cache,
you will produce two different Docker images because of timestamps and other metadata in newly created layers.
To avoid this, you can tell Docker build to use a specific image as a cache source,
like `docker build --cache-from=docker.example.com/service:$PREV_IMAGE`.
But, if you are building on an ephemeral host,
you have to explicitly pull that Docker image to ensure that image is used as a cache.

In our setup, we tag the Docker images both with the full SHA of the app commit and with the source branch.
We considered using an abbreviated SHA, but decided on the full SHA because it is completely unambiguous.

See [`scripts/cd-base.bash`](/scripts/cd-base.bash) for our shell script that we run on CI to build the base images,
and [`scripts/cd-service.bash`](/scripts/cd-service.bash) for the similar shell script that we use to build the service-specific images.
The main difference in the scripts is that the service script stores an artifact containing the generated image tag and digest.
More on that in the section on Config Repository Patterns

## Config Repository Patterns

### Jsonnet

Jsonnet was a good fit for us, starting from scratch.
If you are currently using Helm or Kustomize or any other tool and you're happy with it, by all means keep using it.

Rather than discussing Jsonnet in detail here, I will link to two references on real world use of it:

- [Declarative Infrastructure with the Jsonnet Templating Language](https://databricks.com/blog/2017/06/26/declarative-infrastructure-jsonnet-templating-language.html)
- [Google SRE Workbook, Configuration Specifics](https://landing.google.com/sre/workbook/chapters/configuration-specifics/)

### Commit the Generated YAML

This is not strictly necessary, but we've decided to opt in to this pattern.

It is important that we not only commit the YAML, but that we confirm in CI
that the committed YAML is up to date.
By doing so, we can refactor and review changes to Jsonnet with full confidence in their effect on YAML.

Note that when Argo CD observes a directory, it will parse any Jsonnet
and it will interpret straight Kubernetes resources in YAML.
When we generate our YAML, we generate it into its own directory,
to avoid Argo CD giving warnings about duplicate resource definitions.

#### Regenerate YAML rather than risking merge conflicts

Most of the time, you're writing config changes against master, so there is little risk of merge conflict.
But every once in a while, you may have an old branch that needs to be rebased.
If you are automatically rebasing commits, such as the strategy mentioned in the cfgupdater document,
there will not be a human operator around to handle any merge conflicts.

Luckily, it's easy to instruct git to use [a custom merge driver](https://www.git-scm.com/docs/gitattributes#_defining_a_custom_merge_driver).
One simple approach looks like:

```sh
git config --local merge.regenerateyaml.name 'Regenerate YAML'
git config --local merge.regenerateyaml.driver 'make regenerate-single-yaml REGENERATE_YAML=%P GIT_MERGE_OUT=%A'
```

The `%P` argument is the path in the working tree of the file that had a conflict.
You may overwrite that file, but git also expects you to write the "merged" result to the `%A` argument.
If you don't do that, the current version of git gives a strange error like `error: add_cacheinfo failed to refresh for path`.

Finally, you must set up a .gitattributes entry like:

```
/generated/*/*.yml merge=regenerateyaml
```

This tells git to use the custom merge driver you configured earlier, when handling merges on files that match that pattern.

### Accessible Entrypoints to Config Operations

The primary config operation we have is regenerate the YAML after a manual Jsonnet change
or after an image definition file is updated.
This operation will frequently be run by humans,
but machines will tend to regenerate the YAMl indirectly by way of the secondary set of operations.

The secondary set of operations we have is image promotion between environments --
in our case, introducing new images to Staging, promoting images from Staging to Internal,
and promoting images from Internal to Production.
These operations will rarely be run by humans, frequently by machine.

We have Makefile targets for these operations, which call into shell scripts.
This way, our our `cfgupdater` application can be aware of just the make targets.
If we ever need to refactor to something other than a shell script,
the Makefile offers a layer of abstraction from those details.

### Machine-Updatable Image Definitions

As mentioned in the Accessible Entrypoints section,
our tooling needs to be able to introduce new images into the config repository.

Every set of images that may be updated at once, is defined in its own JSON object.
When we want to update that set of images, we overwrite the entire file with new values.
Then our Jsonnet imports the JSON file and exposes the specific images where they are needed in our configuration objects.

Because the images are delivered as a single unit, image promotion becomes a simple operation:

```sh
# Example of promoting images from Acceptance to Internal.
# Assumes the SHA of cfg-app.git that was successfully deployed to Acceptance is given as $DEPLOYED_SHA.
git show "$DEPLOYED_SHA":images/acceptance/tags.json > images/internal/tags.json
git show "$DEPLOYED_SHA":images/acceptance/digests.json > images/internal/digests.json
git commit -m 'Promoted deployed images to Internal...'
git push origin master
```

### Record Both the Docker Image Tag and its Digest

We intend to update the config repository for every commit to master of the application repository.
But we have many services that may be updated;
recording the digest of the image means that we can see, in the git diff, what services are expected to be affected by any image change.
Recording the image tag, which maps to the commit SHA in the application repository,
quickly indicates what source commit is currently deployed.

We use the image digests in the pod specs because we know them at the time of image build and push.
While a tag can be accidentally or maliciously modified, an image digest is immutable.

## cfgupdater

The cfgupdater service is primarily responsibile for creating automatic commits into the cfg-app.git repository.

It is implemented as an HTTP API to a [GitHub App](https://developer.github.com/apps/)
that creates and pushes commits to cfg-app.git, and observes the CI status of those commits before merging the commits to master.

Please refer to [flowchart.txt](/flowchart.txt) for an overview of how cfgupdater ties into the overall workflow.
