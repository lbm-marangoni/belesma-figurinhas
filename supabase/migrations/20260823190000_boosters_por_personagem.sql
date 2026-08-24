-- BELESMA figurinhas - o pacote dirigido vira um booster por personagem

-- O "pacote dirigido" era um parametro escondido em comprar_pacote: um
-- select na loja mandava p_character_id e o preco dobrava. Ninguem via um
-- produto - via um modificador. E ele nao existia no catalogo, entao nao
-- tinha arte, nem descricao, nem EV proprio, nem aparecia no relatorio.
--
-- Vira definicao de verdade: um booster por personagem, com o filtro no
-- proprio slot. Mesma estrutura do Booster Comum, so que restrito.
create or replace function private.criar_booster_de_personagem(p_character_id int)
returns int
language plpgsql volatile
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_ch    public.characters;
  v_base  public.pack_definitions;
  v_slug  text;
  v_def   int;
  v_slot  int;
  v_s     record;
  v_mult  numeric;
  v_curto text;
begin
  select * into v_ch from public.characters where id = p_character_id;
  if v_ch.id is null then raise exception 'personagem % nao existe', p_character_id; end if;

  v_slug := 'booster-' || v_ch.slug;
  if exists (select 1 from public.pack_definitions where slug = v_slug::extensions.citext) then
    return (select id from public.pack_definitions where slug = v_slug::extensions.citext);
  end if;

  -- o molde e o Booster Comum: mesmas odds, mesma variancia, mesmo tamanho
  select * into v_base from public.pack_definitions where slug = 'comum';
  if v_base.id is null then
    raise notice 'sem Booster Comum de molde, nada a criar';
    return null;
  end if;
  v_mult := coalesce(private.preco('dirigido_mult'), 2);
  -- characters.name ja e "Belesma do Pedrao"; sem tirar o prefixo o produto
  -- vira "Booster Belesma do Pedrao", que ninguem chama assim
  v_curto := regexp_replace(v_ch.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i');
  if v_curto = '' then v_curto := v_ch.name; end if;

  insert into public.pack_definitions (
    slug, name, descricao, art_path, tamanho, distribuicao, elegivel_loja,
    preco_baba, taxa_quente, taxa_bonus, taxa_promocao, pity_limite, pity_piso_tier,
    ativo)
  values (
    v_slug::extensions.citext,
    'Booster ' || v_curto,
    'Só ' || v_ch.name || '. Mesmas odds do Comum, restrito a um Belesma — '
      || 'serve para fechar página do álbum.',
    v_base.art_path,
    v_base.tamanho, 'loja', true,
    ceil(v_base.preco_baba * v_mult)::int,
    v_base.taxa_quente, v_base.taxa_bonus, v_base.taxa_promocao,
    v_base.pity_limite, v_base.pity_piso_tier,
    true)
  returning id into v_def;

  -- copia os slots do molde, acrescentando o filtro do personagem
  for v_s in select * from public.pack_slots
             where pack_definition_id = v_base.id order by ordem
  loop
    insert into public.pack_slots (pack_definition_id, ordem, filtro, garantido)
    values (v_def, v_s.ordem,
            coalesce(v_s.filtro, '{}'::jsonb)
              || jsonb_build_object('characters', jsonb_build_array(v_ch.slug)),
            v_s.garantido)
    returning id into v_slot;

    insert into public.pack_slot_odds (pack_slot_id, tier, weight)
    select v_slot, o.tier, o.weight
    from public.pack_slot_odds o where o.pack_slot_id = v_s.id;
  end loop;

  return v_def;
end;
$fn$;

-- um para cada personagem que ja existe
do $$
declare v_c record;
begin
  for v_c in select id, slug from public.characters order by display_order, id loop
    perform private.criar_booster_de_personagem(v_c.id);
  end loop;
end $$;

-- ---------------------------------------------------------------- futuro
-- O quarto personagem entra por seed_edition. O booster dele nasce junto:
-- sem isto, alguem teria que lembrar de criar na mao, e a loja ficaria com
-- tres boosters e quatro Belesmas.
create or replace function public.admin_criar_booster_faltando()
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_c record; v_criados jsonb := '[]'::jsonb; v_id int;
begin
  perform private.require_admin();
  for v_c in select id, slug, name from public.characters order by display_order, id loop
    if not exists (select 1 from public.pack_definitions
                   where slug = ('booster-' || v_c.slug)::extensions.citext) then
      v_id := private.criar_booster_de_personagem(v_c.id);
      v_criados := v_criados || jsonb_build_object('id', v_id, 'personagem', v_c.name);
    end if;
  end loop;
  if jsonb_array_length(v_criados) > 0 then
    perform private.registrar('boosters_de_personagem_criados', null, v_criados);
  end if;
  return v_criados;
end;
$fn$;

-- ---------------------------------------------------------------- dirigido
-- O parametro some. Deixar aceitar em silencio faria a loja cobrar o dobro e
-- entregar um pacote sem filtro nenhum - pior que recusar.
create or replace function public.comprar_pacote(p_pack_type text, p_character_id int default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_def   public.pack_definitions;
  v_teto  int;
  v_hoje  int;
  v_saldo int;
begin
  if v_uid is null then raise exception 'precisa estar logado' using errcode = '42501'; end if;
  if p_character_id is not null then
    raise exception 'o pacote dirigido virou produto: compre o Booster do personagem na loja';
  end if;

  select * into v_def from public.pack_definitions
  where slug = p_pack_type::extensions.citext;
  if v_def.id is null then raise exception 'pacote "%" nao existe', p_pack_type; end if;
  if not v_def.ativo then raise exception 'pacote "%" esta desativado', v_def.name; end if;
  if not v_def.elegivel_loja then raise exception '"%" nao esta a venda', v_def.name; end if;

  if v_def.limite_global is not null
     and v_def.aberturas_realizadas >= v_def.limite_global then
    raise exception 'edicao esgotada'; end if;

  v_teto := private.preco('teto_compra_dia')::int;
  select count(*) into v_hoje from public.baba_log
  where player_id = v_uid and motivo = 'compra' and created_at > now() - interval '24 hours';
  if v_hoje >= v_teto then
    raise exception 'limite de % compras por dia atingido', v_teto;
  end if;

  v_saldo := private.mover_baba(v_uid, -v_def.preco_baba, 'compra', v_def.slug::text);
  perform private.dar_pacote(v_uid, v_def.id, false, 1);

  return jsonb_build_object('preco', v_def.preco_baba, 'saldo', v_saldo,
    'restantes_hoje', v_teto - v_hoje - 1, 'pack_definition_id', v_def.id,
    'nome', v_def.name);
end;
$fn$;

-- ---------------------------------------------------------------- pack_config
-- A tabela vira registro historico: foi o molde de onde os slots nasceram, e
-- fica como procedencia. Mas EDITAR nao muda nada no jogo desde que o
-- open_pack passou a ler pack_slot_odds - e uma RPC que diz "salvo" sem
-- efeito e pior que uma que nao existe.
-- o original devolvia a diferenca aplicada; agora so recusa, entao muda o
-- tipo de retorno e precisa cair antes
drop function if exists public.admin_set_pack_config(jsonb);
create or replace function public.admin_set_pack_config(p_linhas jsonb)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  perform private.require_admin();
  raise exception 'pack_config nao alimenta mais o sorteio: as odds vivem em pack_slot_odds, por definicao de pacote. Edite em /admin > Pacotes.';
end;
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'admin_criar_booster_faltando()', 'comprar_pacote(text, int)',
    'admin_set_pack_config(jsonb)']
  loop
    execute format('alter function public.%s owner to postgres', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

select private.fechar_grants();

-- os primeiros nasceram com o nome comprido; renomeia sem recriar
update public.pack_definitions d set name = 'Booster ' ||
  regexp_replace(c.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i')
from public.characters c
where d.slug = ('booster-' || c.slug)::extensions.citext
  and d.name <> 'Booster ' ||
      regexp_replace(c.name, '^\s*Belesma\s+(do|da|de|dos|das)?\s*', '', 'i');
