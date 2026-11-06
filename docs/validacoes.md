# Validações a fazer no ambiente de produção

Checklist em ordem de prioridade. Nenhum passo desliga nada: primeiro **medir/diagnosticar**, depois aplicar.

## 0. Inventário básico

| # | Verificação | Comando | Por quê |
|---|---|---|---|
| 0.1 | Versão do Grafana | `grafana-server -v` ou ✱ no canto da UI | Comportamento de sessão muda a partir de ~v6; recursos de HA de Live só em versões novas |
| 0.2 | Tipo de banco em uso | `grep -A6 '\[database\]' /etc/grafana/grafana.ini` | **SQLite em produção com muitos usuários = causa nº 1** de restart lento e locks |
| 0.3 | Disco do `data_path` | `stat -f /var/lib/grafana` | local? SSD? NFS? SQLite em NFS é proibido |
| 0.4 | Como o serviço roda | systemd? docker? k8s? | define estratégia de drain e probes |
| 0.5 | Balanceador na frente | haproxy? nginx? F5? | vem na seção 3 |
| 0.6 | **Tipo de DB REAL em uso** | `docker logs <container> 2>&1 \| grep -oE 'dbtype=[a-z3]+'` | `GF_DATABASE_TYPE` ausente ⇒ SQLite silencioso, mesmo com host/user/name configurados — e a sessão só vale no nó que criou o cookie |

## 1. Diagnóstico do reinício lento (fase a fase)

Rode **na próxima reinicialização** (ou pegue da última nos logs). Cada fase imprime `t=` — a diferença entre fases aponta o culpado:

```bash
sudo journalctl -u grafana-server | tail -3000 | grep \
  -E 'Starting Grafana|Locking database|DB migrations|Path Plugins' \
  -E '|plugin.*(installed|disabled)|State cache|Starting scheduler|HTTP Server Listen'
```

Ou, via `docker logs`. Anote os intervalos:

| Fase (log line) | Interpretação |
|---|---|
| `Starting Grafana` → `Locking database` | config/plugin scan (deve ser < 1 s) |
| `Locking database` → fim das `migrations` | **BANCO** — culpado mais comum; compare `duration=` da última migração |
| fase de plugins (`Path Plugins` → pronto) | plugins quebrados/instalando no boot |
| `State cache has been initialized` (número de `states`) | nº de alertas ativos — dimensão do cache ngalert |
| `Initializing .* Service` em massa | services demorados (ex.: `ngalert.scheduler`, autorização) |

Também vale:

```bash
# o que mais aconteceu entre stop e health 200
sudo journalctl -u grafana-server --since "<início do restart>" \
  --until "<primeiro 200 em /api/health>"
```

## 2. Saúde do banco de dados

Se em produção ainda é SQLite (`grafana.db`) com mais de ~20 usuários: planeje migrar para Postgres/MySQL **antes de qualquer tuning**. Verificações:

```sql
-- volume das tabelas de sessão: cada login é uma linha aqui
SELECT count(*) FROM user_auth_token;

-- annotations (inclusive auto-refresh da UI) podem inflar o DB
SELECT count(*) FROM annotation;

-- Estado dos alertas (impacto no init do ngalert)
SELECT count(*) FROM alert_rule;
```

Interpretação:
- `user_auth_token` em **centenas de milhares/milhões** → purga de tokens velhos parou ou expiração muito longa; confira `[auth] login_remember_days`/lifetimes — essa tabela é tocada no boot e no `POST /login`.
- DB > alguns GB com SQLite → risco alto de lock e boot lento.
- MySQL: conferir `innodb_buffer_pool_size` adequado (o boot relê o `migration_log` e índices).
- Verificar que o **purge agendado de tokens roda** (Grafana roda a cada 2h por padrão: busca por logs `purged`).

## 3. Balanceador / sessão

- [ ] **`[security] secret_key` idêntico em todos os nós** — configuração oficial de HA. No lab funcionou com o default de fábrica, mas qualquer valor personalizado só em um nó quebra a sessão compartilhada (cookie HMAC ≠).
- [ ] **Confirmação dura #1 – sem sticky**: LB faz round-robin entre ≥ 2 nós? `ip_hash`/`source`/cookie presente? stickiness **não** é necessário (sessão é no DB) e vira pin no nó morto → "cai um monte de gente".
- [ ] **Health check ativo** no LB usando `GET /api/health` com expect 200, `inter ≤ 1s fall ≤ 2`.
- [ ] Para cada nó: `maxconn`/`timeout server` saneados (sem fila infinita de requests penduradas).
- [ ] Nginx (se for o caso): `proxy_read_timeout ≥ 90s` (senão dashboards com stream/WebSocket soltam) e `proxy_http_version 1.1` + headers de upgrade para WebSocket do Grafana Live.
- [ ] **Teste de falha controlado** (janela baixa de uso): matar -9 um nó e confirmar que nenhum usuário desloga (deve cair apenas requisições em voo).

## 4. Plano de implantação da correção (ordem)

1. Migrar DB → Postgres/MySQL compartilhado.
2. Ajustar `[database] conn_max_lifetime/conn_max_idle` (pool quente no boot).
3. Segundo nó Grafana (rolling, nunca simultâneo) — mesmo DB.
4. LB com round-robin **sem** sticky + health-check ativo.
5. Desligar o nó antigo (ou reutilizá-lo como segundo nó).
6. Re-testar: crash de um nó com usuário logado = sessão válida no outro.

## 5. Como reproduzir este estudo

```bash
cd lab && docker compose up -d --wait   # 2 nós + postgres + haproxy
../scripts/test-ha-failover.sh          # kill -9 em g1 sob tráfego
../scripts/test-session-crash.sh        # sessão sobrevive a SIGKILL
../scripts/test-restart-sqlite.sh       # timing de restart + dados
```

Resultado esperado: **Zero deslogamentos**; falha apenas em requests em voo no momento do kill.

> Nota de versão: no Grafana 13 o login é `POST /login` com JSON `{"user","password"}`;
> o antigo `POST /api/login` saiu de cena (handler=notfound). Os scripts do repo já usam o novo.
