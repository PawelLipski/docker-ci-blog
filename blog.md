# Nifty Docker tricks you'll crave to use in your CI!

`git machete`, having started as simple rebase automation tool, now developed into a full-fledged repository organizer with support for ... and even its own logo :)

https://github.com/VirtusLab/git-machete

See [https://medium.com/virtuslab/make-your-way-through-the-git-rebase-jungle-with-git-machete-e2ed4dbacd02](first part a guide on how to use the tool)

[https://medium.com/virtuslab/git-machete-strikes-again-traverse-the-git-rebase-jungle-even-faster-with-v2-0-f43ebaf8abb0](second part for more advanced features).

![https://github.com/VirtusLab/git-machete/blob/master/logo.png](git-machete)

The work being done is relatively easy, just two commands:
`debuild`
`dput`

The actual challenge is to create a Dockerized environment that allows for running this sequence... basically anywhere.

We're using Travis CI, but the effort needed to migrate the process to any other modern CI is minimal.


## Stack: launcher script for CI -> docker-compose.yml -> Dockerfile -> entrypoint script

ci/apt-ppa

`apt` stands for Advanced Package Tool, primary package manager for Debian-based distributions

`PPA` in turn comes from Personal Package Archive

https://launchpad.net/~virtuslab/+archive/ubuntu/git-machete/+packages

Other folders like `homebrew-tap` ... , but that process isn't particularly interesting from devops point of view and wont't be covered in this blogpost.


## Super-reusable image: mount repository as volume

Actually, building a separate image once the codebase changes even slightest...

Let's take a look into [ci/apt-ppa/docker-compose.yml]() (irrelevant parts has been skipped so that we can focus on `ppa-upload` service):

```yaml
version: '3'
services:
  ppa-upload:
    image: virtuslab/git-machete-ci-ppa-upload:${DOCKER_TAG:-latest}
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

Thus, the Docker image is not generated based on the state of the entire repo, just the ci/apt-ppa folder

This way a single image can be reused even as the codebase changes.

The only point when the image itself should be rebuild is when the contents of `ci/apt-ppa` change!
This is likely to be very rare compared to how often the actual codebase is going to change.

It would be nice if we somehow made CI aware that it doesn't need to build the image with every single build...


## Caching: rebuild image by folder on CI

Let's just take advantage of the fact that git hashes objects themselves...

More details can be found in [https://slides.com/plipski/git-internals/](this slide deck on git internals \(aka "git's guts"\)).

We need to descend to the _plumbing_ commands of git... one of the more powerful and versatile of them being `rev-parse`.

The syntax for getting hash for tree reminds that of `git show <revision>:<path>`:

`git rev-parse HEAD:ci/apt-ppa`

Note this hash is distinct from the resulting Docker image hash. 
Git object hashes are 160-bit (40 hex digit) SHA1 hashes, while Docker identifies images by their 256-bit (64 hex digit) SHA256 hash.

Let's peek into ci/apt-ppa/upload-travis.sh:
```shell script
...
# If the image corresponding to the current state of ci/apt-ppa/ is missing, build it and push to Docker Hub.
docker-compose pull ppa-upload || {
  docker-compose build --build-arg user_id="$(id -u)" --build-arg group_id="$(id -g)" ppa-upload
  echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
  docker-compose push ppa-upload
}
...
```

Now the first thing that happens is that we check (`docker-compose pull`) whether the image tagged with the git hash of ci/apt-ppa tree is already present on Docker Hub.

https://hub.docker.com/r/virtuslab/git-machete-ci-ppa-upload/tags

... accepts `user_id ` and `group_id`... we'll delve into that in the next section.


## Local runs: non-root user for local execs

As you remember from the previous sections, our entire setup assumes that a host `git-machete` directory is mounted as a volume inside the Docker container.

The problem is that unless explicitly told otherwise, everything in Docker container will be run as root.

Believe it or not, but any file that might be created inside the container... will not only be owned by root in the container, but also in the host!

This leads to a very annoying experience

Let's take a closer look now at [ci/apt-ppa/upload.Dockerfile](ci/apt-ppa/upload.Dockerfile):

```dockerfile
FROM ubuntu

RUN apt-get update && apt-get install -y debhelper devscripts fakeroot gawk python3-all python3-paramiko python3-setuptools

ARG user_id
ARG group_id

RUN "[" ${user_id:-0} -ne 0 ] \
    && [ ${group_id:-0} -ne 0 ] \
    && groupadd -g ${group_id} ci-user \
    && useradd -l -u ${user_id} -g ci-user ci-user \
    && install -d -m 0755 -o ci-user -g ci-user /home/ci-user

USER ci-user

RUN install -d -m 0700 ~/.gnupg/ ~/.gnupg/private-keys-v1.d/ ~/.ssh/

COPY upload-dput.cf /etc/dput.cf

COPY --chown=ci-user:ci-user upload-gpg-sign.sh /home/ci-user/gpg-sign.sh
RUN chmod +x ~/gpg-sign.sh

COPY --chown=ci-user:ci-user upload-release-notes-to-changelog.awk /home/ci-user/release-notes-to-changelog.awk

COPY --chown=ci-user:ci-user upload-entrypoint.sh /home/ci-user/entrypoint.sh
RUN chmod +x ~/entrypoint.sh
CMD ["/home/ci-user/entrypoint.sh"]

WORKDIR /home/ci-user/git-machete
```

Let's skip the familiar parts including 

.env-sample

for the sake of convenience, copied into .env

`install` is a very convenient and surprisingly obscure GNU utility that combines some of the most commonly used features of `cp`, `mkdir`, `chmod` and `chown`.

With a rather unusual syntax (rarely ... Unix-style options passed directly to Dockerfile directive), we need to pass `--chown` flag to `COPY`.
Otherwise, the files will be owned by `root:root`; the preceding `USER` directive unfortunately doesn't affect the default owner of `COPY`-ed (or `ADD`-ed, for that matter) files.

One can now ask... well, how come `ci-user` from inside the container can be in any way equal to an existing user on the host machine (esp. given that host most likely doesn't have a `ci-user` user or group)?

Well, actually it's the numeric id of user/group that matters; names are just aliases, and they can resolve differently on host machine and inside the container.

Even more surprisingly, if there was indeed a `ci-user` on host machine... that still completely wouldn't matter from the perspective of ownership of files generated within container ....


## Handling secrets: files encoded into env vars

The entrypoint script first "unpacks" the 

Note that every good CI should have a mechanism to mask the values 

Still a security issue: what if somebody simply base64-encodes the secret? Or reverses? or does anything else just to make ...

Travis CI by default blocks any usage of secret vars in PRs coming from forked repositories.

Note that it's not a problem in our case since the variables are only ever needed in case of deploy

upload-vars.env to avoid specifying the litany of variables in docker-compose.yml itself

upload-export-vars can be launched locally to load base64-encoded files into variables as expected by the entrypoint 
