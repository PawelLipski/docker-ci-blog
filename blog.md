
# Nifty Docker tricks you'll crave to use in your CI!

If you're running Dockerized jobs in your CI (or considering migration to Docker-based flow),
it's very likely that some (if not most) of the techniques outlined in this blog post will prove very useful.

We'll take a closer look at the CI process for an open source tool, [git machete](https://github.com/VirtusLab/git-machete), being under active development at VirtusLab.
Having started as a simple rebase automation tool, it has now grown into a full-fledged Git repository organizer.
It even acquired its own logo, stylized as the original Git logo with extra forks, slashed in half.

![git-machete](https://raw.githubusercontent.com/VirtusLab/git-machete/master/logo.png)

The purpose of the git-machete's CI is to ensure that it performs its basic functions correctly under
a wide array of Git and Python versions that the users might have on their machines.
In this blog post, we're going to create a Dockerized environment that allows for running such functional tests both locally and in CI.
We're using [Travis CI](https://travis-ci.org/VirtusLab/git-machete) specifically, but the effort needed to migrate the entire configuration to any other modern CI is minimal.

This article assumes that you're familiar with concepts like [Dockerfiles](https://docs.docker.com/engine/reference/builder/)
and [docker-compose](https://docs.docker.com/compose/).


## High-level overview of the setup

Let's start with the project layout (also available [on Github](https://github.com/VirtusLab/git-machete)):

![project layout](project-layout.png)

The files that are particularly relevant to us:

| File                               | Responsibility                                                       |
| ---                                | ---                                                                  |
| .travis.yml                        | Tells the CI to launch ci/tox/travis-{script,install}.sh             |
| ci/tox/travis-{script,install}.sh  | Runs docker-compose pull/build/push/up commands                      |
| ci/tox/docker-compose.yml          | Provides configuration for building the image/running the container  |
| ci/tox/Dockerfile                  | Stores recipe on how to build the Docker image                       |
| ci/tox/build-context/entrypoint.sh | Serves as the entrypoint for the container                           |


## Reducing image size: keep each layer small

The central part of the entire setup is the [Dockerfile](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/Dockerfile).

```dockerfile
ARG python_version
FROM python:${python_version}-alpine
RUN ln -s /usr/local/bin/python /usr/bin/python

ARG git_version
RUN set -x \
    && apk add --no-cache --virtual git-build-deps  alpine-sdk autoconf gettext wget zlib-dev \
    && wget -q https://github.com/git/git/archive/v$git_version.tar.gz \
    && tar xzf v$git_version.tar.gz \
    && rm v$git_version.tar.gz \
    && cd git-$git_version/ \
    && make configure \
    && ./configure \
    && make \
    && make install \
    && cd .. \
    && rm -r git-$git_version/ \
    && git --version \
    && apk del git-build-deps \
    && rm -rfv /usr/local/bin/git-shell /usr/local/share/git-gui/ \
    && cd /usr/local/libexec/git-core/ \
    && rm -fv git-credential-* git-daemon git-fast-import git-http-backend git-imap-send git-remote-testsvn git-shell

# ... skipped ...
```

We'll return to the skipped parts later when dealing with non-root user setup.

The purpose of the second section (the one with `git_version` ARG) is to install Git in a specific version.
The non-obvious step here is the very long chain of `&&`-ed shell commands under `RUN`, some of which, surprisingly, relate to _removing_ rather than installing software (`apk del`, `rm`).
Two questions arise: why combine so many commands into a single `RUN` rather than split them into multiple `RUN`s and why even remove any software at all?

Docker stores the image contents in layers that correspond to Dockerfile instructions.
If an instruction (usually `RUN` or `COPY`) adds data to the underlying file system (which is typically [OverlayFS](https://docs.docker.com/storage/storagedriver/overlayfs-driver/) nowadays, by the way),
this data, even if it's later removed in a subsequent layer, will remain a part of the layer corresponding to the instruction, and will thus make its way to the final image.

If a piece of software (like `alpine-sdk`) is only needed for building the image but not for running the container, then leaving it installed is an utter waste of space.
A reasonable (but not the only one &mdash; see the [multistage builds](https://docs.docker.com/develop/develop-images/multistage-build/)) way to prevent the resulting image from bloating
is to remove unnecessary files in the very same layer as they were added.
Hence, the first `RUN` instruction installs all of `alpine-sdk autoconf gettext wget zlib-dev`, necessary to build Git from source, only to later remove it (`apk del`) in the same shell script.
What survives in the resulting layer is only the Git installation that we care for, but not the toolchain necessary to arrive at this installation in the first place
(but which would otherwise be useless in the final image).

A more na&iuml;ve version of this Dockerfile, with all the dependencies installed at the very beginning and never removed, yields an almost 800MB behemoth:

![docker images](docker-images.png)

After including the `apk del` and `rm` commands, and squeezing the installations and removals into the same layer,
the resulting image shrinks to around 150-250MB, depending on the exact Git and Python version.
This makes caching the images far less space-consuming.

As a side note, if you're curious how I figured out which files (`git-fast-import`, `git-http-backend` etc.) to remove from /usr/local/libexec/git-core/,
take a look at [dive](https://github.com/wagoodman/dive), an excellent tool for inspecting files residing within each layer of a Docker image.


## Making the image reusable: mount a volume instead of `COPY`

It would be very handy if the same image could be used to test multiple versions of the code without having to rebuild the image.
In order to achieve that, the Dockerfile doesn't `COPY` the entire project directory into the image (only the entrypoint script is directly copied).
The codebase is instead mounted as a volume within the container rather than baked into the image.
Let's take a closer look at [ci/tox/docker-compose.yml](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/docker-compose.yml),
which provides the recipe on how to configure the image build and how to run the container.

```yaml
version: '3'
services:
  tox:
    image: virtuslab/git-machete-ci-tox:git${GIT_VERSION}-python${PYTHON_VERSION}-${DIRECTORY_HASH}
    build:
      context: build-context
      dockerfile: ../Dockerfile # relative to build-context
      args:
        - user_id=${USER_ID:-0}
        - group_id=${GROUP_ID:-0}
        - git_version=${GIT_VERSION:-0.0.0}
        - python_version=${PYTHON_VERSION:-0.0.0}
    volumes:
      # Host path is relative to current directory, not build-context
      - ../..:/home/ci-user/git-machete
```

We'll return to the `image:` section and explain the origin of `DIRECTORY_HASH` later.

As the `volumes:` section indicates, the entire git-machete codebase is mounted under /home/ci-user/git-machete/ inside the container.
`PYTHON_VERSION` and `GIT_VERSION` variables, which correspond to `python_version` and `git_version` build args,
are provided by Travis based on the configuration in [.travis.yml](https://github.com/VirtusLab/git-machete/blob/master/.travis.yml),
here redacted for brevity:

```yaml
os: linux
language: minimal
env:
  - PYTHON_VERSION=2.7 GIT_VERSION=1.7.10  # Earliest version of git supported by git-machete
  - PYTHON_VERSION=2.7 GIT_VERSION=2.7.6
  - PYTHON_VERSION=3.6 GIT_VERSION=2.20.2
  - PYTHON_VERSION=3.8 GIT_VERSION=2.25.0 DEPLOY_ON_TAGS=true

install: bash ci/tox/travis-install.sh

script: bash ci/tox/travis-script.sh

# ... skipped ...
```

(Yes, we still keep [Python 2 support](https://pythonclock.org/)...
but nevertheless, if you still use Python 2, please upgrade your software!)

The part of the pipeline that actually takes the contents of the mounted volume into account
is located in the [ci/tox/build-context/entrypoint.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/build-context/entrypoint.sh) script
that is `COPY`-ed into the image:

```bash
#!/bin/sh

{ [ -f setup.py ] && grep -q "name='git-machete'" setup.py; } || {
  echo "Error: the repository should be mounted as a volume under $(pwd)"
  exit 1
}

set -e -u -x

$PYTHON -m pip install --user tox
TOXENV="pep8,py${PYTHON_VERSION/./}" tox

$PYTHON setup.py install --user
git machete --version
```

It first checks if the git-machete repo has really been mounted under the current working directory, then fires
the all-encompassing [`tox`](https://tox.readthedocs.io/en/latest/) command that runs code style check, tests etc.


## Caching the images: make use of Docker tags

It would be nice to cache the generated images, so that CI doesn't need to build the same stuff over and over again.
By the way, the purpose of the intense image size optimization outlined previously is also to facilitate caching.

Think for a moment what specifically makes one generated image different from another.
We obviously have to take into account different versions of Git and Python &mdash; passing different combinations of these will surely result in a different final image.
These versions should therefore be included in the Docker image tag to make the caching possible.

But with respect to project files... since it's ci/tox/build-context that's passed as build context,
the Dockerfile doesn't know anything about the files from outside the ci/tox/build-context!
This means that even if other files change (which is inevitable as the project is being developed),
we could theoretically use the same image as long as ci/tox/build-context remains untouched.
Note that the changes to ci/tox/build-context are likely to be very rare compared to how often the rest of the codebase is likely to change.

There's a catch here, though.
The build context is not the only thing that can affect the final Docker image.
A change to the Dockerfile itself can obviously lead to a different result,
but modification to docker-compose.yml and even the scripts that run `docker-compose` may also influence the result e.g. by changing environment variables and/or values passed as arguments.
But since all those files reside under ci/tox/, this doesn't make things much worse &mdash;
the entire resulting build image depends only on the contents of ci/tox/ directory instead of ci/tox/build-context/
(with one exception that packages installed via apt-get can also get updated over time in their respective APT repositories).

Given all that, what if we just computed the hash of the entire ci/tox/ directory and used it to identify the image?
Actually, we don't even need to derive that hash ourselves!
We can take advantage of SHA-1 hashes that git computes for each object.
It's a well known fact that each commit in git has a unique hash, but actually SHA-1 hashes are also derived for each file (called a _blob_ in gitspeak) and each directory (called a _tree_).
The hash of a tree is a function of the hashes of all of its underlying blobs and, recursively, trees.
More details can be found in [this slide deck on git internals (aka "git's guts")](https://slides.com/plipski/git-internals/).
For our use case it means that once any file inside ci/tox/ changes, we'll end up with a different Docker image tag.

To extract the hash of a given directory within the current commit (HEAD),
we need to resort to one of the more powerful and versatile _plumbing_ commands of git called `rev-parse`:

```bash
git rev-parse HEAD:ci/tox
```

The `<revision>:<path>` syntax might be familiar from `git show`.

Note that this hash is different from the resulting Docker image hash.
Also, git object hashes are 160-bit (40 hex digit) SHA-1 hashes, while Docker identifies images by their 256-bit (64 hex digit) SHA-256 hash.

Back into [ci/tox/docker-compose.yml](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/docker-compose.yml) for a moment:

```yaml
version: '3'
services:
  tox:
    image: virtuslab/git-machete-ci-tox:git${GIT_VERSION}-python${PYTHON_VERSION}-${DIRECTORY_HASH}
# ... skipped ...
```

We already know that `GIT_VERSION` and `PYTHON_VERSION` are set up directly by Travis based on values specified in .travis.yml.
Let's peek into [ci/tox/travis-install.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/travis-install.sh) to see where `DIRECTORY_HASH` comes from:

```bash
# ... skipped ...

DIRECTORY_HASH=$(git rev-parse HEAD:ci/tox)
export DIRECTORY_HASH
cd ci/tox/

# If the image corresponding to the expected git&python versions and the current state of ci/tox is missing, build it and push to Docker Hub.
docker-compose pull tox || {
  docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" tox
  # In builds coming from forks, secret vars are unavailable for security reasons; hence, we have to skip pushing the newly built image.
  if [[ ${DOCKER_PASSWORD-} && ${DOCKER_USERNAME-} ]]; then
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    docker-compose push tox
  fi
}
```

Once we've got the directory hash at hand, the first thing that happens is that we check (`docker-compose pull`) whether the image with the given tag is already present
in the [virtuslab/git-machete-ci-tox repository on Docker Hub](https://hub.docker.com/r/virtuslab/git-machete-ci-tox/tags).

If `docker-compose pull` returns a non-zero exit code, then it means no build so far has been executed for the given combination of
Git version, Python version and contents of ci/tox directory, or an error occurred while pulling.
In either case, we need to construct the image from scratch.

Note that `docker-compose build` accepts `user_id ` and `group_id` build arguments... we'll cover that in the next section.

Once the image is built, we log in to Docker Hub and perform a `docker-compose push`.
A little catch here: Travis completely forbids the use of secret variables in builds that are triggered by forks.
Even though Travis masks the _exact matches_ of a secret value in build logs, it can't prevent a malicious "contributor" from printing e.g. base64-encoded
(or otherwise reversibly transformed) secret, which would constitute an obvious security breach.
Thus, we need to make sure that the Docker credentials are indeed available in the environment; otherwise, we refrain from pushing the image.

Note that using `docker-compose`, although not strictly necessary for our use case, saves us from specifying the same parameters over and over again.
If we were to use just plain `docker pull/build/push` instead of their `docker-compose` counterparts,
we'd need to supply e.g. the image name and tag every single time.

Once we have the image in place (either just being built or, hopefully, pulled from Docker Hub),
running the tests is easy, see [ci/tox/travis-script.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/travis-script.sh):

```bash
# ... skipped ...

docker-compose up --exit-code-from=tox tox
```

The `--exit-code-from=` option of `docker-compose up` is relatively unknown, yet crucial in automated workflows.
By default, `docker-compose up` returns zero regardless of the exit codes of the launched services.
This leads to CI pipelines falsely succeeding even when `tox` (and thus the entire entrypoint script) fails.
We have to explicitly pick the service whose exit code should serve as the exit code for the entire `docker-compose up` command.
One of the likely rationales for that option not being the default is that `up` can run more than one service at once (esp. when `depends_on` mechanism is involved)
and it wouldn't be obvious the exit code of which service should be selected.


## Running the build locally: configure a non-root user

To run the tests locally:

```bash
cd ci/tox
cp .env-sample .env  # and optionally edit if needed to change git/python version
./local-run.sh
```

[ci/tox/local-run.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/local-run.sh) is somewhat similar to how things are run on Travis:

```bash
# ... skipped ...

function build_image() {
  docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" tox
}

cd "$(git rev-parse --show-toplevel)"/ci/tox/
check_var GIT_VERSION
check_var PYTHON_VERSION

set -x

if git diff-index --quiet HEAD .; then
  DIRECTORY_HASH=$(git rev-parse HEAD:ci/tox)
  export DIRECTORY_HASH
  docker-compose pull tox || build_image
else
  export DIRECTORY_HASH=unspecified
  build_image
fi

docker-compose up --exit-code-from=tox tox
```

We're just doing more sanity checks like whether variables are defined (`check_var`) and whether there are any uncommitted changes (`git diff-index`).
Also, we don't attempt to push the freshly-built image to Docker Hub since we can rely on a local build cache instead.

As you remember from the previous sections, our entire setup assumes that the git-machete directory from the host is mounted as a volume inside the Docker container.
The problem is that, unless explicitly told otherwise, every command in the Docker container is executed with root user privileges.
By default, any file that might be created by the container inside a volume will be owned by root not only in the container... but also in the host!
This leads to a very annoying experience: all the files that are usually generated by the build (like `build/` and `dist/` directories in case of Python, or `target/` for JVM tools)
will belong to root:

![root owned folders](root-owned-folders.png)

If only Docker had an option to run commands as a non-root user...

Let's take a look again at [ci/tox/Dockerfile](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/Dockerfile), this time the bottom part:
```dockerfile
# ... git & python setup - skipped ...

ARG user_id
ARG group_id
RUN set -x \
    && [ ${user_id:-0} -ne 0 ] \
    && [ ${group_id:-0} -ne 0 ] \
    && addgroup --gid=${group_id} ci-user \
    && adduser --uid=${user_id} --ingroup=ci-user --disabled-password ci-user
USER ci-user
ENV PATH=$PATH:/home/ci-user/.local/bin/
COPY --chown=ci-user:ci-user entrypoint.sh /home/ci-user/
RUN chmod +x ~/entrypoint.sh
CMD ["/home/ci-user/entrypoint.sh"]
WORKDIR /home/ci-user/git-machete
```

The trick is to fill up the `user_id` and `group_id` ARGs passed to `addgroup` and `adduser` with user and group id of your user on your machine &mdash;
that's exactly what happens in `function build_image` in ci/tox/local-run.sh: `docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" tox`.
On modern Linuxes, they're both likely 1000 (see `UID_MIN` and `GID_MIN` in /etc/login.defs) if you have just one user on your machine.
CI is no special case &mdash; we fill those arguments with the CI user/group id, whatever it might be (on Travis they both turn out to be 2000).

We switch from `root` to the newly-created user by calling `USER ci-user`.

Using rather unusual syntax (Unix-style `--something` options are rarely passed directly to a Dockerfile instruction), we need to specify `--chown` flag for `COPY`.
Otherwise, the files would end up owned by `root:root`.
The preceding `USER` instruction, unfortunately, doesn't affect the default owner of `COPY`-ed (or `ADD`-ed, for that matter) files.

One can now ask... how come `ci-user` from inside the container can be in any way equivalent to an existing user on the host machine
(esp. given that the host most likely doesn't have a `ci-user` user or group)?

Well, actually it's the numeric id of user/group that matters; names on Unix systems are just aliases,
and they can resolve differently on the host machine and inside the container.
As a consequence, if there was indeed a user called `ci-user` on the host machine...
that still completely wouldn't matter from the perspective of ownership of files generated within a container &mdash;
still, the only thing that matters is the numeric id.

Now after launching `./local-run.sh` we can observe that all files generated inside the volume are owned by the currently logged-in host user:

![user owned folders](user-owned-folders.png)


## Summary: where to look next

We've taken a look at the entire stack used for building and testing git branches.
There is also a similar setting for uploading Debian packages to [PPA (Personal Package Archive) for Ubuntu](https://launchpad.net/~virtuslab/+archive/ubuntu/git-machete/+packages)
in [ci/apt-ppa-upload](https://github.com/VirtusLab/git-machete/tree/master/ci/apt-ppa-upload) directory,
which is only executed for git tags.
From a technical perspective, the only significantly different point is more prevalent use of secrets (for GPG and SSH).

For more details on git-machete tool itself, see
the [first part of a guide on how to use the tool](https://medium.com/virtuslab/make-your-way-through-the-git-rebase-jungle-with-git-machete-e2ed4dbacd02) and
the [second part for the more advanced features](https://medium.com/virtuslab/git-machete-strikes-again-traverse-the-git-rebase-jungle-even-faster-with-v2-0-f43ebaf8abb0).

Contributions (and stars on Github) are more than welcome!
