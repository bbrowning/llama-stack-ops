#!/bin/bash

VERSION="0.2.9rc1"
if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
TEMPLATES=${TEMPLATES:-}
BUILD_PLATFORM=${BUILD_PLATFORM:-}

set -euo pipefail

release_exists() {
  local source=$1
  releases=$(curl -s https://${source}.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
  for release in $releases; do
    if [ x"$release" = x"$VERSION" ]; then
      return 0
    fi
  done
  return 1
}


if release_exists "test.pypi"; then
  echo "Version $VERSION found in test.pypi"
  PYPI_SOURCE="testpypi"
elif release_exists "pypi"; then
  echo "Version $VERSION found in pypi"
  PYPI_SOURCE="pypi"
else
  echo "Version $VERSION not found in either test.pypi or pypi" >&2
  exit 1
fi

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.10
source .venv/bin/activate

uv pip install --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  llama-stack==${VERSION}

which llama
llama stack list-apis

docker buildx ls

if [ -n "$BUILDER_NAME" ]; then
  echo "Using docker builder $BUILDER_NAME"
  export BUILDX_BUILDER="$BUILDER_NAME"
fi

build_and_push_docker() {
  template=$1

  echo "Building and pushing docker for template $template"

  for platform in "amd64" "arm64"; do
      # Build for the specific architecture
      export BUILD_PLATFORM="linux/$platform"
      # Load the built image from the builder to our docker images
      export CONTAINER_OPTS="${CONTAINER_OPTS:-} --load"
    if [ "$PYPI_SOURCE" = "testpypi" ]; then
      TEST_PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container
    else
      PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container
    fi
    docker images

    echo "Pushing docker image for ${platform} platform"
    if [ "$PYPI_SOURCE" = "testpypi" ]; then
      docker tag distribution-$template:test-${VERSION} bbrowning/distribution-$template:test-${VERSION}-${platform}
      docker push bbrowning/distribution-$template:test-${VERSION}-${platform}
    else
      docker tag distribution-$template:${VERSION} llamastack/distribution-$template:${VERSION}
      docker tag distribution-$template:${VERSION} llamastack/distribution-$template:latest
      docker push bbrowning/distribution-$template:${VERSION}
      docker push bbrowning/distribution-$template:latest
    fi
  done

  echo "Pushing multi-arch manifest list"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    docker buildx imagetools create \
      -t bbrowning/distribution-$template:test-${VERSION} \
      bbrowning/distribution-$template:test-${VERSION}-amd64 \
      bbrowning/distribution-$template:test-${VERSION}-arm64
  fi
}


if [ -z "$TEMPLATES" ]; then
  TEMPLATES=(ollama together fireworks bedrock remote-vllm tgi meta-reference-gpu)
else
  TEMPLATES=(${TEMPLATES//,/ })
fi

for template in "${TEMPLATES[@]}"; do
  build_and_push_docker $template
done

echo "Done"
