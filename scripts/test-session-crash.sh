#!/usr/bin/env bash
# Teste 2/3: a sessão sobrevive a um crash brutal (SIGKILL)?
# Uso: ./test-session-crash.sh [port] [container]   (default 13010 / g1, lab/)
#
# Resultado esperado (de acordo com o estudo): 200 antes E depois do crash.
# A sessão é auth token no BANCO (grafana >= 6.x); o processo não guarda estado de sessão.

set -uo pipefail
PORT="${1:-13010}"
URL="http://localhost:$PORT"
CONT="${2:-${GRAFANA_CONTAINER:-g1}}"
PASS='AdminLab123!'   # senha admin do lab (docker-compose.yml)

wait_health() {
  for _ in $(seq 1 400); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 0.5 "$URL/api/health")" = "200" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_health || { echo "Grafana ($URL) não respondeu /api/health" >&2; exit 1; }

# login (Grafana >= 12 aceita apenas o formato JSON abaixo; form dá "form-auth.invalid")
LOGIN_CODE=$(curl -s -c /tmp/gf-jar-crash -H 'Content-Type: application/json' \
  -d "{\"user\":\"admin\",\"password\":\"$PASS\"}" "$URL/login" -o /dev/null -w '%{http_code}')
if ! grep -q grafana_session /tmp/gf-jar-crash; then
  echo "cookie NÃO obtido (login=$LOGIN_CODE) — confira usuário/senha do lab" >&2
  exit 1
fi

A=$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/gf-jar-crash "$URL/api/user")
echo "antes do crash   : $A"

docker kill --signal=KILL "$CONT" > /dev/null
sleep 0.2
docker start "$CONT" > /dev/null
wait_health || { echo "Grafana não voltou após crash" >&2; exit 1; }

B=$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/gf-jar-crash "$URL/api/user")
echo "depois do crash  : $B"

if [ "$A" = "200" ] && [ "$B" = "200" ]; then
  echo "✅ sessão persistiu no DB — crash SIGKILL não desloga usuários"
  exit 0
fi
echo "❌ sessão NÃO sobreviveu — verifique versão do Grafana (esperado >= 13.x) e config de [auth]"
exit 1
