conoha vps 上で稼働している nginx のワイルドカード証明書をcertbot で取得しています。
ワイルドカード証明書のため、dns-01チャレンジが必要で、現在は手動で毎回更新しています。
certbot には --manual-auth-hook と --manual-cleanup-hook があり、ここに指定する shell を作成します。
