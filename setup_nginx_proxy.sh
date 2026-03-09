#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

JSON_FILE="domains.json"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ENABLE_SSL=1
FORCE_RECONFIGURE="${FORCE_RECONFIGURE:-0}"

usage() {
  cat <<'EOF'
用法:
  bash setup_nginx_proxy.sh --config domains.json --email admin@example.com

参数:
  -c, --config <file>   域名配置文件（默认: domains.json）
  -e, --email <email>   证书邮箱（启用 SSL 时必填，也可用环境变量 CERTBOT_EMAIL）
      --no-ssl          仅配置反向代理，不申请证书
      --force           忽略 completed=true，强制重建配置
  -h, --help            查看帮助

domains.json 格式:
{
  "domains": [
    {
      "domain": "example.com",
      "target_host": "127.0.0.1",
      "target_port": 3000,
      "completed": false
    }
  ]
}
说明:
  target_host 和 target_ip 二选一，target_host 优先。
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -c|--config)
      JSON_FILE="$2"
      shift 2
      ;;
    -e|--email)
      CERTBOT_EMAIL="$2"
      shift 2
      ;;
    --no-ssl)
      ENABLE_SSL=0
      shift
      ;;
    --force)
      FORCE_RECONFIGURE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1（使用 -h 查看帮助）"
      ;;
  esac
done

require_root

[[ -f "$JSON_FILE" ]] || die "配置文件不存在: $JSON_FILE"
jq -e '.domains and (.domains | type == "array")' "$JSON_FILE" >/dev/null || die "JSON 格式错误: $JSON_FILE"

apt_install nginx jq
if [[ "$ENABLE_SSL" -eq 1 ]]; then
  [[ -n "$CERTBOT_EMAIL" ]] || die "启用 SSL 时必须传入 --email 或设置 CERTBOT_EMAIL。"
  apt_install certbot python3-certbot-nginx
fi

systemctl enable --now nginx

processed=0
skipped=0
failed=0

while IFS= read -r domain_entry; do
  domain="$(jq -r '.domain // empty' <<<"$domain_entry")"
  target_host="$(jq -r '.target_host // .target_ip // empty' <<<"$domain_entry")"
  target_port="$(jq -r '.target_port // empty' <<<"$domain_entry")"
  completed="$(jq -r '.completed // false' <<<"$domain_entry")"

  if [[ -z "$domain" || -z "$target_host" || -z "$target_port" ]]; then
    warn "跳过非法条目（缺少 domain/target_host(target_ip)/target_port）。"
    failed=$((failed + 1))
    continue
  fi

  if [[ "$completed" == "true" && "$FORCE_RECONFIGURE" != "1" ]]; then
    log "跳过已完成域名: $domain"
    skipped=$((skipped + 1))
    continue
  fi

  log "配置域名: $domain -> http://$target_host:$target_port"
  config_path="/etc/nginx/sites-available/${domain}.conf"

  cat >"$config_path" <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://$target_host:$target_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sfn "$config_path" "/etc/nginx/sites-enabled/${domain}.conf"
  rm -f /etc/nginx/sites-enabled/default

  if ! nginx -t; then
    warn "Nginx 配置校验失败: $domain"
    failed=$((failed + 1))
    continue
  fi

  systemctl reload nginx

  if [[ "$ENABLE_SSL" -eq 1 ]]; then
    log "申请证书: $domain"
    if ! certbot --nginx -n --agree-tos --redirect --email "$CERTBOT_EMAIL" -d "$domain"; then
      warn "证书申请失败: $domain（请确认 DNS 已解析到当前服务器）"
      failed=$((failed + 1))
      continue
    fi
  fi

  tmp_file="$(mktemp)"
  jq --arg domain "$domain" '(.domains[] | select(.domain == $domain) | .completed) = true' "$JSON_FILE" >"$tmp_file"
  mv "$tmp_file" "$JSON_FILE"

  processed=$((processed + 1))
  log "完成: $domain"
done < <(jq -c '.domains[]' "$JSON_FILE")

log "执行完成: success=$processed, skipped=$skipped, failed=$failed"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
