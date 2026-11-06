#!/usr/bin/env bash
# Measures image size before and after the multi-stage build, for the README.
#
# "Naive" is what a first attempt usually looks like: the full Python base image, the whole
# directory copied in, and pip's cache left behind. "Single-stage slim" changes only the base
# image, which separates what the slim base saves from what the multi-stage build saves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mib() { docker image inspect "$1" --format '{{.Size}}' | awk '{printf "%.0f MiB", $1/1048576}'; }
disk() { docker images "$1" --format '{{.Size}}'; }

printf '%-8s %-20s %-16s %s\n' SERVICE VARIANT COMPRESSED ON-DISK
for service in api worker; do
  module="leadpipe_${service}"
  if [[ "${service}" == "api" ]]; then
    run='["uvicorn", "--factory", "leadpipe_api.main:create_app", "--host", "0.0.0.0"]'
  else
    run='["python", "-m", "leadpipe_worker.main"]'
  fi

  for variant in naive slim; do
    base="python:3.13"
    [[ "${variant}" == "slim" ]] && base="python:3.13-slim"
    context="${WORK}/${service}-${variant}"
    mkdir -p "${context}"
    cp -r "${ROOT}/app/${service}/requirements.txt" "${ROOT}/app/${service}/tests" \
      "${ROOT}/app/${service}/${module}" "${context}/"
    cat >"${context}/Dockerfile" <<EOF
FROM ${base}
WORKDIR /app
COPY . .
RUN pip install --require-hashes -r requirements.txt
CMD ${run}
EOF
    docker build --quiet --tag "leadpipe-size/${service}:${variant}" "${context}" >/dev/null
  done
  docker build --quiet --tag "leadpipe-size/${service}:multi-stage" "${ROOT}/app/${service}" >/dev/null

  for variant in naive slim multi-stage; do
    image="leadpipe-size/${service}:${variant}"
    printf '%-8s %-20s %-16s %s\n' "${service}" "${variant}" "$(mib "${image}")" "$(disk "${image}")"
  done
done

docker rmi --force \
  leadpipe-size/api:naive leadpipe-size/api:slim leadpipe-size/api:multi-stage \
  leadpipe-size/worker:naive leadpipe-size/worker:slim leadpipe-size/worker:multi-stage >/dev/null
