#!/usr/bin/env bash
# Кладёт в Vault локальной базы edge_url и edge_key, чтобы pg_cron/pg_net могли звать Edge Functions.
# Запускать после каждого `supabase db reset` (reset стирает vault.secrets).
set -euo pipefail
cd "$(dirname "$0")/.."

status=$(supabase status -o json 2>/dev/null)
key=$(printf '%s' "$status" | python3 -c 'import sys,json; print(json.load(sys.stdin)["SERVICE_ROLE_KEY"])')
# из контейнера базы API доступен через host.docker.internal, не через 127.0.0.1
url=${EDGE_URL:-http://host.docker.internal:54321}
container=$(docker ps --format '{{.Names}}' | grep '^supabase_db_' | head -1)

docker exec -i "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
delete from vault.secrets where name in ('edge_url', 'edge_key');
select vault.create_secret('$url', 'edge_url', 'functions base URL for edge_call');
select vault.create_secret('$key', 'edge_key', 'service role key for edge_call');
SQL
echo "vault: edge_url=$url, edge_key set"
