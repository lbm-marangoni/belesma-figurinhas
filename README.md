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
  check-assets.mjs            confere as artes contra o catálogo (spec §3)
```

## Rodar a verificação

```
npm run verificar:fase1
```

Sobe um Postgres em WASM, aplica **as mesmas migrações** que vão para o
Supabase e testa. Não precisa de Docker nem de projeto no ar.

O que ele não cobre: a camada HTTP do PostgREST e o JWT do Supabase Auth.
`auth.uid()` é um stub que lê a mesma GUC que o Supabase usa, então as
policies são exercitadas de verdade, mas o transporte não.

## Aplicar no Supabase

Ainda **não foi aplicado em nenhum projeto Supabase.** Quando for:

```
supabase link --project-ref <ref>
npm run db:push
```

Depois, para ligar o primeiro admin — na mão, pelo SQL editor do painel, que é
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
