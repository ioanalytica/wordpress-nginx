#!/bin/bash
WP_VERSION="${WP_VERSION:-6.8.2}"
TAG=${WP_VERSION}-alpine-r6
PROD_IMAGE="harbor.ioanalytica.com/wordpress/wordpress-nginx:${TAG}"

# docker login harbor.ioanalytica.com
docker buildx build --platform linux/amd64,linux/arm64 -t ${PROD_IMAGE} --push --pull .
docker-squash.sh ${PROD_IMAGE} --platform linux/amd64,linux/arm64 -t ${PROD_IMAGE} --push

# end
