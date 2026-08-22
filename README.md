# BELESMA — figurinhas

Implementação de `BELESMA-BUILD.md` (a spec mestre, na pasta acima).
**Estado: Fase 1 (fundação) concluída.** Fase 2 em diante não começou.

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
  fraude-http.mjs             o mesmo teste de fraude, mas contra o Supabase
                              real, por HTTP e com JWT do Auth
  check-assets.mjs            confere as artes contra o catálogo (spec §3)
  importar-assets.mjs         traz as artes de "../belesma new", renomeia para
                              o padrão e reconstrói o alfa dos selos
```

## Rodar as verificações

```
npm run verificar:fase1     # Postgres local (PGlite), sem Docker
node scripts/fraude-http.mjs  # contra o Supabase de verdade, por HTTP
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
