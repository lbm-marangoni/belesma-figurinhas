-- BELESMA figurinhas - Fase 1: RLS e permissoes (spec secao 9)
--
-- Modelo: nega tudo, libera SELECT ponto a ponto. Nenhuma escrita direta
-- existe para anon nem para authenticated, em nenhuma tabela. Toda mutacao
-- passa por RPC security definer.
--
-- O Supabase concede privilegios por default no schema public a anon e
-- authenticated. Por isso o REVOKE abaixo nao e decorativo: sem ele, a RLS
-- ficaria por cima de GRANTs abertos.

-- service_role e o papel de servidor de confianca: bypassa RLS e precisa de
-- GRANT explicito. O Supabase concede por default, mas essa configuracao vive
-- presa ao schema - se alguem recriar o schema public, ela some junto e o
-- painel e os scripts administrativos param de enxergar as tabelas.
-- Conceder aqui torna a migracao autossuficiente.
-- A chave de service_role NUNCA vai para o navegador.
grant usage on schema public to postgres, anon, authenticated, service_role;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- o schema private nao existe para o cliente
revoke all on schema private from anon, authenticated;

-- ---------------------------------------------------------------- RLS ligada
alter table public.tiers               enable row level security;
alter table public.characters          enable row level security;
alter table public.album_pages         enable row level security;
alter table public.card_types          enable row level security;
alter table public.card_copies         enable row level security;
alter table public.players             enable row level security;
alter table public.copy_history        enable row level security;
alter table public.trades              enable row level security;
alter table public.pack_config         enable row level security;
alter table public.pack_params         enable row level security;
alter table public.economy_config      enable row level security;
alter table public.baba_log            enable row level security;
alter table public.admin_log           enable row level security;
alter table public.pack_openings       enable row level security;
alter table public.pack_opening_cards  enable row level security;
alter table public.album_page_rewards  enable row level security;
alter table public.trade_rewards       enable row level security;
alter table public.seal_audit         enable row level security;

-- force: nem o dono da tabela escapa da politica em consulta normal.
-- As RPCs security definer continuam funcionando porque rodam como owner
-- com bypassrls no papel de servico.
alter table public.card_copies        force row level security;
alter table public.players            force row level security;
alter table public.admin_log          force row level security;

-- ================================================================ catalogo
-- Publico. O indice global e publico e a rota /v/<codigo> nao pede auth.
drop policy if exists tiers_leitura on public.tiers;
create policy tiers_leitura        on public.tiers          for select to anon, authenticated using (true);
drop policy if exists characters_leitura on public.characters;
create policy characters_leitura   on public.characters     for select to anon, authenticated using (true);
drop policy if exists album_pages_leitura on public.album_pages;
create policy album_pages_leitura  on public.album_pages    for select to anon, authenticated using (true);
drop policy if exists card_types_leitura on public.card_types;
create policy card_types_leitura   on public.card_types     for select to anon, authenticated using (true);
drop policy if exists pack_config_leitura on public.pack_config;
create policy pack_config_leitura  on public.pack_config    for select to anon, authenticated using (true);
drop policy if exists pack_params_leitura on public.pack_params;
create policy pack_params_leitura  on public.pack_params    for select to anon, authenticated using (true);
drop policy if exists economy_leitura on public.economy_config;
create policy economy_leitura      on public.economy_config for select to anon, authenticated using (true);

drop policy if exists seal_audit_leitura on public.seal_audit;
create policy seal_audit_leitura on public.seal_audit
  for select to anon, authenticated using (true);

grant select on public.tiers, public.characters, public.album_pages,
               public.card_types, public.pack_config, public.pack_params,
               public.economy_config, public.seal_audit
  to anon, authenticated;

-- ================================================================ card_copies
-- SELECT liberado (secao 9). Nenhuma politica de INSERT, UPDATE ou DELETE
-- existe - e a ausencia dela que nega, nao uma regra explicita.
drop policy if exists card_copies_leitura on public.card_copies;
create policy card_copies_leitura on public.card_copies
  for select to anon, authenticated using (true);

grant select on public.card_copies to anon, authenticated;

-- historico de donos aparece na figurinha aberta (secao 11)
drop policy if exists copy_history_leitura on public.copy_history;
create policy copy_history_leitura on public.copy_history
  for select to anon, authenticated using (true);

grant select on public.copy_history to anon, authenticated;

-- ================================================================ players
-- Secao 9: SELECT so de nickname, id, vitrine e is_admin.
--
-- RLS nao filtra COLUNA, so linha. A primeira versao resolvia com GRANT por
-- coluna, o que funcionava mas deixava uma armadilha: qualquer
-- select('*') em players tomaria permission denied, e o erro nao explica o
-- porque. Agora a tabela nao tem SELECT nenhum para o cliente, e o recorte
-- publico e a view players_public. Um select('*') NA VIEW e seguro.
--
-- O proprio jogador le a linha inteira - baba, pacotes, pity - por me().
grant select on public.players_public to anon, authenticated;
grant execute on function public.me() to authenticated;

-- ================================================================ trades
drop policy if exists trades_leitura on public.trades;
create policy trades_leitura on public.trades
  for select to authenticated
  using (auth.uid() = from_player or auth.uid() = to_player);

grant select on public.trades to authenticated;

-- ================================================================ baba_log
drop policy if exists baba_log_leitura on public.baba_log;
create policy baba_log_leitura on public.baba_log
  for select to authenticated
  using (auth.uid() = player_id);

grant select on public.baba_log to authenticated;

-- ================================================================ admin_log
-- Secao 18.3: somente leitura, e so para admin. Sem UPDATE e sem DELETE
-- para papel nenhum - nem admin apaga o proprio rastro.
drop policy if exists admin_log_leitura on public.admin_log;
create policy admin_log_leitura on public.admin_log
  for select to authenticated
  using (public.sou_admin());

grant select on public.admin_log to authenticated;
grant execute on function public.sou_admin() to authenticated;

-- ================================================================ auditoria de pacote
drop policy if exists pack_openings_leitura on public.pack_openings;
create policy pack_openings_leitura on public.pack_openings
  for select to authenticated
  using (auth.uid() = player_id);

drop policy if exists pack_opening_cards_leitura on public.pack_opening_cards;
create policy pack_opening_cards_leitura on public.pack_opening_cards
  for select to authenticated
  using (exists (
    select 1 from public.pack_openings o
    where o.id = pack_opening_cards.opening_id and o.player_id = auth.uid()
  ));

grant select on public.pack_openings, public.pack_opening_cards to authenticated;

-- ================================================================ recompensas
drop policy if exists album_page_rewards_leitura on public.album_page_rewards;
create policy album_page_rewards_leitura on public.album_page_rewards
  for select to authenticated
  using (auth.uid() = player_id);

grant select on public.album_page_rewards to authenticated;

-- trade_rewards e trava interna: ninguem le, ninguem escreve, so as RPCs.
-- Sem policy e sem grant de proposito.

-- ================================================================ service_role
-- Depois de todos os REVOKE acima, devolve tudo ao papel de servidor.
grant all on all tables     in schema public to service_role;
grant all on all sequences  in schema public to service_role;
grant all on all functions  in schema public to service_role;
grant usage on schema private to service_role;
grant all on all functions in schema private to service_role;

alter default privileges in schema public grant all on tables    to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;
