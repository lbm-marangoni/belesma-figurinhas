-- BELESMA figurinhas - Fase 2: RPCs administrativas (spec secao 18)
--
-- NAO existe admin_key. Toda funcao aqui comeca com private.require_admin(),
-- que checa auth.uid() contra players.is_admin dentro do banco.
--
-- Elas sao CHAMAVEIS por authenticated de proposito: o erro precisa ser
-- "nao autorizado", nao "function does not exist", para o teste de fraude da
-- secao 17 ser conclusivo.

create or replace function private.registrar(p_acao text, p_alvo text, p_payload jsonb)
returns void
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  insert into public.admin_log (admin_id, acao, alvo, payload)
  values (auth.uid(), p_acao, p_alvo, p_payload);
$$;

-- ================================================================ jogadores
create or replace function public.admin_jogadores()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'nickname', p.nickname, 'created_at', p.created_at,
      'is_admin', p.is_admin, 'baba', p.baba,
      'copias', (select count(*) from public.card_copies cc where cc.owner_id = p.id),
      'pacotes', jsonb_build_object(
        'comum', p.packs_common, 'raro', p.packs_rare, 'ultra', p.packs_ultra,
        'comum_diario', p.packs_common_daily, 'raro_diario', p.packs_rare_daily,
        'ultra_diario', p.packs_ultra_daily),
      'last_daily_at', p.last_daily_at, 'pity_counter', p.pity_counter
    ) order by p.created_at)
    from public.players p), '[]'::jsonb);
end;
$$;

create or replace function public.grant_packs(p_target text, p_pack_type text, p_quantidade int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n int; v_tipo public.pack_type := p_pack_type::public.pack_type;
begin
  perform private.require_admin();
  if p_quantidade is null or p_quantidade = 0 then raise exception 'quantidade invalida'; end if;

  update public.players p
  set packs_common = p.packs_common + (case when v_tipo = 'comum' then p_quantidade else 0 end),
      packs_rare   = p.packs_rare   + (case when v_tipo = 'raro'  then p_quantidade else 0 end),
      packs_ultra  = p.packs_ultra  + (case when v_tipo = 'ultra' then p_quantidade else 0 end)
  where p_target = 'todos' or p.nickname = p_target::extensions.citext;
  get diagnostics v_n = row_count;

  perform private.registrar('grant_packs', p_target,
    jsonb_build_object('pack_type', p_pack_type, 'quantidade', p_quantidade, 'jogadores', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_reset_password(p_nickname text, p_nova_senha text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid;
begin
  perform private.require_admin();
  if length(coalesce(p_nova_senha, '')) < 6 then raise exception 'senha minima de 6 caracteres'; end if;

  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  -- Secao 10: nao existe recuperacao automatica; o reset e manual e passa
  -- por aqui. A senha nunca e gravada no admin_log.
  update auth.users
  set encrypted_password = extensions.crypt(p_nova_senha, extensions.gen_salt('bf')),
      updated_at = now()
  where id = v_id;

  perform private.registrar('admin_reset_password', p_nickname, jsonb_build_object('senha', 'omitida'));
end;
$$;

create or replace function public.admin_reset_daily_cooldown(p_nickname text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  update public.players set last_daily_at = null where nickname = p_nickname::extensions.citext;
  if not found then raise exception 'jogador nao encontrado'; end if;
  perform private.registrar('admin_reset_daily_cooldown', p_nickname, '{}'::jsonb);
end;
$$;

-- ================================================================ odds e precos
-- Uma migracao posterior troca o retorno para void (a funcao passou a so
-- recusar: pack_config nao alimenta mais o sorteio). Sem o drop, reaplicar a
-- cadeia inteira estoura com "cannot change return type".
drop function if exists public.admin_set_pack_config(jsonb);
create or replace function public.admin_set_pack_config(p_rows jsonb)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_antes jsonb; v_n int; v_erro text;
begin
  perform private.require_admin();

  select jsonb_agg(to_jsonb(pc)) into v_antes from public.pack_config pc;

  update public.pack_config pc
  set weight = (r->>'weight')::numeric
  from jsonb_array_elements(p_rows) r
  where pc.pack_type = (r->>'pack_type')::public.pack_type
    and pc.slot      = (r->>'slot')::public.pack_slot
    and pc.tier      = r->>'tier';
  get diagnostics v_n = row_count;

  -- Secao 18.1: cada tipo de pacote soma 100%. Nao salva torto.
  select string_agg(x.pack_type || '/' || x.slot || ' = ' || x.total, ', ')
    into v_erro
  from (select pack_type::text, slot::text, sum(weight) as total
        from public.pack_config group by pack_type, slot) x
  where x.total <> 100;

  if v_erro is not null then
    raise exception 'as odds precisam somar 100: %', v_erro;
  end if;

  perform private.registrar('admin_set_pack_config', null,
    jsonb_build_object('antes', v_antes, 'depois', p_rows, 'linhas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_set_economy_config(p_rows jsonb)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_antes jsonb; v_n int;
begin
  perform private.require_admin();
  select jsonb_agg(to_jsonb(ec)) into v_antes from public.economy_config ec;

  update public.economy_config ec
  set valor = (r->>'valor')::numeric
  from jsonb_array_elements(p_rows) r
  where ec.chave = r->>'chave';
  get diagnostics v_n = row_count;

  perform private.registrar('admin_set_economy_config', null,
    jsonb_build_object('antes', v_antes, 'depois', p_rows, 'linhas', v_n));
  return v_n;
end;
$$;

-- ================================================================ estoque
create or replace function public.top_up_daily_reserve(p_n int)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_por_char int; v_total int := 0; v_c record;
begin
  perform private.require_admin();
  if p_n is null or p_n <= 0 then raise exception 'n invalido'; end if;

  v_por_char := ceil(p_n::numeric / greatest((select count(*) from public.characters), 1));
  for v_c in select id from public.characters order by id loop
    v_total := v_total + private.reservar_diario(v_c.id,
      (select count(*) from public.card_copies cc
       join public.card_types ct on ct.id = cc.card_type_id
       where ct.character_id = v_c.id and cc.reserved_for_daily and not cc.burned)::int + v_por_char);
  end loop;

  perform private.registrar('top_up_daily_reserve', null,
    jsonb_build_object('pedido', p_n, 'marcadas', v_total));
  return v_total;
end;
$$;

create or replace function public.admin_stock_report()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return jsonb_build_object(
    'por_tier', (
      select coalesce(jsonb_agg(x order by x->>'tier_order'), '[]'::jsonb) from (
        select jsonb_build_object(
          'tier', t.slug, 'tier_order', t.tier_order,
          'total', count(cc.id),
          'distribuidas', count(*) filter (where cc.owner_id is not null),
          'queimadas',    count(*) filter (where cc.burned),
          'reservadas',   count(*) filter (where cc.reserved_for_daily and cc.owner_id is null),
          'disponiveis',  count(*) filter (where cc.owner_id is null and not cc.burned)
        ) as x
        from public.tiers t
        join public.card_types ct on ct.tier = t.slug
        join public.card_copies cc on cc.card_type_id = ct.id
        group by t.slug, t.tier_order) y),
    'por_personagem', (
      select coalesce(jsonb_agg(x order by x->>'display_order'), '[]'::jsonb) from (
        select jsonb_build_object(
          'personagem', ch.slug, 'display_order', ch.display_order,
          'total', count(cc.id),
          'distribuidas', count(*) filter (where cc.owner_id is not null),
          'queimadas',    count(*) filter (where cc.burned),
          'disponiveis',  count(*) filter (where cc.owner_id is null and not cc.burned)
        ) as x
        from public.characters ch
        join public.card_types ct on ct.character_id = ch.id
        join public.card_copies cc on cc.card_type_id = ct.id
        group by ch.slug, ch.display_order) y),
    'selos', (
      select jsonb_build_object(
        'emitidos', count(*) filter (where cc.seal <> 'none'),
        'em_posse', count(*) filter (where cc.seal <> 'none' and cc.owner_id is not null),
        'branco', count(*) filter (where cc.seal = 'branco'),
        'preto',  count(*) filter (where cc.seal = 'preto'),
        'rosa',   count(*) filter (where cc.seal = 'rosa'))
      from public.card_copies cc),
    'desgaste', (
      select coalesce(jsonb_object_agg(damage_level::text, n), '{}'::jsonb)
      from (select damage_level, count(*) as n from public.card_copies group by damage_level) d),
    'reserva_diaria', (
      select count(*) from public.card_copies where reserved_for_daily and owner_id is null)
  );
end;
$$;

-- O banco nao enxerga disco. Devolve o catalogo com os caminhos; quem
-- confere a existencia do arquivo e o painel, com um HEAD em cada um.
create or replace function public.admin_missing_art()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform private.require_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'card_type_id', ct.id, 'personagem', ch.slug, 'skin', ct.skin, 'art_path', ct.art_path)
      order by ch.display_order, ct.tier_order)
    from public.card_types ct join public.characters ch on ch.id = ct.character_id), '[]'::jsonb);
end;
$$;

-- ================================================================ conteudo
create or replace function public.seed_edition_dry_run(p_params jsonb)
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare v_slug text := lower(p_params->>'slug');
begin
  perform private.require_admin();
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{2,19}$' then
    raise exception 'slug invalido';
  end if;

  return jsonb_build_object(
    'slug', v_slug,
    'ja_existe', exists (select 1 from public.characters where slug = v_slug::extensions.citext),
    'card_types', (select count(*) from public.skins),
    'card_copies', (select sum(t.print_run) from public.skins s join public.tiers t on t.slug = s.tier),
    'selos', jsonb_build_object('branco', 12, 'preto', 4, 'rosa', 1),
    'reserva_diaria', 500,
    'art_paths', (select jsonb_agg('/figurinhas/' || v_slug || '/' || s.slug || '.jpg' order by s.skin_order)
                  from public.skins s)
  );
end;
$$;

create or replace function public.seed_edition(p_params jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_slug text := lower(p_params->>'slug');
  v_id   int;
  v_copias int;
begin
  perform private.require_admin();
  if v_slug is null or v_slug !~ '^[a-z0-9][a-z0-9-]{2,19}$' then
    raise exception 'slug invalido';
  end if;

  -- Secao 16: idempotente por slug. Se ja existe, aborta SEM escrever nada.
  -- Nunca faz DELETE nem UPDATE em card_copies existentes.
  if exists (select 1 from public.characters where slug = v_slug::extensions.citext) then
    raise exception 'personagem % ja existe', v_slug;
  end if;

  insert into public.characters (slug, name, display_order, palette_primary, palette_accent)
  values (v_slug::extensions.citext,
          coalesce(p_params->>'name', initcap(v_slug)),
          coalesce((p_params->>'display_order')::int,
                   (select coalesce(max(display_order), 0) + 1 from public.characters)),
          coalesce(p_params->>'palette_primary', '#555555'),
          coalesce(p_params->>'palette_accent',  '#999999'))
  returning id into v_id;

  insert into public.card_types (character_id, tier, tier_order, skin, print_run, art_path, album_page)
  select v_id, s.tier, t.tier_order, s.slug, t.print_run,
         '/figurinhas/' || v_slug || '/' || s.slug || '.jpg', ap.id
  from public.skins s
  join public.tiers t on t.slug = s.tier
  join public.album_pages ap on ap.slug = s.slug;

  insert into public.card_copies (card_type_id, serial_number, verify_code)
  select ct.id, g,
         upper(substr(encode(extensions.digest(
           'belesma-v1|' || v_slug || '|' || ct.skin || '|' || g::text, 'sha256'), 'hex'), 1, 10))
  from public.card_types ct
  cross join lateral generate_series(1, ct.print_run) g
  where ct.character_id = v_id;

  perform private.distribuir_selos(v_id);
  perform private.reservar_diario(v_id, 500);

  select count(*) into v_copias
  from public.card_copies cc join public.card_types ct on ct.id = cc.card_type_id
  where ct.character_id = v_id;

  perform private.registrar('seed_edition', v_slug,
    jsonb_build_object('character_id', v_id, 'copias', v_copias));

  return jsonb_build_object('character_id', v_id, 'slug', v_slug, 'copias', v_copias,
    'selos', (select to_jsonb(a) from public.seal_audit a where a.character_id = v_id));
end;
$$;

-- ================================================================ zona de perigo
-- Secao 18.2: nenhum reset apaga card_types nem characters. So posse.
create or replace function private.devolver_ao_pool(p_owner uuid)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $$
declare v_n int;
begin
  insert into public.copy_history (copy_id, from_player, to_player, kind)
  select id, p_owner, null, 'admin_reset' from public.card_copies where owner_id = p_owner;

  -- Forjada e supply paralelo: devolver ao pool colocaria carta forjada
  -- dentro de pacote. Queima em vez de devolver.
  update public.card_copies
  set owner_id = null, claimed_at = null, burned = true
  where owner_id = p_owner and origin = 'forge';

  -- Puxada volta inteira: mantem id, serial, selo e damage_level.
  -- first_discovered_* NAO e tocado - estreia mundial e historia, nao posse.
  update public.card_copies
  set owner_id = null, claimed_at = null
  where owner_id = p_owner and origin = 'pull';
  get diagnostics v_n = row_count;

  update public.players
  set showcase_1 = null, showcase_2 = null, showcase_3 = null
  where id = p_owner;

  return v_n;
end;
$$;

create or replace function public.admin_reset_player_collection(p_nickname text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid; v_n int;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and (from_player = v_id or to_player = v_id);

  v_n := private.devolver_ao_pool(v_id);
  perform private.registrar('admin_reset_player_collection', p_nickname,
    jsonb_build_object('devolvidas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_reset_all_collections(p_confirmacao text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_n int := 0; v_p record;
begin
  perform private.require_admin();
  if p_confirmacao <> 'RESETAR' then
    raise exception 'confirmacao invalida: digite RESETAR';
  end if;

  update public.trades set status = 'cancelled', resolved_at = now() where status = 'pending';
  for v_p in select id from public.players loop
    v_n := v_n + private.devolver_ao_pool(v_p.id);
  end loop;

  perform private.registrar('admin_reset_all_collections', 'todos',
    jsonb_build_object('devolvidas', v_n));
  return v_n;
end;
$$;

create or replace function public.admin_delete_player(p_nickname text)
returns int
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare v_id uuid; v_n int;
begin
  perform private.require_admin();
  select id into v_id from public.players where nickname = p_nickname::extensions.citext;
  if v_id is null then raise exception 'jogador nao encontrado'; end if;
  if v_id = auth.uid() then raise exception 'nao da para apagar a si mesmo'; end if;

  update public.trades set status = 'cancelled', resolved_at = now()
  where status = 'pending' and (from_player = v_id or to_player = v_id);
  v_n := private.devolver_ao_pool(v_id);

  perform private.registrar('admin_delete_player', p_nickname,
    jsonb_build_object('devolvidas', v_n, 'player_id', v_id));

  -- players.id referencia auth.users on delete cascade
  delete from auth.users where id = v_id;
  return v_n;
end;
$$;

-- ================================================================ permissoes
do $$
declare f text;
begin
  foreach f in array array[
    'admin_jogadores()', 'grant_packs(text,text,int)', 'admin_reset_password(text,text)',
    'admin_reset_daily_cooldown(text)', 'admin_set_pack_config(jsonb)',
    'admin_set_economy_config(jsonb)', 'top_up_daily_reserve(int)', 'admin_stock_report()',
    'admin_missing_art()', 'seed_edition_dry_run(jsonb)', 'seed_edition(jsonb)',
    'admin_reset_player_collection(text)', 'admin_reset_all_collections(text)',
    'admin_delete_player(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
    execute format('alter function public.%s owner to postgres', f);
  end loop;
end $$;
