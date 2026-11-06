# Grafana Performance & HA — Estudo com testes locais

Estudo prático sobre dois problemas comuns em Grafana de produção:

1. **Reinício lento** — o serviço leva muito tempo para voltar no ar após restart/upgrade
2. **Quedas em massa de sessões** — quando um nó falha, "um monte de gente" cai

Todos os números abaixo foram medidos localmente com **Grafana OSS 13.0.2**, Docker, SQLite, Postgres 16 e HAProxy 2.7 (16 cores / 29 GB RAM). Os scripts para reproduzir estão em [`scripts/`](scripts/) e o lab completo em [`lab/`](lab/).

---

## 1. Resultados dos testes

| Teste | Resultado |
|---|---|
| Primeiro boot (migrações de schema, SQLite vazio) | 7,8 s – 12,4 s *(uma vez só na vida da instalação)* |
| Restart a quente — SQLite, com +200 dashboards | **1,2 s – 2,5 s** (janela indisponível ≈ 2 s) |
| Restart a quente — Postgres | **< 1 s** |
| Crash brutal (`kill -9`) com sessão ativa | ✅ cookie `grafana_session` **continuou válido** após voltar |
| 2 nós + Postgres compartilhado + HAProxy **sem sticky**: `kill -9` sob tráfego | **2 falhas em 150 requests** (0,6% — apenas a request em voo) |
| Rolling restart de um nó com sessões ativas | **2 falhas em 120 requests** |
| 2 nós subindo **ao mesmo tempo** | ⚠️ o segundo **morre**: `failed to obtain lock` |
| Plugins pré-instalados no GF 13 | 4 app plugins lidos no boot (loki/metrics drilldown, exploretraces, pyroscope) |

### Descobertas-chave

1. **Número de dashboards nÃO é o motivo de restart lento.** 200 dashboards criados via API: impacto quase zero. O tempo de boot vai quase todo para **verificações de migração no banco + inicialização de services (ngalert, plugins)**.
2. **A sessão vive no banco, não em memória.** Grafana moderno usa *auth token strategy* com o DB (`login_token`). Crash do processo não desloga ninguém.
3. **"Cai um monte de gente" não é a sessão expirar — é o balanceador.** Com banco compartilhado e LB sem sticky + health-check ativo, um nó morto derruba apenas a request em voo de cada cliente. Se na empresa cai massa, não existe HA (nó único) ou o LB tem stickiness/health-check ruins.
4. **Dois nós subindo simultaneamente competem pelo lock de migração.** O segundo sai com `failed to obtain lock`. Retries não acontecem: precisa subir sequencial (rolling).

---

## 2. Arquitetura recomendada

```
              ┌──── HAProxy / Nginx (sem sticky, health-check ativo)
              │
        ┌─────┴─────┐
        │ Grafana#1 │          ┌────────────────┐
        │ Grafana#2 ├──────────► Postgres/MySQL   │ ← sessões + dados
        └───────────┘          └────────────────┘
```

### grafana.ini (em ambos os nós)

```ini
[database]
type = postgres
host = postgres:5432
name = grafana
user = grafana
password = ***
conn_max_lifetime = 14400
conn_max_idle = 20

[analytics]
reporting_enabled = false
check_for_plugin_updates = false

[plugins]
preinstall_enabled = false   ; se não usar os drilldowns/app plugins embutidos
```

### HAProxy

```
backend grafana
  balance roundrobin
  option httpchk GET /api/health
  http-check expect status 200
  server g1 10.0.0.1:3000 check inter 500ms fall 2 rise 1
  server g2 10.0.0.2:3000 check inter 500ms fall 2 rise 1
  timeout server 60s
  timeout client 90s
```

- **Sem** `ip_hash` / `balance source` / cookie de stickiness — são desnecessários (sessão no DB) e danosos no failover.
- `inter 500ms fall 2` = detecção de nó morto em ~1 s (medido).

### Regras de operação

1. **Nunca levante os nós ao mesmo tempo** — lock de migração é exclusivo; segundo nó morre.
2. Faça **rolling restart**: suba 1 → `/api/health` = 200 → suba o próximo.
3. Upgrade de versão: reserve 5–15 min para o boot inicial (migrações) em bases grandes.
4. Nginx na frente: `proxy_read_timeout ≥ 90s`, `upstream keepalive`.

### Armadilhas encontradas durante o lab (agora no checklist!)

- **`GF_DATABASE_TYPE` é obrigatória.** Sem ela o Grafana **silenciosamente usa SQLite** local (`dbtype=sqlite3` no boot) mesmo com host/user/name configurados — e a sessão passa a valer só no nó que criou o cookie (reproduzido no lab: login no g1 = 401 no g2). Detecção em 1 linha no boot:
  ```bash
  docker logs <container> 2>&1 | grep -oE 'dbtype=[a-z3]+'
  # esperado: dbtype=postgres (ou mysql). "sqlite3" em produção = problema.
  ```
  (No YAML, cuidado com comentário colado na mesma linha do valor — o valor vira parte do comentário e é engolido.)
- **`[security] secret_key` deve ser IDÊNTICO em todos os nós** (config de HA oficial). No lab funcionou até sem setar (o default de fábrica é o mesmo), mas toda personalização individual por nó quebra a sessão compartilhada.
- **Login via API no Grafana 13**: `POST /login` com JSON `{"user":"…","password":"…"}`. O antigo `POST /api/login` não existe mais (retorna `handler=notfound`) — automações com a chamada antiga falham silenciosamente.

---

## 3. Tuning rápido (reinício mais veloz)

| Ajuste | Motivo |
|---|---|
| `[paths] data` em SSD local (se SQLite ainda) | SQLite + WAL em NFS = boot lento e locks |
| `[analytics] reporting/check: off` | boot sem chamadas externas |
| `[plugins] preinstall off` (se não usa) | menos I/O e rede no boot |
| `[database] conn_max_lifetime/max_idle` | sem pool frio pós-restart |
| Não desabilitar a purga de tokens | evita `user_auth_token` gigante (tabela tocada no boot) |
| `[auth] login_remember_days` moderado (7–30) | reduz volume da tabela de sessão |

## 4. Validar no seu ambiente — antes de aplicar

O checklist completo está em **[docs/validacoes.md](docs/validacoes.md)**: versão do Grafana, tipo de DB, volume de tokens de sessão, configs do balanceador e diagnóstico fase a fase do último boot.
