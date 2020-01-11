#!/usr/bin/env bash

set -e -o pipefail -u

grep -Po '(?<=\]\().*//.*?(?=\))' blog.md | xargs -t -l curl -fsI -o/dev/null -w "> %{http_code}\n"
