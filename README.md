# BELESMA — figurinhas

Implementação de `BELESMA-BUILD.md` (a spec mestre, na pasta acima).
**Estado: Fases 1, 2 e 3 concluídas.** Fase 4 em diante não começou.

Este projeto é novo e separado de `../belesma/`, que é a implementação da spec
antiga (`BELESMA-SPEC.md`, modelo de cartas com `rarity`). Aquele projeto não
foi tocado.

## O que existe

```
supabase/migrations/
  20260821120000_schema.sql   schema completo, incluindo is_admin, admin_log,
                              baba, baba_log, damage_level e economy_config
  20260821120100_seed.sql     3 personagens, 81 tipos, 6642 cópias, selos,
                              reserva do diário, odds e preços
  20260821120200_rls.sql      RLS e GRANTs: nega tudo, libera SELECT ponto a ponto

scripts/
  verificar-fase1.mjs         roda as migrações num Postgres real (PGlite) e
                              confere contagens, selos, RLS e idempotência
  verificar-fase2.mjs         450 pacotes: distribuição, pity, reserva, authz
  fraude-http.mjs             o mesmo teste de fraude, mas contra o Supabase
                              real, por HTTP e com JWT do Auth
  fluxo-http.mjs              cadastro -> abrir -> coleção -> admin, por HTTP
  concorrencia-http.mjs       72 pacotes em paralelo: nenhum serial repetido
  check-assets.mjs            confere as artes contra o catálogo (spec §3)
  importar-assets.mjs         traz as artes de "../belesma new", renomeia para
                              o padrão e reconstrói o alfa dos selos
```

## Rodar as verificações

```
npm run verificar:fase1       # Postgres local (PGlite), sem Docker
npm run verificar:fase2       # idem, com 450 pacotes abertos
node scripts/fraude-http.mjs      # contra o Supabase real, por HTTP
node scripts/fluxo-http.mjs       # fluxo do usuário de ponta a ponta
node scripts/concorrencia-http.mjs # 72 pacotes simultâneos
```

O primeiro sobe um Postgres em WASM e aplica **as mesmas migrações** que vão
para o Supabase — não precisa de Docker. Ele não cobre PostgREST nem o JWT do
Auth; `auth.uid()` é um stub que lê a mesma GUC que o Supabase usa.

O segundo fecha esse buraco: roda contra o projeto de verdade, por HTTP, com
JWT real. Precisa de `SUPABASE_SERVICE_ROLE_KEY` no ambiente, e só para criar
o jogador cobaia — as tentativas de fraude usam exclusivamente a anon key.

## No ar

| | |
|---|---|
| Site | https://lbm-marangoni.github.io/belesma-figurinhas/ |
| Supabase | `jllecfwnwgabyqhhfanx` (projeto novo; o `cepdbxgealjdiqmacnvm` do jogo antigo ficou intocado) |
| Repo | https://github.com/lbm-marangoni/belesma-figurinhas (público — Pages não roda em repo privado no plano free) |

Push na `main` roda `check-assets`, `verificar:fase1` e o build antes de publicar.

## Reaplicar no Supabase

```
supabase link --project-ref jllecfwnwgabyqhhfanx
npm run db:push
```

As migrações são idempotentes: reaplicar não duplica cópia, não re-sorteia
selo e não infla a reserva.

Para ligar o primeiro admin — na mão, pelo SQL editor do painel, que é
o único caminho previsto pela spec §18:

```sql
update public.players set is_admin = true where nickname = '<apelido>';
```

## Permissão administrativa

Não existe `admin_key` neste projeto, e não deve aparecer. A guarda é
`players.is_admin`, checada dentro de cada RPC via `private.require_admin()`.
A rota `/admin` (Fase 2) decide só o que renderiza, nunca se a ação é
permitida.

## Assets

`npm run check-assets` — hoje acusa as 81 figurinhas, os 3 selos e os 3
boosters faltando. É o esperado: as artes chegam aos poucos e o sistema tem
que funcionar com placeholder (spec §3).

## Rotas

| rota | quem vê |
|---|---|
| `/colecao` | logado |
| `/abrir` | logado |
| `/admin` | só `is_admin` — para os outros, 404 |

O `dist/404.html` é cópia do `index.html`: é o que faz link direto para
`/admin` funcionar no GitHub Pages, que não conhece rotas de SPA.

## Configuração do Auth

O e-mail é sintético (`apelido@belesma.local`), então **a confirmação de
e-mail precisa ficar desligada** (`mailer_autoconfirm: true`) e o mínimo de
senha é 6. Já está assim no projeto.

## Efeito 3D (Fase 3)

Tudo em CSS `transform` + `perspective`, sem Three.js nem WebGL. O JS escreve
só quatro variáveis no palco (`--rx`, `--ry`, `--px`, `--py`); as camadas de
`src/styles/figurinha.css` fazem o resto.

**A armadilha do §12, e por que este código não cai nela:** nunca leia
`getBoundingClientRect()` do elemento que carrega o `transform`. Esse rect é a
caixa *projetada* — e como o tilt sai dessa leitura, vira realimentação.
Medido neste projeto, girando de -12° a +12°:

| leitura | variação |
|---|---|
| rect do palco (o que `useTilt` usa) | **0 px** |
| rect da carta transformada (proibido) | 7,3 px |

`src/lib/tilt.ts` usa rect do palco + `offsetWidth`/`offsetHeight` da
figurinha, derivando a escala de ancestrais por `rect.width / offsetWidth`.
