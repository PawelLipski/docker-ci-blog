
# Nifty Docker tricks you'll crave to use in your CI!

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

Arguably, the most central part of the entire setup is the [Dockerfile](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/Dockerfile), let's start from there.

```dockerfile
FROM ubuntu

RUN apt-get update && apt-get install -y autoconf gcc gettext libz-dev make python-pip python3-pip software-properties-common unzip wget
RUN add-apt-repository ppa:deadsnakes/ppa
RUN apt-get update

ARG git_version
RUN wget -q https://github.com/git/git/archive/v$git_version.zip
RUN unzip -q v$git_version.zip
WORKDIR git-$git_version
RUN make configure
RUN ./configure
RUN make
RUN make install
RUN git --version

ARG python_version
ENV PYTHON_VERSION=${python_version}
ENV PYTHON="python${python_version}"
RUN apt-get install -y $PYTHON
RUN $PYTHON -m pip install tox

ARG user_id
ARG group_id

RUN "[" ${user_id:-0} -ne 0 ] \
    && [ ${group_id:-0} -ne 0 ] \
    && groupadd -g ${group_id} ci-user \
    && useradd -l -u ${user_id} -g ci-user ci-user \
    && install -d -m 0755 -o ci-user -g ci-user /home/ci-user

USER ci-user

COPY --chown=ci-user:ci-user entrypoint.sh /home/ci-user/entrypoint.sh
RUN chmod +x ~/entrypoint.sh
ENTRYPOINT /home/ci-user/entrypoint.sh

WORKDIR /home/ci-user/git-machete
```

The first three sections are just for setting up git and Python in the desired versions and aren't particularly interesting.
The only worth noting here is that the heaviest operation of installing the software necessary for the build 

Actually, it goes without saying that we shouldn't building a separate image every time any portion of the codebase changes - this would be completely contrary ???? 

TODO: screenshot from Travis build!

We'll return to the upper layers (.travis.yml and ci/tox/travis-*.sh) in a second,
let's first take a closer look at [ci/tox/docker-compose.yml](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/docker-compose.yml):

```yaml
version: '3'
services:
  tox:
    image: virtuslab/git-machete-ci-tox:${DOCKER_TAG:-latest}
    build:
      context: .
      dockerfile: upload.Dockerfile
      args:
        - user_id=${USER_ID:-0}
        - group_id=${GROUP_ID:-0}
    volumes:
      - ${PWD}/../..:/home/ci-user/git-machete
    env_file:
      - upload-vars.env
```

We'll explain the exact rationale behind `args` and `env_file` later.
Let's now focus on `context`, `dockerfile` and `volumes` sections.


TODO fill up


The entire codebase is mounted under /home/ci-user/git-machete/ inside the container.

There's a slight catch here: we also mount the ci/tox/ directory that we previously passed as build context to the image as a part of this volume...
but this doesn't make much difference inside the container anyway.

Now one thing we didn't cover is where `DOCKER_TAG` comes from and how it's generated...

Let's think for a moment what are the characteristic features that distinguish one build image from another.

Take into account git and Python version and have a separate image for each tested combination.

Thus, the Docker image is not generated based on the state of the entire repo, just the ci/tox folder

This way a single image can be reused even as the codebase changes.

The only point when the image itself should be rebuild is when the contents of `ci/tox` change!
This is likely to be very rare compared to how often the actual codebase is going to change.

The parts that depend on the rest of repository are actually happening in the [ci/tox/entrypoint.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/entrypoint.sh) script:

```shell script
#!/usr/bin/env bash

{ [[ -f setup.py ]] && grep -q "name='git-machete'" setup.py; } || {
  echo "Error: the repository should be mounted as a volume under $(pwd)"
  exit 1
}

set -e -u -x

TOXENV="pep8,py${PYTHON_VERSION/./}" tox
$PYTHON setup.py install --user
PATH=$PATH:~/.local/bin/
git machete --version
```

We're first checking if the git-machete repo has really been mounted, an subsequently run the magic `tox` command that runs code style check, tests etc.

Python (of version `$PYTHON_VERSION`) and git (also in its own specified version) are already installed.

Now given that we separated the things that are likely to change TODO... cache the images TODO

It would be nice if we somehow made CI aware that it doesn't need to build the image that if a similar build already happened in the past...


## Caching: rebuild image by folder on CI

Well, the key observation is that the entire resulting build image depends only on the contents of ci/tox/ directory
(with one reservation that packages installed via apt-get can also get updated over time in their respective APT repositories).

Specifically:
* the entrypoint script is directly copied from ci/tox/entrypoint.sh,
* the recipe for Docker on build the image (subject to parametrization, including build context/arguments) is stored in ci/tox/Dockerfile,
* the parametrization of the build (context, args, Dockerfile to use) is included in ci/tox/docker-compose.yml,
* the recipe on how to run the container given the image (volumes to mount, env file) is also included in ci/tox/docker-compose.yml,
* finally, even the way of invoking the high-level docker-compose commands themselves is also located within ci/tox as travis-script.sh and travis-install.sh.

Given all that, what if we just computed the hash of the entire ci/tox/ directory and appended to the docker image tag?
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

An excerpt from [.travis.yml](https://github.com/VirtusLab/git-machete/blob/master/.travis.yml), slightly redacted for brevity:

```yaml
os: linux
language: minimal
env:
  - PYTHON_VERSION=2.7 GIT_VERSION=2.0.0
  - PYTHON_VERSION=2.7 GIT_VERSION=2.7.1
  - PYTHON_VERSION=2.7 GIT_VERSION=2.20.1
  - PYTHON_VERSION=3.6 GIT_VERSION=2.20.1
  - PYTHON_VERSION=3.6 GIT_VERSION=2.24.1
  - PYTHON_VERSION=3.8 GIT_VERSION=2.20.1
  - PYTHON_VERSION=3.8 GIT_VERSION=2.24.1

install: bash ci/tox/travis-install.sh

script: bash ci/tox/travis-script.sh

.... skipped ....
```

Let's now peek into [ci/tox/travis-install.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/travis-install.sh):

```shell script
...
DOCKER_TAG=git${GIT_VERSION}-python${PYTHON_VERSION}-$(git rev-parse HEAD:ci/tox)
export DOCKER_TAG
cd ci/tox

# If the image corresponding to the expected git&python versions and the current state of ci/tox is missing, build it and push to Docker Hub.
docker-compose pull tox || {
  docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" tox
  # In builds coming from forks, secret vars are unavailable for security reasons; hence, we have to skip pushing the newly built image.
  [[ -n $DOCKER_PASSWORD && -n $DOCKER_USERNAME ]] && {
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    docker-compose push tox
  }
}

```

We construct the docker image hash including the 3 variables that we need to take into account: git version, Python version and git hash of ci/tox directory used to build the image.

Now the first thing that happens is that we check (`docker-compose pull`) whether the image with the given tag already present in the [virtuslab/git-machete-ci-tox repository on Docker Hub](https://hub.docker.com/r/virtuslab/git-machete-ci-tox/tags).

If `docker-compose pull` returns a non-zero exit code, then it means no build has ever run so far for the given combination of git version, Python version and contents of ci/tox directory - we need to build it now on this build.

Note that `docker-compose build` accepts `user_id ` and `group_id` build arguments... we'll delve into that in the next section.

Later we log in to Docker Hub and push the image.
A little catch here - Travis completely forbids the use of secret variables in builds coming from forks.
Even though Travis masks the exact matches of a secret value, it can't prevent a malicious "contributor" from printing e.g. base64-encoded (or otherwise transformed) secret directly to the build logs,
which would an obvious security breach.
Thus, we need to make sure that the Docker credentials are indeed available in the environment; otherwise, we skip the push.

Note that using `docker-compose` saves us from specifying the same parameters over and over again.
If we were to use just plain `docker pull/build/push` instead of their `docker-compose` counterparts,
we'd need to specify e.g. the image name/tag every single time.

Having the image in place (either just being built, or, hopefully, pulled from Docker Hub), running the tests is easy:

[ci/tox/travis-script.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/travis-script.sh)

```shell script
... skipped ...

docker-compose up --exit-code-from=tox tox
```

The `--exit-code-from=` option to `docker-compose up` is relatively unknown, yet crucial in automated workflows.
By default, `docker-compose up` does not return the exit code of any of the launched services, just zero (assuming it launched all the services successfully).
This would lead to falsely passing pipelines.
We have to explicitly pick the service whose exit code should serve as the exit code of the entire command.
The likely rationale for that option not being the default is that `up` can run more than one service at once (esp. when `depends_on` mechanism is involved)
and it wouldn't be obvious which service should be special one ???


## Local runs: non-root user for local execs

To run the tests locally:

`docker-compose up --build tox`

Here we don't even need to resort to an external registry like Docker Hub, we can just rely on local Docker cache to remember the already built images.

As you remember from the previous sections, our entire setup assumes that a host `git-machete` directory is mounted as a volume inside the Docker container.

The problem is that unless explicitly told otherwise, everything in Docker container will be run as root.

By default any file that might be created inside the running container will not only be owned by root in the container, but also in the host!

This leads to a very annoying experience - all the files that are usually generated by the build (like `build/` and `dist/` directories in case of Python, or `target/` for JVM tools)
will be owned by the root:

![root owned folders](root-owned-folders.png)

What if only Docker provided the option to run commands as non-root user...

Let's take a closer look now at [ci/tox/Dockerfile](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/Dockerfile).
The parts where git and Python are installed are skipped since they're not of much interest for us here.

```dockerfile
FROM ubuntu

# ... git & python installation - skipped ...

ARG user_id
ARG group_id

RUN "[" ${user_id:-0} -ne 0 ] \
    && [ ${group_id:-0} -ne 0 ] \
    && groupadd -g ${group_id} ci-user \
    && useradd -l -u ${user_id} -g ci-user ci-user \
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

Now the entire trick is to fill up the `user_id` and `group_id` ARGs with user and group id of the your user on your machine (likely 1000 if you have just one user).
CI is no special case - we'd fill those arguments with the CI user/group id, whatever it might be (for Travis they both turn out to be 2000).

Setting the ARGs itself, however, is approached slightly differently for local builds (using .env file that hard-codes the ids into environment variables, see [ci/tox/.env-sample](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/.env-sample))
and on CI (where we explicitly pass the result of Unix command `id -u` as `user_id` and the result of `id -g` as `group_id` in `docker-compose build`, see [ci/tox/travis-install.sh](https://github.com/VirtusLab/git-machete/blob/master/ci/tox/travis-install.sh)).

Now we switch away from `root` to the newly-created user by calling `USER ci-user`.

With a rather unusual syntax (we rarely see Unix-style `--something` options accepted directly by a Dockerfile directive), we need to pass `--chown` flag to `COPY`.
Otherwise, the files will be owned by `root:root`; the preceding `USER` directive unfortunately doesn't affect the default owner of `COPY`-ed (or `ADD`-ed, for that matter) files.

One can now ask... well, how come `ci-user` from inside the container can be in any way equivalent to an existing user on the host machine (esp. given that host most likely doesn't have a `ci-user` user or group)?

Well, actually it's the numeric id of user/group that matters; names on Unix systems are just aliases, and they can resolve differently on host machine and inside the container.

As a consequence, if there was indeed a `ci-user` on host machine... that still completely wouldn't matter from the perspective of ownership of files generated within container -
still, the only thing that matters is the numeric id.

Now after firing `docker-compose up tox` we can observe that all files generated inside the volume are owned by the host user:

![user owned folders](user-owned-folders.png)


## Summary/conclusions

We've taken a look at the entire stack used for testing,
but there is also a similar setting for deployment in [ci/apt-ppa](https://github.com/VirtusLab/git-machete/tree/master/ci/apt-ppa) directory, specifically for upload of Debian packages to 
[PPA (Personal Package Archive) for Ubuntu](https://launchpad.net/~virtuslab/+archive/ubuntu/git-machete/+packages).
From the technical perspective, the only significantly different point is more prevalent use of secrets (for GPG ans SSH).

For more details on git-machete tool itself, see
[first part a guide on how to use the tool](https://medium.com/virtuslab/make-your-way-through-the-git-rebase-jungle-with-git-machete-e2ed4dbacd02) and
[second part for more advanced features](https://medium.com/virtuslab/git-machete-strikes-again-traverse-the-git-rebase-jungle-even-faster-with-v2-0-f43ebaf8abb0).

Contributions (and stars on Github!) are more then welcome, esp. if you're proficient with production use of Python.
