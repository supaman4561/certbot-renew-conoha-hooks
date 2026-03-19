#!/bin/bash
# certbot --manual-auth-hook スクリプト
# ConoHa DNS API を使って DNS-01 チャレンジ用 TXT レコードを作成します
#
# certbot が設定する環境変数:
#   CERTBOT_DOMAIN     - 認証対象のドメイン (例: *.example.com)
#   CERTBOT_VALIDATION - TXT レコードに設定する検証文字列

set -euo pipefail

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Error: config.env が見つかりません: ${CONFIG_FILE}" >&2
  echo "config.env.example をコピーして設定してください" >&2
  exit 1
fi

# shellcheck source=config.env.example
source "${CONFIG_FILE}"

# ワイルドカードプレフィックスを除去 (*.example.com -> example.com)
DOMAIN="${CERTBOT_DOMAIN#\*.}"
VALIDATION="${CERTBOT_VALIDATION}"

# auth hook と cleanup hook 間でレコードIDを共有するための一時ファイル
SAFE_DOMAIN="$(echo "${CERTBOT_DOMAIN}" | tr -dc 'a-zA-Z0-9.-')"
TMPFILE="/tmp/_certbot_conoha_${SAFE_DOMAIN}_${VALIDATION:0:20}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auth_hook] $*" >&2
}

log "開始: ドメイン=${CERTBOT_DOMAIN}"

# 認証トークン取得
log "ConoHa API トークンを取得中..."
TOKEN_RESPONSE=$(curl -s -f -X POST \
  "https://identity.${CONOHA_REGION}.conoha.io/v2.0/tokens" \
  -H "Content-Type: application/json" \
  -d "{
    \"auth\": {
      \"tenantId\": \"${CONOHA_TENANT_ID}\",
      \"passwordCredentials\": {
        \"username\": \"${CONOHA_API_USERNAME}\",
        \"password\": \"${CONOHA_API_PASSWORD}\"
      }
    }
  }")

TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access.token.id')
if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  log "Error: トークンの取得に失敗しました"
  log "レスポンス: ${TOKEN_RESPONSE}"
  exit 1
fi
log "トークン取得成功"

# ゾーン一覧取得
log "DNSゾーン一覧を取得中..."
DOMAINS_RESPONSE=$(curl -s -f -X GET \
  "https://dns-service.${CONOHA_REGION}.conoha.io/v1/domains" \
  -H "X-Auth-Token: ${TOKEN}" \
  -H "Accept: application/json")

# 対象ドメインに一致するゾーンを検索 (最長サフィックスマッチ)
DOMAIN_ID=""
BEST_MATCH_LEN=0

while IFS= read -r zone_json; do
  ZONE_NAME=$(echo "${zone_json}" | jq -r '.name' | sed 's/\.$//')
  ZONE_ID=$(echo "${zone_json}" | jq -r '.id')

  if [[ "${DOMAIN}" == "${ZONE_NAME}" || "${DOMAIN}" == *".${ZONE_NAME}" ]]; then
    if [[ ${#ZONE_NAME} -gt ${BEST_MATCH_LEN} ]]; then
      DOMAIN_ID="${ZONE_ID}"
      BEST_MATCH_LEN=${#ZONE_NAME}
    fi
  fi
done < <(echo "${DOMAINS_RESPONSE}" | jq -c '.domains[]')

if [[ -z "${DOMAIN_ID}" ]]; then
  log "Error: ドメイン '${DOMAIN}' に一致するゾーンが見つかりません"
  log "登録済みゾーン: $(echo "${DOMAINS_RESPONSE}" | jq -r '.domains[].name')"
  exit 1
fi
log "ゾーンID: ${DOMAIN_ID}"

# TXT レコード作成
TXT_RECORD_NAME="_acme-challenge.${DOMAIN}."
log "TXT レコードを作成中: ${TXT_RECORD_NAME}"

RECORD_RESPONSE=$(curl -s -f -X POST \
  "https://dns-service.${CONOHA_REGION}.conoha.io/v1/domains/${DOMAIN_ID}/records" \
  -H "X-Auth-Token: ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${TXT_RECORD_NAME}\",
    \"type\": \"TXT\",
    \"data\": \"${VALIDATION}\",
    \"ttl\": 60
  }")

RECORD_ID=$(echo "${RECORD_RESPONSE}" | jq -r '.id')
if [[ -z "${RECORD_ID}" || "${RECORD_ID}" == "null" ]]; then
  log "Error: TXT レコードの作成に失敗しました"
  log "レスポンス: ${RECORD_RESPONSE}"
  exit 1
fi
log "TXT レコード作成成功 (ID: ${RECORD_ID})"

# cleanup_hook で使用するために一時ファイルに保存
echo "${DOMAIN_ID}" > "${TMPFILE}"
echo "${RECORD_ID}" >> "${TMPFILE}"
log "一時ファイルに保存: ${TMPFILE}"

# DNS 伝播待ち
PROPAGATION_WAIT="${CONOHA_PROPAGATION_WAIT:-60}"
log "DNS 伝播待ち: ${PROPAGATION_WAIT}秒..."
sleep "${PROPAGATION_WAIT}"

log "完了"
