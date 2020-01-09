# cfgupdater

This document describes the cfgupdater service in detail.
Refer to [README.md](/README.md) for an overview of the overall patterns InfluxData uses for CD/GitOps.

## Overview

cfgupdater is implemented as a [GitHub App](https://developer.github.com/apps/).
The overall patterns would generally be the same if you were writing a service to interact with another source control provider.

The API endpoints look like:

- One endpoint to be triggered from `app`'s CI pipeline to announce a new set of images
- One set of endpoints to be triggered from Argo CD post sync hooks, to handle promoting images between environment sets
- One endpoint to receive GitHub webhooks for commit status updates on the cfg-app repository.

You will notice that the first two endpoints map to the "accessible entrypoints" of the config repository.
The third endpoint is so that we follow the 
["Not Rocket Science Rule of Software Engineering"](https://graydon.livejournal.com/186550.html)
by pushing automatic commits to a branch that is rebased on master,
and master is always fast-forwarded to a commit that has already passed CI.

## General Operation

We will assume that `master` is the branch of `cfg-app.git` that Argo CD observes,
and `auto` is the arbitrary branch that cfgupdater uses for its automatic commits.

cfgupdater creates commits on the auto branch and attempts to keep auto rebased on master.
Once CI reports a commit on the auto branch has passed,
cfgupdater can fast-forward the master branch to that commit.

The automatic commits have [trailers](https://git-scm.com/docs/git-interpret-trailers)
which are easily machine-parsed for fuller audit details.

## Implementation Details

The code for our cfgupdater implementation is not ready to share,
but I can share the fine details on exactly what git operations we take at each stage of the process.

The details are outlined as rough, untested shell scripts.
For any functions that start with `helper_`, see the Helpers section at the bottom of this document.

Assume that all scripts run in the root directory of the `cfg-app.git` working tree,
and that all scripts are run effectively as `set -euo pipefail`.

### Startup

The process clones the full `cfg-app.git` repository.
If the auto branch does not exist, it is created at the current commit at HEAD of master.

### New Images Published

When `app`'s CI pipeline finishes, it publishes a JSON object to cfgupdater that looks like:

```json
{
  "Service1": {
    "Digest": "docker.example.com/service1@sha256:6a9ca693f6fff83215c00b653bcf2106124705ad538dc509373523fdd6cefdb4",
    "Tag": "docker.example.com/service1:7d1043473d55bfa90e8530d35801d4e381bc69f0"
  },
  "Service2": {
    "Digest": "docker.example.com/service2@sha256:621f0ce9f70ad34dcc76d4b28c0e16ff30afa7f0318ec9ed85f9979255006a65",
    "Tag": "docker.example.com/service2:7d1043473d55bfa90e8530d35801d4e381bc69f0"
  }
}
```

Assumptions:
- cfgupdater saves that JSON input as a file `/tmp/images.json`.
- The full application SHA is available as `$APP_SHA`.

Then cfgupdater effectively runs:

```sh
helper_align_auto || helper_refresh

# Detach from the auto branch so that we don't have persist changes back to the branch
# until everything is done.
git checkout --detach auto || helper_refresh

# Apply the new images to the staging environment, and regenerate the YAML.
make introduce_images IMAGE_FILE=/tmp/images.json

# Format the commit message, and use commit -a to commit all changes to updated files.
git commit -a -m "chore: update app to ${APP_SHA:0:10}

Autocommit-App-SHA: $APP_SHA
Autocommit-Target: staging
Autocommit-Reason: new images published
"

# Set the branch back now that the commit is finalized.
git checkout -B auto HEAD

git push origin auto:auto
```

If you are concerned that your CI pipeline may replay a build,
this stage could see if the image has been published before by inspecting the output of
`git log --format='%(trailers:key=Autocommit-App-SHA,valueonly)' auto`.
However, note that this format style [requires git 2.22](https://github.com/git/git/blob/7a6a90c6ec48fc78c83d7090d6c1b95d8f3739c0/Documentation/RelNotes/2.22.0.txt#L21-L23) or newer,
and as of this writing, [the newest git you can apt-get install on Debian Buster or Stretch, even with backports, is git 2.20](https://unix.stackexchange.com/q/559437).

### CI Status Reported

We subscribe to GitHub webhook events for the `cfg-app.git` repository.

When GitHub reports the updated status for a commit, it includes the names of the branches that include the commit.
Pending statuses are ignored.
We only care about a particular set of status checks;
if they all pass, we can fast-forward master master to that commit,
or if any fail, we "evict" that commit from the auto branch.

In these flows we rely heavily on `git merge-base --is-ancestor` to check that commits are ordered as expectedc,
so you may want to read [its documentation](https://git-scm.com/docs/git-merge-base)
if you are unfamiliar with the command.

#### All Status Checks Passed

When all internally required status checks pass, we fast-forward master to that new commit.
Note that since GitHub reports a single status at a time, you may need to make a separate API call to GitHub to check whether the other required status checks have passed.

Assumptions:
- The commit whose status passed is available as `$GREEN_SHA`.

```sh
helper_align_auto || helper_refresh

# The commit must be on the auto branch.
git merge-base --is-ancestor $GREEN_SHA auto || helper_refresh

# And ensure master will be fast-forwarded the new commit.
# Note that if master is already on this commit, the command will still succeed.
# This is fine, as the later merge attempt and push will be a no-op.
git merge-base --is-ancestor master $GREEN_SHA || helper_refresh

git checkout master
git merge --ff-only $GREEN_SHA
git push origin master:master || helper_refresh
```

#### Any Status Check Failed

We need to rebase away the commit whose status failed.

Assumptions:
- The commit whose status failed is available as `$RED_SHA`.

```sh
helper_align_auto || helper_refresh

# $RED_SHA must be an ancestor of auto, and master must be an ancestor of $RED_SHA.
git merge-base --is-ancestor $RED_SHA auto || helper_refresh
git merge-base --is-ancestor master $RED_SHA || helper_refresh

# git merge-base --is-ancestor x y will exit 0 if x and y point at the same commit;
# so as one last sanity check, make sure master's commit isn't the same as $RED_SHA.
test "$(git rev-parse --verify master)" != "$RED_SHA" || helper_refresh

ORIG_AUTO_SHA="$(git rev-parse auto)"

# Rebase away the actual commit.
git rebase --onto "${RED_SHA}^" "$RED_SHA" auto || helper_refresh

# Force-push with lease our new auto ref.
git push --force-with-lease=auto:"$ORIG_AUTO_SHA" origin auto:auto || helper_refresh
```

### Helpers

Here are the details on the helpers referenced in the above implementation details.

#### `helper_align_auto`

The rebase at the end of `helper_align_auto` is likely the most brittle part of this git automation.

One potentially more intelligent solution would inspect the trailers on the commits in the auto branch,
and then "replay" those actions as new commits on master.

For now, we are using the rebase strategy, but we are specifically regenerating YAML,
as detailed in the README, rather than allowing the possibility of merge conflicts in those generated files.
Before rebasing, we run the appropriate `git config` commands to configure the custom merge driver.

```sh
MASTER_SHA="$(git rev-parse master)"
AUTO_SHA="$(git rev-parse auto)"

if [ "$MASTER_SHA" == "$AUTO_SHA" ]; then
  # Branches are aligned. Nothing to do.
  exit 0
fi

if git merge-base --is-ancestor "$AUTO_SHA" "$MASTER_SHA"; then
  # auto is an ancestor of master. Maybe someone pushed directly to master.
  # Locally reset the auto branch to match master.
  git branch -f auto master
  exit 0
fi

if git merge-base --is-ancestor "$MASTER_SHA" "$AUTO_SHA"; then
  # master is an ancestor of auto. That just means auto has advanced past master. This is fine.
  exit 0
fi

# At this point, master is not an ancestor of auto, nor vice versa.
# Try to rebase auto on master.
MERGE_BASE="$(git merge-base "$MASTER_SHA" "$AUTO_SHA")"
git rebase "$MASTER_SHA" auto
git push --force-with-lease=auto:"$AUTO_SHA" origin auto:auto
```

#### `helper_refresh`

This helper is run when a git command has failed, and it optimistically retries the entire script
after creating a fresh clone of the application git repository.

During the second run of the script, calls to `helper_refresh` have no effect.
An earlier error is simply returned.
