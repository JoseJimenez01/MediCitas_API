#!/bin/sh
set -eu
if [ "${INITIALIZE_DATABASE:-true}" = "true" ]; then
  dotnet Project_Restaurant_API.dll --initialize-only
fi
unset DB_BOOTSTRAP_USER DB_BOOTSTRAP_PASSWORD DB_BOOTSTRAP_CONNECTION
export INITIALIZE_DATABASE=false
exec dotnet Project_Restaurant_API.dll "$@"
