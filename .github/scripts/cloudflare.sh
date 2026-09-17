#!/usr/bin/env bash
# Idempotent Cloudflare provisioning for the deploy workflow.
#
#   cloudflare.sh account    resolve CLOUDFLARE_ACCOUNT_ID (-> $GITHUB_ENV)
#   cloudflare.sh provision  create D1 / R2 / Vectorize / workers.dev subdomain /
#                            Pages project if missing (-> $GITHUB_OUTPUT)
#   cloudflare.sh secrets    make sure the Worker has its secrets
#
# Only needs CLOUDFLARE_API_TOKEN; everything else has a default below.
set -euo pipefail

API=https://api.cloudflare.com/client/v4
D1_NAME=${D1_NAME:-chiphealth}
R2_BUCKET=${R2_BUCKET:-chiphealth-media}
VECTORIZE_INDEX=${VECTORIZE_INDEX:-chiphealth-food}
VECTORIZE_DIMENSIONS=${VECTORIZE_DIMENSIONS:-1024}
WORKER_NAME=${WORKER_NAME:-chiphealth-api}
PAGES_PROJECT=${PAGES_PROJECT:-chiphealth-admin}
# Most users are in Vietnam.
LOCATION_HINT=${LOCATION_HINT:-apac}

out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }
die() { echo "::error::$*" >&2; exit 1; }

# cf METHOD PATH [JSON] -> prints the response body; never fails on HTTP status,
# callers inspect .success / .errors themselves.
cf() {
  local args=(-sS -X "$1" "$API$2" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
  [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data "$3")
  curl "${args[@]}"
}

# Like cf, but dies unless the call succeeded.
cf_ok() {
  local res
  res=$(cf "$@")
  if [ "$(jq -r '.success' <<<"$res")" != "true" ]; then
    die "Cloudflare API $1 $2 failed: $(jq -c '.errors' <<<"$res" 2>/dev/null || echo "$res")"
  fi
  echo "$res"
}

acct() { echo "/accounts/$CLOUDFLARE_ACCOUNT_ID"; }

cmd_account() {
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "Missing secret CLOUDFLARE_API_TOKEN"
  # The workflow passes the optional secret as CF_ACCOUNT_ID so the value written
  # to $GITHUB_ENV below never competes with a YAML-level env of the same name.
  CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-${CF_ACCOUNT_ID:-}}
  if [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    local ids
    ids=$(cf_ok GET '/accounts?per_page=50' | jq -r '.result[].id')
    [ "$(wc -w <<<"$ids")" = "1" ] \
      || die "Token sees $(wc -w <<<"$ids") accounts; set secret CLOUDFLARE_ACCOUNT_ID"
    CLOUDFLARE_ACCOUNT_ID=$ids
  fi
  echo "CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID" >> "${GITHUB_ENV:-/dev/null}"
}

ensure_d1() {
  local id
  id=$(cf_ok GET "$(acct)/d1/database?name=$D1_NAME&per_page=100" \
    | jq -r --arg n "$D1_NAME" '.result[] | select(.name == $n) | .uuid' | head -1)
  if [ -z "$id" ]; then
    echo "Creating D1 database $D1_NAME"
    id=$(cf_ok POST "$(acct)/d1/database" \
      "$(jq -nc --arg n "$D1_NAME" --arg l "$LOCATION_HINT" '{name: $n, primary_location_hint: $l}')" \
      | jq -r '.result.uuid')
  fi
  echo "D1 $D1_NAME = $id"
  out d1_id "$id"
}

ensure_r2() {
  if [ "$(cf GET "$(acct)/r2/buckets/$R2_BUCKET" | jq -r '.success')" != "true" ]; then
    echo "Creating R2 bucket $R2_BUCKET"
    cf_ok POST "$(acct)/r2/buckets" \
      "$(jq -nc --arg n "$R2_BUCKET" --arg l "$LOCATION_HINT" '{name: $n, locationHint: $l}')" >/dev/null
  fi
  echo "R2 bucket $R2_BUCKET ready"
  out r2_bucket "$R2_BUCKET"
}

ensure_vectorize() {
  local base
  base="$(acct)/vectorize/v2/indexes"
  if [ "$(cf GET "$base/$VECTORIZE_INDEX" | jq -r '.success')" != "true" ]; then
    echo "Creating Vectorize index $VECTORIZE_INDEX"
    cf_ok POST "$base" "$(jq -nc --arg n "$VECTORIZE_INDEX" --argjson d "$VECTORIZE_DIMENSIONS" \
      '{name: $n, config: {dimensions: $d, metric: "cosine"}}')" >/dev/null
  fi
  # queryVectors() filters on metadata.namespace, which only works once a
  # metadata index exists (and only for vectors written after it).
  if ! cf_ok GET "$base/$VECTORIZE_INDEX/metadata_index/list" \
      | jq -e '.result.metadataIndexes // [] | any(.propertyName == "namespace")' >/dev/null; then
    echo "Creating Vectorize metadata index on namespace"
    cf_ok POST "$base/$VECTORIZE_INDEX/metadata_index/create" \
      '{"propertyName":"namespace","indexType":"string"}' >/dev/null
  fi
  echo "Vectorize $VECTORIZE_INDEX ready"
}

ensure_workers_subdomain() {
  local sub
  sub=$(cf GET "$(acct)/workers/subdomain" | jq -r '.result.subdomain // empty')
  if [ -z "$sub" ]; then
    sub="chiphealth-${CLOUDFLARE_ACCOUNT_ID:0:8}"
    echo "Registering workers.dev subdomain $sub"
    cf_ok PUT "$(acct)/workers/subdomain" "$(jq -nc --arg s "$sub" '{subdomain: $s}')" >/dev/null
  fi
  local url=${API_BASE_URL_OVERRIDE:-https://$WORKER_NAME.$sub.workers.dev}
  echo "API base URL = $url"
  out api_base_url "$url"
}

ensure_pages() {
  local res
  res=$(cf GET "$(acct)/pages/projects/$PAGES_PROJECT")
  if [ "$(jq -r '.success' <<<"$res")" != "true" ]; then
    echo "Creating Pages project $PAGES_PROJECT"
    res=$(cf_ok POST "$(acct)/pages/projects" \
      "$(jq -nc --arg n "$PAGES_PROJECT" '{name: $n, production_branch: "main"}')")
  fi
  # The pages.dev subdomain can differ from the project name if it was taken.
  local origin=${ADMIN_ORIGIN_OVERRIDE:-https://$(jq -r '.result.subdomain' <<<"$res")}
  echo "Admin origin = $origin"
  out admin_origin "$origin"
  out pages_project "$PAGES_PROJECT"
}

cmd_provision() {
  ensure_d1
  ensure_r2
  ensure_vectorize
  ensure_workers_subdomain
  ensure_pages
}

put_secret() {
  echo "Setting Worker secret $1"
  cf_ok PUT "$(acct)/workers/scripts/$WORKER_NAME/secrets" \
    "$(jq -nc --arg n "$1" --arg v "$2" '{name: $n, text: $v, type: "secret_text"}')" >/dev/null
}

cmd_secrets() {
  local existing
  existing=$(cf_ok GET "$(acct)/workers/scripts/$WORKER_NAME/secrets" | jq -r '.result[].name')

  # A secret given in GitHub always wins; otherwise JWT_SECRET is generated once
  # and then left alone, so existing sessions stay valid across deploys.
  if [ -n "${JWT_SECRET:-}" ]; then
    put_secret JWT_SECRET "$JWT_SECRET"
  elif ! grep -qx JWT_SECRET <<<"$existing"; then
    put_secret JWT_SECRET "$(openssl rand -base64 48 | tr -d '\n')"
  fi

  if [ -n "${FCM_SERVICE_ACCOUNT_JSON:-}" ]; then
    put_secret FCM_SERVICE_ACCOUNT_JSON "$FCM_SERVICE_ACCOUNT_JSON"
  fi
}

case "${1:-}" in
  account) cmd_account ;;
  provision) cmd_provision ;;
  secrets) cmd_secrets ;;
  *) die "usage: $0 account|provision|secrets" ;;
esac
