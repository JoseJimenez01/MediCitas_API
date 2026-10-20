#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
kind delete cluster --name restaurant-api
