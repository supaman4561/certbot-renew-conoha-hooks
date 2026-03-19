#!/bin/bash
# certbot --manual-cleanup-hook スクリプト
# ConoHa DNS API を使って DNS-01 チャレンジ用 TXT レコードを削除します
#
# certbot が設定する環境変数:
#   CERTBOT_DOMAIN     - 認証対象のドメイン (例: *.example.com)
#   CERTBOT_VALIDATION - TXT レコードに設定した検証文字列

set -euo pipefail

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Error: config.env が見つかりません: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=config.env.example
source "${CONFIG_FILE}"

VALIDATION="${CERTBOT_VALIDATION}"

# auth_hook と同じ命名規則で一時ファイルのパスを生成
SAFE_DOMAIN="$(echo "${CERTBOT_DOMAIN}" | tr -dc 'a-zA-Z0-9.-')"
TMPFILE="/tmp/_certbot_conoha_${SAFE_DOMAIN}_${VALIDATION:0:20}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup_hook] $*" >&2
}

log "開始: ドメイン=${CERTBOT_DOMAIN}"

# auth_hook が保存したゾーンIDとレコードIDを読み込む
if [[ ! -f "${TMPFILE}" ]]; then
  log "Error: 一時ファイルが見つかりません: ${TMPFILE}"
  log "auth_hook が正常に実行されたか確認してください"
  exit 1
fi

DOMAIN_ID=$(sed -n '1p' "${TMPFILE}")
RECORD_ID=$(sed -n '2p' "${TMPFILE}")

if [[ -z "${DOMAIN_ID}" || -z "${RECORD_ID}" ]]; then
  log "Error: 一時ファイルからIDを読み込めませんでした"
  exit 1
fi

log "ゾーンID: ${DOMAIN_ID}, レコードID: ${RECORD_ID}"

# 認証トークン取得
IDENTITY_VERSION="${CONOHA_IDENTITY_VERSION:-v3}"
log "ConoHa API トークンを取得中 (Identity ${IDENTITY_VERSION})..."

if [[ "${IDENTITY_VERSION}" == "v2.0" ]]; then
  TOKEN=$(curl -s -f -X POST \
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
    }" | jq -r '.access.token.id')
else
  # v3: トークンはレスポンスヘッダー X-Subject-Token に返される
  TOKEN=$(curl -s -i -f -X POST \
    "https://identity.${CONOHA_REGION}.conoha.io/v3/auth/tokens" \
    -H "Content-Type: application/json" \
    -d "{
      \"auth\": {
        \"identity\": {
          \"methods\": [\"password\"],
          \"password\": {
            \"user\": {
              \"name\": \"${CONOHA_API_USERNAME}\",
              \"password\": \"${CONOHA_API_PASSWORD}\",
              \"domain\": {\"name\": \"Default\"}
            }
          }
        },
        \"scope\": {
          \"project\": {\"id\": \"${CONOHA_TENANT_ID}\"}
        }
      }
    }" | grep -i "^x-subject-token:" | awk '{print $2}' | tr -d '\r\n')
fi

if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  log "Error: トークンの取得に失敗しました"
  exit 1
fi
log "トークン取得成功"

# TXT レコード削除
log "TXT レコードを削除中 (ID: ${RECORD_ID})..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  "https://dns-service.${CONOHA_REGION}.conoha.io/v1/domains/${DOMAIN_ID}/records/${RECORD_ID}" \
  -H "X-Auth-Token: ${TOKEN}")

if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "204" ]]; then
  log "Error: TXT レコードの削除に失敗しました (HTTP ${HTTP_STATUS})"
  exit 1
fi
log "TXT レコード削除成功"

# 一時ファイルを削除
rm -f "${TMPFILE}"
log "一時ファイルを削除: ${TMPFILE}"

log "完了"
