#!/usr/bin/env bash
# Teste 3/3: failover sob tráfego — matar um nó com sessão ativa e LB sem sticky.
# Uso: ./test-ha-failover.sh [container-a-matar] [segundos-observando]   (lab/: haproxy em 13020)
#
# Esperado: ~0 "deslogamentos"; apenas a(s) request(s) em voo no momento do kill falha
# (medido no estudo: 2/150 falhas com SIGKILL e 2/120 em rolling restart).

set -uo pipefail
LB="http://localhost:13020"
NODE1="http://localhost:13010"   # g1 direto
NODE2="http://localhost:13011"   # g2 direto
VICTIM="${1:-grafana-1}"         # container a matar (compose: lab-grafana-1, alias "g1")
OBS="${2:-8}"
PASS='AdminLab123!'

wait_lb() {
  for _ in $(seq 1 100); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$LB/api/health")" = "200" ] && return 0
    sleep 0.5
  done
  return 1
}

wait_lb || { echo "LB ($LB) não respondeu /api/health" >&2; exit 1; }

LOGIN_CODE=$(curl -s -c /tmp/gf-jar-ha -H 'Content-Type: application/json' \
  -d "{\"user\":\"admin\",\"password\":\"$PASS\"}" "$LB/login" -o /dev/null -w '%{http_code}')
if ! grep -q grafana_session /tmp/gf-jar-ha; then
  echo "login via LB falhou (código $LOGIN_CODE)" >&2
  exit 1
fi

# prova do comportamento "sem sticky": o MESMO cookie é aceito por qualquer nó
curl -s -o /dev/null -w "cookie aceito no g1: %{http_code}\n" -b /tmp/gf-jar-ha "$NODE1/api/user"
curl -s -o /dev/null -w "cookie aceito no g2: %{http_code}\n" -b /tmp/gf-jar-ha "$NODE2/api/user"

echo "→ iniciando tráfego e matando '$VICTIM'…"
(
  for _ in $(seq 1 2000); do
    printf '%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 -b /tmp/gf-jar-ha "$LB/api/user")"
    sleep 0.15
  done > poll_ha.csv
) & POLL=$!

sleep 2
docker kill --signal=KILL "$VICTIM" > /dev/null
sleep "$OBS"
kill $POLL 2> /dev/null
wait $POLL 2> /dev/null

TOTAL=$(wc -l < poll_ha.csv)
BAD=$(awk '$1!=200' poll_ha.csv | wc -l)
echo "resultado: $BAD falhas de $TOTAL requests durante o failover"
echo "(esperado: 0–2 falhas, todas de requests em voo no momento do kill)"

# auto-reparo: repõe o nó morto para permitir executar o script em sequência
if docker inspect "$VICTIM" > /dev/null 2>&1; then
  ST=$(docker inspect -f '{{.State.Status}}' "$VICTIM")
  if [ "$ST" != "running" ]; then
    echo "repondo '$VICTIM'…"
    docker start "$VICTIM" > /dev/null
  fi
fi
# aguarda o LB voltar a servir 200 (com qualquer nó)
for _ in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$LB/api/health")" = "200" ] && break
  sleep 0.5
done
