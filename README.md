# certbot-renew-conoha-hooks

ConoHa VPS 上で certbot によるワイルドカード証明書の自動更新を行うためのフックスクリプトです。

DNS-01 チャレンジに必要な TXT レコードの作成・削除を ConoHa DNS API を使って自動化します。

## 必要なもの

- certbot
- curl
- jq
- ConoHa API ユーザー ([ConoHaコントロールパネル](https://www.conoha.jp/conoha/) > API から作成)

## セットアップ

### 1. スクリプトをサーバーに配置

```bash
git clone https://github.com/supaman4561/certbot-renew-conoha-hooks.git /etc/certbot-hooks
cd /etc/certbot-hooks
```

### 2. 設定ファイルを作成

```bash
cp config.env.example config.env
vim config.env
```

`config.env` に以下を設定します:

| 変数名 | 説明 |
|--------|------|
| `CONOHA_TENANT_ID` | テナントID (ConoHaコントロールパネル > API) |
| `CONOHA_API_USERNAME` | API ユーザー名 |
| `CONOHA_API_PASSWORD` | API パスワード |
| `CONOHA_REGION` | リージョン。コントロールパネル > API のエンドポイントURLで確認 (`c3j1` / `tyo1` / `tyo2` など) |
| `CONOHA_IDENTITY_VERSION` | Identity API バージョン。`c3j1` など新世代は `v3`、`tyo1`/`tyo2` など旧世代は `v2.0` |
| `CONOHA_PROPAGATION_WAIT` | DNS 伝播待ち時間（秒、デフォルト: 60） |

### 3. 実行権限を付与

```bash
chmod +x /etc/certbot-hooks/auth_hook.sh
chmod +x /etc/certbot-hooks/cleanup_hook.sh
```

### 4. 設定ファイルのパーミッションを制限

```bash
chmod 600 /etc/certbot-hooks/config.env
```

## 使い方

### 初回証明書取得

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook /etc/certbot-hooks/auth_hook.sh \
  --manual-cleanup-hook /etc/certbot-hooks/cleanup_hook.sh \
  -d "*.example.com" \
  -d "example.com"
```

### 手動更新

```bash
certbot renew \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook /etc/certbot-hooks/auth_hook.sh \
  --manual-cleanup-hook /etc/certbot-hooks/cleanup_hook.sh
```

### cron による自動更新

`/etc/cron.d/certbot-renew` を作成します:

```cron
0 3 * * * root certbot renew --manual --preferred-challenges dns --manual-auth-hook /etc/certbot-hooks/auth_hook.sh --manual-cleanup-hook /etc/certbot-hooks/cleanup_hook.sh --quiet
```

証明書の有効期限が30日以内になったタイミングで自動的に更新されます。

## フックの動作

```
certbot renew
├── auth_hook.sh
│   ├── ConoHa API でトークン取得
│   ├── DNSゾーンID を取得
│   ├── _acme-challenge.<domain> の TXT レコードを作成
│   └── DNS 伝播待ち (デフォルト60秒)
│
├── (Let's Encrypt による DNS-01 チャレンジ検証)
│
└── cleanup_hook.sh
    ├── ConoHa API でトークン取得
    ├── TXT レコードを削除
    └── 一時ファイルを削除
```
