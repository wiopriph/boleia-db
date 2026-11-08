#!/usr/bin/env bash
# Заливает бэкенд в облачный проект Supabase: миграции (+ seed при --seed), config (auth hooks,
# test OTP, verify_jwt функций), Edge Functions, секреты, Vault для edge_call.
# Требует: supabase login; ref проекта; пароль базы (SUPABASE_DB_PASSWORD или интерактивно).
#   scripts/deploy.sh <project-ref> [--seed]
set -euo pipefail
cd "$(dirname "$0")/.."

REF=${1:?usage: scripts/deploy.sh <project-ref> [--seed]}
SEED=${2:-}
PW_ARGS=()
[[ -n "${SUPABASE_DB_PASSWORD:-}" ]] && PW_ARGS=(--password "$SUPABASE_DB_PASSWORD")

echo "== link $REF"
supabase link --project-ref "$REF" "${PW_ARGS[@]}"

echo "== db push"
if [[ "$SEED" == "--seed" ]]; then
  supabase db push --include-seed "${PW_ARGS[@]}"
else
  supabase db push "${PW_ARGS[@]}"
fi

echo "== config push (auth hooks, test OTP, functions verify_jwt)"
supabase config diff || true
supabase config push

echo "== functions deploy"
supabase functions deploy

echo "== secrets"
supabase secrets set PUBLIC_FUNCTIONS_URL="https://$REF.supabase.co/functions/v1"
if [[ -f supabase/functions/.env.cloud ]]; then
  supabase secrets set --env-file supabase/functions/.env.cloud
fi

echo "== vault: edge_url / edge_key для edge_call (pg_cron -> Edge)"
SERVICE_KEY=$(supabase projects api-keys --remote="$REF" -o json | python3 -c '
import sys, json
keys = json.load(sys.stdin)
for k in keys:
    if k.get("name") == "service_role" or k.get("type") == "secret":
        print(k.get("api_key") or k.get("key")); break')
supabase db query --remote "delete from vault.secrets where name in ('edge_url','edge_key');
select vault.create_secret('https://$REF.supabase.co', 'edge_url', 'functions base URL for edge_call');
select vault.create_secret('$SERVICE_KEY', 'edge_key', 'service role key for edge_call');"

echo
echo "Готово. Проверка: scripts/edge-smoke.sh --cloud $REF"
echo "Для клиентов: SUPABASE_URL=https://$REF.supabase.co, anon key: supabase projects api-keys --remote=$REF"
