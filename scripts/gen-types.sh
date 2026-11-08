#!/usr/bin/env bash
# Обновляет types/database.ts и docs/api.md из локальной базы. Запускать после db reset с новой миграцией.
set -euo pipefail
cd "$(dirname "$0")/.."
supabase gen types typescript --local 2>/dev/null > types/database.ts
python3 scripts/gen-api-doc.py
echo "types/database.ts: $(wc -l < types/database.ts) lines"
