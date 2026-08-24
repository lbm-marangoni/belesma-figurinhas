-- BELESMA figurinhas - entram Biscoito, Lucas e Luiz
--
-- Tres personagens novos, 27 skins cada, pelo mesmo caminho que o
-- seed_edition usa. Fica como migracao e nao como chamada de RPC para o
-- mundo ser reproduzivel: qualquer banco novo (o PGlite dos testes, por
-- exemplo) nasce com os seis.
--
-- O que cada um traz:
--   27 card_types (uma por skin)
--   2214 card_copies, com a tiragem de cada tier
--   selos por CSPRNG: 12 brancos, 4 pretos, 1 rosa
--   500 copias reservadas para o diario
--
-- O acervo do mundo passa de 6642 para 13284, e os selos de 36/12/3 para
-- 72/24/6. Isso muda a escassez de tudo - inclusive quem tem a joia do
-- servidor - e e assim que tem que ser: o censo se recalcula sozinho.

do $$
declare
  v_c    record;
  v_id   int;
  v_n    int;
begin
  for v_c in
    select * from (values
      ('biscoito', 'Belesma do Biscoito', 4, '#c98b3a', '#f2d08a'),
      ('lucas',    'Belesma do Lucas',    5, '#3a6fc9', '#8ab6f2'),
      ('luiz',     'Belesma do Luiz',     6, '#3ac98b', '#8af2c4')
    ) as t(slug, nome, ordem, primaria, acento)
  loop
    -- Idempotente por slug, igual ao seed_edition: se ja existe, nao encosta
    -- em card_copies. Reaplicar a cadeia inteira nao pode duplicar acervo.
    if exists (select 1 from public.characters
               where slug = v_c.slug::extensions.citext) then
      raise notice '% ja existe, pulando', v_c.slug;
      continue;
    end if;

    insert into public.characters (slug, name, display_order, palette_primary, palette_accent)
    values (v_c.slug::extensions.citext, v_c.nome, v_c.ordem, v_c.primaria, v_c.acento)
    returning id into v_id;

    insert into public.card_types (character_id, tier, tier_order, skin, print_run, art_path, album_page)
    select v_id, s.tier, t.tier_order, s.slug, t.print_run,
           '/figurinhas/' || v_c.slug || '/' || s.slug || '.jpg', ap.id
    from public.skins s
    join public.tiers t on t.slug = s.tier
    join public.album_pages ap on ap.slug = s.slug;

    -- o verify_code e deterministico por (personagem, skin, serial): a mesma
    -- carta gera o mesmo codigo em qualquer banco, e /v/<codigo> funciona
    insert into public.card_copies (card_type_id, serial_number, verify_code)
    select ct.id, g,
           upper(substr(encode(extensions.digest(
             'belesma-v1|' || v_c.slug || '|' || ct.skin || '|' || g::text, 'sha256'),
             'hex'), 1, 10))
    from public.card_types ct
    cross join lateral generate_series(1, ct.print_run) g
    where ct.character_id = v_id;

    perform private.distribuir_selos(v_id);
    perform private.reservar_diario(v_id, 500);

    select count(*) into v_n
    from public.card_copies cc
    join public.card_types ct on ct.id = cc.card_type_id
    where ct.character_id = v_id;
    raise notice '% : % copias', v_c.slug, v_n;
  end loop;
end $$;

-- ---------------------------------------------------------------- boosters
-- Um Booster por personagem, como os tres primeiros. Sem isto a loja ficaria
-- com tres boosters e seis Belesmas.
do $$
declare v_c record;
begin
  for v_c in select id from public.characters order by display_order, id loop
    perform private.criar_booster_de_personagem(v_c.id);
  end loop;
end $$;

-- ---------------------------------------------------------------- reserva
-- A reserva do diario era 1500 divididos entre os personagens - com tres,
-- 500 cada. Com seis isso viraria 250 cada, e como reservar_diario so
-- ACRESCENTA, os tres antigos ficariam em 500 e os novos em 250: metade da
-- prateleira para quem chegou depois, sem motivo nenhum.
--
-- O alvo passa a ser POR PERSONAGEM. Cada Belesma traz 2214 copias proprias,
-- entao a prateleira dele acompanha - e o total cresce junto com o mundo em
-- vez de encolher por cabeca.
create or replace function private.repor_reserva()
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare v_alvo int; v_total int := 0; v_c record;
begin
  v_alvo := coalesce(private.preco('reserva_por_personagem')::int, 500);
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id, v_alvo);
  end loop;
  return v_total;
end;
$fn$;

insert into public.economy_config (chave, valor, descricao) values
  ('reserva_por_personagem', 500,
   'Copias de comum/incomum reservadas para o diario, por personagem')
on conflict (chave) do nothing;

revoke all on function private.repor_reserva() from public, anon, authenticated;

-- o reset total tambem passa a usar o alvo por personagem, em vez do 500
-- escrito na mao
create or replace function public.admin_recomecar_do_zero(p_confirmacao text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_forjadas int; v_devolvidas int; v_jogadores int; v_estreias int;
  v_p record; v_d record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RECOMECAR DO ZERO' then
    raise exception 'confirmacao invalida: digite RECOMECAR DO ZERO';
  end if;

  delete from public.trades             where true;
  delete from public.trade_rewards      where true;
  delete from public.album_colagem      where true;
  delete from public.pack_opening_cards where true;
  delete from public.pack_openings      where true;
  delete from public.copy_history       where true;
  delete from public.baba_log           where true;
  delete from public.player_packs       where true;

  delete from public.card_copies where origin = 'forge';
  get diagnostics v_forjadas = row_count;

  select count(*) into v_estreias
  from public.card_copies where first_discovered_at is not null;

  update public.card_copies
  set owner_id = null, claimed_at = null, burned = false, damage_level = 0,
      first_discovered_at = null, first_discovered_by = null, reserved_for_daily = false
  where true;
  get diagnostics v_devolvidas = row_count;

  update public.players set
    baba = 0, pity_counter = 0, dailies_claimed = 0, last_daily_at = null,
    showcase_1 = null, showcase_2 = null, showcase_3 = null
  where true;
  get diagnostics v_jogadores = row_count;

  for v_p in select id from public.players loop
    for v_d in select id, allotment_quantidade from public.pack_definitions
               where ativo and allotment_quantidade > 0
    loop
      perform private.dar_pacote(v_p.id, v_d.id, false, v_d.allotment_quantidade);
    end loop;
  end loop;

  update public.pack_definitions set aberturas_realizadas = 0 where true;

  perform private.repor_reserva();

  perform private.registrar('admin_recomecar_do_zero', 'mundo',
    jsonb_build_object('forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
                       'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores));

  return jsonb_build_object(
    'forjadas_apagadas', v_forjadas, 'copias_devolvidas', v_devolvidas,
    'estreias_apagadas', v_estreias, 'jogadores_zerados', v_jogadores,
    'reservadas_para_diario',
      (select count(*) from public.card_copies where reserved_for_daily));
end;
$fn$;

alter function public.admin_recomecar_do_zero(text) owner to postgres;
grant execute on function public.admin_recomecar_do_zero(text) to authenticated;

select private.fechar_grants();
