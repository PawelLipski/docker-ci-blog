
# Nifty Docker tricks you'll crave to use in your CI!

TODO: rework
TODO: rework
There is a multitude of content out there in the internet delving into the subject of Dockerized CIs,
but the piece that might be missing is a dissection of entire setup.

Either you have the vague feeling that your current CI setup can be improved but you're lacking the direction,

or maybe you see repetition between ??? local build setup and the CI, and despite the two being similar they still need to be maintained separately due to technical limitations ???

It's assumed you're familiar with concepts like Dockerfiles and docker-compose.
We'll take a closer look at the CI process for an open source tool being under active developed at VirtusLab.

[git machete](https://github.com/VirtusLab/git-machete), having started as simple rebase automation tool, now developed into a full-fledged repository organizer with support for ...
and even its own logo, namely git logo stylized as cut in the half :)

![git-machete](https://raw.githubusercontent.com/VirtusLab/git-machete/master/logo.png)

The purpose of the git-machete's CI is to ensure that it performs its basic functions correctly under a wide array of git and Python versions that the users might have on their machines.

Let's create a Dockerized environment that allows for running such tests both locally and on a CI.
We're using Travis CI specifically, but the effort needed to migrate the process to any other modern CI is minimal.

[https://travis-ci.org/VirtusLab/git-machete](https://travis-ci.org/VirtusLab/git-machete)

## The five-layered stack

Let's get this handy table first:

| File                               | Responsibility                                                       |
| ---                                | ---                                                                  |
| .travis.yml                        | Tells the CI to launch ci/tox/travis-{script,install}.sh             |
| ci/tox/travis-{script,install}.sh  | Runs docker-compose pull/build/push/up commands                      |
| ci/tox/docker-compose.yml          | Provides configuration for building the image/running the container  |
| ci/tox/Dockerfile                  | Stores recipe on how to build the Docker image                       |
| ci/tox/entrypoint.sh               | Serves as the entrypoint for the container                           |

As with any good stack, the layers are organized so that no layer needs to know anything about any layer above, only about the ones below (typically just one layer below and not more).


## Super-reusable image: mount repository as volume

Arguably, the most central part of the entire setup is the [Dockerfile](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/Dockerfile), let's start from there.

```dockerfile
FROM ubuntu:18.04

ARG git_version
RUN set -x \
    && apt-get update \
    && apt-get install -y autoconf gcc gettext libz-dev make unzip wget \
    && wget -q https://github.com/git/git/archive/v$git_version.zip \
    && unzip -q v$git_version.zip \
    && rm v$git_version.zip \
    && cd git-$git_version \
    && make configure \
    && ./configure \
    && make \
    && make install \
    && git --version \
    && cd .. \
    && rm -rf git-$git_version/ \
    && apt-get purge -y autoconf gcc gettext libz-dev make unzip wget \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

ARG python_version
ENV PYTHON_VERSION=${python_version}
ENV PYTHON="python${python_version}"
RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get purge -y software-properties-common \
    && apt-get autoremove -y \
    && PYTHON_MAJOR=${python_version%.*} \
    && if [ "$PYTHON_MAJOR" -eq 2 ]; then apt-get install -y --no-install-recommends gcc{PYTHON}-dev python-pip; fi \
    && if [ "$PYTHON_MAJOR" -eq 3 ]; then apt-get install -y --no-install-recommends python3-pip; fi \
    && apt-get install -y --no-install-recommendsPYTHON \
    &&PYTHON -m pip install setuptools six wheel \
    &&PYTHON -m pip install tox \
    && rm -rf /var/lib/apt/lists/*

ARG user_id
ARG group_id
RUN "["{user_id:-0} -ne 0 ] \
    && [{group_id:-0} -ne 0 ] \
    && groupadd -g{group_id} ci-user \
    && useradd -l -u{user_id} -g ci-user ci-user \
    && install -d -m 0755 -o ci-user -g ci-user /home/ci-user
USER ci-user
COPY --chown=ci-user:ci-user entrypoint.sh /home/ci-user/entrypoint.sh
RUN chmod +x ~/entrypoint.sh
ENTRYPOINT /home/ci-user/entrypoint.sh
WORKDIR /home/ci-user/git-machete
```

Let's leave the third section (the one with `user_id` and `group_id` ARGs) aside for a moment, we'll come back there later. 

The purpose of the first two sections is to set up git and Python in the desired versions.
The non-obvious part here are very long chains of `&&`-ed shell commands under `RUN`, some of which are, surprisingly, related to _removing_ rather than installing software 
(`apt-get purge`, `apt-get autoremove`, `rm -rf`).
Two questions arise: why combine so many commands into a single `RUN` rather than split them into mutliple `RUN`s and why remove the software?
Docker stores data in layers that correspond to Dockerfile instructions. 
If an instruction (typically `RUN` or `COPY`) adds data to the underlying file system (which is typically OverlayFS in modern setting, by the way),
this data will remain a part of the layer and thus of the resulting image - even if it's later removed in a subsequent layer.
The only way to deal with that limitation is to remove the no longer necessary files in the same layer as they were added.
Hence, the first `RUN` instruction installs all of `autoconf gcc gettext libz-dev make unzip wget`, necessary to build git from source, only to later remove it.
What survives in the resulting layer is only the git installation that we care for, but not the GNU toolchain necessary to arrive at this installation in the first place 
(but otherwise useless in the final image). 
When all the dependencies are installed at the very beginning and never removed, the image reaches almost 1GB.
After including the `apt-get purge` and `apt-get autoremove` commands, and squeezing the installations and removals into the same layer,
it went down to around 250-300MB, depending on exact git and Python version.

Now please note that Dockerfile doesn't refer to any portion of the project's codebase other than to entrypoint.sh.
The trick is that the entire codebase is mounted as a volume to the _container_ rather than baked into the image!
Let's take a closer look at [ci/tox/docker-compose.yml](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/docker-compose.yml)
which provides the recipe on how to configure the image build and how to run the container.
By the way, since the YML itself is located in ci/tox/, the paths are also relative to ci/tox/ rather than to the project root.

```yaml
version: '3'
services:
  tox:
    image: virtuslab/git-machete-ci-tox:${DOCKER_TAG:-latest}
    build:
      context: .
      args:
        - user_id=${USER_ID:-0}
        - group_id=${GROUP_ID:-0}
        - git_version=${GIT_VERSION:-0.0.0}
        - python_version=${PYTHON_VERSION:-0.0.0}
    volumes:
      -{PWD}/../..:/home/ci-user/git-machete
```

Let's skip the `image:` section and where `DOCKER_TAG` comes from for a moment, we'll delve into that later.

As `volumes:` section indicates, the entire codebase is mounted under `WORKDIR` (/home/ci-user/git-machete/) inside the container.
`PYTHON_VERSION` and `GIT_VERSION` variables, that translate to build args `python_version` and `git_version`,
are provided by Travis based on the configuration in [.travis.yml](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/.travis.yml),
here shown redacted for brevity:

```yaml
os: linux
language: minimal
env:
  - PYTHON_VERSION=2.7 GIT_VERSION=2.0.0
  - PYTHON_VERSION=2.7 GIT_VERSION=2.7.1
  - PYTHON_VERSION=3.6 GIT_VERSION=2.20.1
  - PYTHON_VERSION=3.8 GIT_VERSION=2.24.1 DEPLOY=true

install: bash ci/tox/travis-install.sh

script: bash ci/tox/travis-script.sh

.... skipped ....
```

The parts of the pipeline that actually take the contents of the mounted volume into account
are located in the [ci/tox/entrypoint.sh](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/entrypoint.sh) script:

```shell script
#!/usr/bin/env bash

{ [[ -f setup.py ]] && grep -q "name='git-machete'" setup.py; } || {
  echo "Error: the repository should be mounted as a volume under(pwd)"
  exit 1
}

set -e -u -x

TOXENV="pep8,py${PYTHON_VERSION/./}" tox
$PYTHON setup.py install --user
PATH=$PATH:~/.local/bin/
git machete --version
```

It's first checking if the git-machete repo has really been mounted, an subsequently fires 
the all-encompassing [`tox`](https://tox.readthedocs.io/en/latest/) command that runs code style check, tests etc.


## Caching: rebuild image by folder on CI

It would be nice to cache the images that generated, so that CI doesn't need to build the image the same image over and over again.
That caching was by the way also the purpose of the intense size optimization outlined in the previous section.

Let's think for a moment what are the characteristic features that make one generated image different from another.

TODO!! dockerignore for the dirs
TODO!! dockerignore for the dirs
TODO!! dockerignore for the dirs + rework the sections below

We obviously have to take into account git and Python version - passing a different combination of those will surely result in a different final image.
But with respect to project files... since it's ci/tox/ that's passed as build context, Dockerfile doesn't know anything about the files from outside ci/tox/!
This means that even if other project files change (which is, well, inevitable when the project is being developed), we can use the same image as long as ci/tox/ remains untouched.
Note that the changes to ci/tox/ are likely to be very rare compared to how often the rest of codebase is going to change.

The little catch here is that not just the different build context that can change the final Docker image;
Dockerfile, docker-compose.yml and even the scripts that run `docker-compose` can also influence the result.
This is, however, 
Anyway, the entire resulting build image depends only on the contents of ci/tox/ directory
(with one reservation that packages installed via apt-get can also get updated over time in their respective APT repositories).

Specifically:
* the entrypoint script is directly copied from ci/tox/entrypoint.sh,
* the recipe for Docker on build the image (subject to parametrization, including build context/arguments) is stored in ci/tox/Dockerfile,
* the parametrization of the build (context, args, Dockerfile to use) is included in ci/tox/docker-compose.yml,
* the recipe on how to run the container given the image (volumes to mount, env file) is also included in ci/tox/docker-compose.yml,
* finally, even the way of invoking the high-level docker-compose commands themselves is also located within ci/tox as travis-script.sh and travis-install.sh.

Given all that, what if we just computed the hash of the entire ci/tox/ directory and used it to identify the image?
Actually, we don't even need to compute that hash ourselves!
We can take advantage of SHA-1 hashes that git computes for each object.
It's a well known fact that each commit in git has a unique hash, but actually SHA-1 hashes are also derived for each file (called _blob_ in gitspeak) and each directory (called _tree_).
Hash of a tree is a function of hashes of all its underlying blobs and, recursively, trees.
More details can be found in [this slide deck on git internals (aka "git's guts")](https://slides.com/plipski/git-internals/).
For our use case it means that once any file inside ci/tox changes, we'll end up with a different Docker image tag!

To extract the hash of given directory within the current commit (HEAD),
we need to resort to a one of the more powerful and versatile _plumbing_ commands of git called `rev-parse`:

```shell script
git rev-parse HEAD:ci/tox
```

The `<revision>:<path>` syntax might be familiar from `git show`.

Note that obviously this hash is distinct from the resulting Docker image hash.
Git object hashes are 160-bit (40 hex digit) SHA-1 hashes, while Docker identifies images by their 256-bit (64 hex digit) SHA-256 hash.

Let's now peek into [ci/tox/travis-install.sh](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/travis-install.sh):

```shell script
...
DOCKER_TAG=git${GIT_VERSION}-python${PYTHON_VERSION}-$(git rev-parse HEAD:ci/tox)
export DOCKER_TAG
cd ci/tox

# If the image corresponding to the expected git&python versions and the current state of ci/tox is missing, build it and push to Docker Hub.
docker-compose pull tox || {
  docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" tox
  # In builds coming from forks, secret vars are unavailable for security reasons; hence, we have to skip pushing the newly built image.
  [[ -nDOCKER_PASSWORD && -nDOCKER_USERNAME ]] && {
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    docker-compose push tox
  }
}
```

We cook up the `DOCKER_TAG` (remember? it's referenced under `image` in docker-compose.yml!)
from the 3 variables that we need to take into account: git version, Python version and git hash of ci/tox directory.

Now the first thing that happens is that we check (`docker-compose pull`) whether the image with the given tag already present
in the [virtuslab/git-machete-ci-tox repository on Docker Hub](https://hub.docker.com/r/virtuslab/git-machete-ci-tox/tags).

If `docker-compose pull` returns a non-zero exit code, then it means no build has ever run so far for the given combination of
git version, Python version and contents of ci/tox directory - we need to build it now on this build.

Note that `docker-compose build` accepts `user_id ` and `group_id` build arguments... we'll delve into that in the next section.

Later we log in to Docker Hub and push the image.
A little catch here - Travis completely forbids the use of secret variables in builds coming from forks.
Even though Travis masks the _exact_ matches of a secret value, it can't prevent a malicious "contributor" from printing e.g. base64-encoded 
(or otherwise reversibly transformed) secret directly to the build logs, which would constitute an obvious security breach.
Thus, we need to make sure that the Docker credentials are indeed available in the environment; otherwise, we refrain from pushing the image.

Note that using `docker-compose`, although not strictly necessary for our use case, saves us from specifying the same parameters over and over again.
If we were to use just plain `docker pull/build/push` instead of their `docker-compose` counterparts,
we'd need to pass e.g. the image name and tag every single time.

Having the image in place (either just being built or, hopefully, pulled from Docker Hub), running the tests is easy:

[ci/tox/travis-script.sh](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/travis-script.sh)

```shell script
... skipped ...

docker-compose up --exit-code-from=tox tox
```

The `--exit-code-from=` option to `docker-compose up` is relatively unknown, yet crucial in automated workflows.
By default, `docker-compose up` does not return the exit code of any of the launched services, just zero (assuming it launched all the services successfully).
This would lead to CI pipelines falsely passing even when `tox` (and thus the entire entrypoint script) fails.
We have to explicitly pick the service whose exit code should serve as the exit code of the entire `docker-compose up` command.
The likely rationale for that option not being the default is that `up` can run more than one service at once (esp. when `depends_on` mechanism is involved)
and it wouldn't be obvious the exit code of which service should be selected. 


## Local runs: non-root user for local execs

To run the tests locally:

`docker-compose up --build tox`

Here we don't even need to resort to an external registry like Docker Hub, we can just rely on local Docker cache to remember the already constructed layers.
As you remember from the previous sections, our entire setup assumes that a host `git-machete` directory is mounted as a volume inside the Docker container.
The problem is that unless explicitly told otherwise, every command in Docker container is as root user.
By default any file that might be created inside the running container will be owned by root not only in the container... but also in the host!
This leads to a very annoying experience - all the files that are usually generated by the build (like `build/` and `dist/` directories in case of Python, or `target/` for JVM tools)
will belong to root:

![root owned folders](root-owned-folders.png)

If only Docker provided the option to run commands as non-root user...

Let's take a look again at [ci/tox/Dockerfile](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/Dockerfile), this time on the bottom part:
```dockerfile
# ... git & python installation - skipped ...

ARG user_id
ARG group_id
RUN "["{user_id:-0} -ne 0 ] \
    && [{group_id:-0} -ne 0 ] \
    && groupadd -g{group_id} ci-user \
    && useradd -l -u{user_id} -g ci-user ci-user \
    && install -d -m 0755 -o ci-user -g ci-user /home/ci-user
USER ci-user
COPY --chown=ci-user:ci-user entrypoint.sh /home/ci-user/entrypoint.sh
RUN chmod +x ~/entrypoint.sh
ENTRYPOINT /home/ci-user/entrypoint.sh
WORKDIR /home/ci-user/git-machete
```

We first run `groupadd` and `useradd` to create the user.
Home folder is created with a single invocation of `install`, a very convenient and surprisingly obscure GNU utility 
that combines some of the most commonly used features of `cp`, `mkdir`, `chmod` and `chown`.
A single `install` invocation creates the home folder and ensures proper ownership and access modes.

Now the entire trick is to fill up the `user_id` and `group_id` ARGs with user and group id of the your user on your machine.
On a modern Linux, it's likely 1000 (`UID_MIN` and `GID_MIN` in /etc/login.defs) if you have just one user on your machine.
CI is no special case - we'd fill those arguments with the CI user/group id, whatever it might be (for Travis they actually both turn out to be 2000).

Setting the ARGs themselves, however, is approached slightly differently for local builds (using .env file that hard-codes the ids into environment variables, see [ci/tox/.env-sample](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/.env-sample))
and on CI (where we explicitly pass the result of Unix command `id -u` as `user_id` and the result of `id -g` as `group_id` in `docker-compose build`, see [ci/tox/travis-install.sh](https://github.com/VirtusLab/git-machete/blob/chore/ci-multiple-git-versions/ci/tox/travis-install.sh)).

Now we switch away from `root` to the newly-created user by calling `USER ci-user`.

With a rather unusual syntax (we rarely see Unix-style `--something` options accepted directly by a Dockerfile instruction), we need to pass `--chown` flag to `COPY`.
Otherwise, the files would end up owned by `root:root`.
The preceding `USER` instruction unfortunately doesn't affect the default owner of `COPY`-ed (or `ADD`-ed, for that matter) files.

One can now ask... well, how come `ci-user` from inside the container can be in any way equivalent to an existing user on the host machine (esp. given that host most likely doesn't have a `ci-user` user or group)?

Well, actually it's the numeric id of user/group that matters; names on Unix systems are just aliases, and they can resolve differently on host machine and inside the container.
As a consequence, if there was indeed a `ci-user` on host machine... that still completely wouldn't matter from the perspective of ownership of files generated within container -
still, the only thing that matters is the numeric id.

Now after firing `docker-compose up --build tox` we can observe that all files generated inside the volume are owned by the host user:

![user owned folders](user-owned-folders.png)


## Summary/conclusions

We've taken a look at the entire stack used for building and testing the branches,
but there is also a similar setting for deployment (only executed for git tags) in [ci/apt-ppa](https://github.com/VirtusLab/git-machete/tree/master/ci/apt-ppa) directory,
specifically for upload of Debian packages to  [PPA (Personal Package Archive) for Ubuntu](https://launchpad.net/~virtuslab/+archive/ubuntu/git-machete/+packages).
From the technical perspective, the only significantly different point is more prevalent use of secrets (for GPG and SSH).

For more details on git-machete tool itself, see
[first part of a guide on how to use the tool](https://medium.com/virtuslab/make-your-way-through-the-git-rebase-jungle-with-git-machete-e2ed4dbacd02) and
[second part for the more advanced features](https://medium.com/virtuslab/git-machete-strikes-again-traverse-the-git-rebase-jungle-even-faster-with-v2-0-f43ebaf8abb0).

Contributions (and stars on Github!) are more then welcome, especially if you're proficient with production use of Python or with the internals of git.
