#!/usr/bin/env bash
set -e

PROJECT=nextcloud
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_TAG=docker_build
BUILD_WORKINGDIR=${BUILD_WORKINGDIR:-.}
DOCKERFILE=${DOCKERFILE:-Dockerfile-15}
VCS_REF=${TRAVIS_COMMIT::8}
RUNNING_TIMEOUT=120
RUNNING_LOG_CHECK="php entered RUNNING state"

PUSH_LATEST=${PUSH_LATEST:-true}
DOCKER_USERNAME=${DOCKER_USERNAME:-crazymax}
DOCKER_LOGIN=${DOCKER_LOGIN:-crazymax}
DOCKER_REPONAME=${DOCKER_REPONAME:-nextcloud}
QUAY_USERNAME=${QUAY_USERNAME:-crazymax}
QUAY_LOGIN=${QUAY_LOGIN:-crazymax}
QUAY_REPONAME=${QUAY_REPONAME:-nextcloud}

# Check local or travis
BRANCH=${TRAVIS_BRANCH:-local}
if [[ ${TRAVIS_PULL_REQUEST} == "true" ]]; then
  BRANCH=${TRAVIS_PULL_REQUEST_BRANCH}
fi
DOCKER_TAG=${BRANCH:-local}
if [[ "$BRANCH" == "master" ]]; then
  DOCKER_TAG=latest
elif [[ "$BRANCH" == "local" ]]; then
  BUILD_DATE=
  VERSION=local
fi

echo "PROJECT=${PROJECT}"
echo "VERSION=${VERSION}"
echo "BUILD_DATE=${BUILD_DATE}"
echo "BUILD_TAG=${BUILD_TAG}"
echo "BUILD_WORKINGDIR=${BUILD_WORKINGDIR}"
echo "DOCKERFILE=${DOCKERFILE}"
echo "VCS_REF=${VCS_REF}"
echo "PUSH_LATEST=${PUSH_LATEST}"
echo "DOCKER_LOGIN=${DOCKER_LOGIN}"
echo "DOCKER_USERNAME=${DOCKER_USERNAME}"
echo "DOCKER_REPONAME=${DOCKER_REPONAME}"
echo "QUAY_LOGIN=${QUAY_LOGIN}"
echo "QUAY_USERNAME=${QUAY_USERNAME}"
echo "QUAY_REPONAME=${QUAY_REPONAME}"
echo "TRAVIS_BRANCH=${TRAVIS_BRANCH}"
echo "TRAVIS_PULL_REQUEST=${TRAVIS_PULL_REQUEST}"
echo "BRANCH=${BRANCH}"
echo "DOCKER_TAG=${DOCKER_TAG}"
echo

# Build
echo "### Build"
docker build \
  --build-arg BUILD_DATE=${BUILD_DATE} \
  --build-arg VCS_REF=${VCS_REF} \
  --build-arg VERSION=${VERSION} \
  -t ${BUILD_TAG} -f ${DOCKERFILE} ${BUILD_WORKINGDIR}
echo

echo "### Test"
docker rm -f ${PROJECT} ${PROJECT}-db > /dev/null 2>&1 || true
docker network rm ${PROJECT} > /dev/null 2>&1 || true
docker network create -d bridge ${PROJECT}
docker run -d --network=${PROJECT} --name ${PROJECT}-db --hostname ${PROJECT}-db \
  -e "MYSQL_ALLOW_EMPTY_PASSWORD=yes" \
  -e "MYSQL_DATABASE=nextcloud" \
  -e "MYSQL_USER=nextcloud" \
  -e "MYSQL_PASSWORD=asupersecretpassword" \
  mariadb:10.2
docker run -d --network=${PROJECT} --link ${PROJECT}-db -p 8000:80 \
  -e "DB_HOST=${PROJECT}-db" \
  -e "DB_NAME=nextcloud" \
  -e "DB_USER=nextcloud" \
  -e "DB_PASSWORD=asupersecretpassword" \
  --name ${PROJECT} ${BUILD_TAG}
echo

echo "### Waiting for ${PROJECT} to be up..."
TIMEOUT=$((SECONDS + RUNNING_TIMEOUT))
while read LOGLINE; do
  echo ${LOGLINE}
  if [[ ${LOGLINE} == *"${RUNNING_LOG_CHECK}"* ]]; then
    echo "Container up!"
    break
  fi
  if [[ $SECONDS -gt ${TIMEOUT} ]]; then
    >&2 echo "ERROR: Failed to run ${PROJECT} container"
    docker rm -f ${PROJECT} ${PROJECT}-db > /dev/null 2>&1 || true
    exit 1
  fi
done < <(docker logs -f ${PROJECT} 2>&1)
echo

CONTAINER_STATUS=$(docker container inspect --format "{{.State.Status}}" ${PROJECT})
if [[ ${CONTAINER_STATUS} != "running" ]]; then
  >&2 echo "ERROR: Container ${PROJECT} returned status '$CONTAINER_STATUS'"
  docker rm -f ${PROJECT} ${PROJECT}-db > /dev/null 2>&1 || true
  exit 1
fi
docker rm -f ${PROJECT} ${PROJECT}-db > /dev/null 2>&1 || true

if [ "${VERSION}" == "local" -o "${TRAVIS_PULL_REQUEST}" == "true" ]; then
  echo "INFO: This is a PR or a local build, skipping push..."
  exit 0
fi
if [[ ! -z ${DOCKER_PASSWORD} ]]; then
  echo "### Push to Docker Hub..."
  echo "$DOCKER_PASSWORD" | docker login --username "$DOCKER_LOGIN" --password-stdin > /dev/null 2>&1
  if [ "${DOCKER_TAG}" == "latest" -a "${PUSH_LATEST}" == "true" ]; then
    docker tag ${BUILD_TAG} ${DOCKER_USERNAME}/${DOCKER_REPONAME}:${DOCKER_TAG}
  fi
  if [[ "${VERSION}" != "latest" ]]; then
    docker tag ${BUILD_TAG} ${DOCKER_USERNAME}/${DOCKER_REPONAME}:${VERSION}
  fi
  docker push ${DOCKER_USERNAME}/${DOCKER_REPONAME}
  if [[ ! -z ${MICROBADGER_HOOK} ]]; then
    echo "Call MicroBadger hook"
    curl -X POST ${MICROBADGER_HOOK}
    echo
  fi
  echo
fi
if [[ ! -z ${QUAY_PASSWORD} ]]; then
  echo "### Push to Quay..."
  echo "$QUAY_PASSWORD" | docker login quay.io --username "$QUAY_LOGIN" --password-stdin > /dev/null 2>&1
  if [ "${DOCKER_TAG}" == "latest" -a "${PUSH_LATEST}" == "true" ]; then
    docker tag ${BUILD_TAG} quay.io/${QUAY_USERNAME}/${QUAY_REPONAME}:${DOCKER_TAG}
  fi
  if [[ "${VERSION}" != "latest" ]]; then
    docker tag ${BUILD_TAG} quay.io/${QUAY_USERNAME}/${QUAY_REPONAME}:${VERSION}
  fi
  docker push quay.io/${QUAY_USERNAME}/${QUAY_REPONAME}
  echo
fi
