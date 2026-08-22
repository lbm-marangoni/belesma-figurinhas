-- BELESMA figurinhas - troca de apelido
--
-- A spec secao 10 diz "apelido unico e travado". Isto afrouxa o "travado",
-- mas mantem o "unico" no sentido forte: um apelido que ja foi de alguem
-- nunca vai para outra pessoa.
--
-- Por que isso importa: a figurinha exportada grava o apelido para dar
-- credito (secao 14). Se a "ana" virasse "bia" e outra pessoa pudesse
-- assumir "ana", todo arquivo antigo passaria a creditar a pessoa errada.
-- O historico abaixo impede exatamente isso.
--
-- O apelido tambem e a identidade de login: o e-mail interno e
-- <apelido>@belesma.local. Trocar um sem trocar o outro deixaria o jogador
-- sem conseguir entrar. As duas coisas mudam na mesma transacao.

create table if not exists public.nickname_history (
  id          bigserial primary key,
  player_id   uuid not null references public.players(id) on delete cascade,
  nickname    extensions.citext not null,
  usado_ate   timestamptz not null default now()
);
create unique index if not exists nickname_history_unico
  on public.nickname_history (nickname, player_id);
create index if not exists nickname_history_nick on public.nickname_history (nickname);

alter table public.nickname_history enable row level security;
-- o historico e publico: e ele que permite conferir credito de figurinha velha
drop policy if exists nickname_history_leitura on public.nickname_history;
create policy nickname_history_leitura on public.nickname_history
  for select to anon, authenticated using (true);
grant select on public.nickname_history to anon, authenticated;
grant all on public.nickname_history to service_role;
grant usage, select on sequence public.nickname_history_id_seq to service_role;

-- ---------------------------------------------------------------- disponibilidade
-- Agora tambem recusa apelido que ja foi de OUTRA pessoa. Retomar um apelido
-- que ja foi seu continua liberado.
create or replace function public.nickname_disponivel(p_nickname text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  -- Apelido EM USO nunca esta disponivel, nem para o proprio dono: quem
  -- digita o proprio apelido no formulario de troca recebe "ja esta em uso",
  -- que e verdade. A excecao vale so para o HISTORICO - retomar um apelido
  -- que ja foi seu continua liberado.
  select not exists (
    select 1 from public.players
    where nickname = p_nickname::extensions.citext
  ) and not exists (
    select 1 from public.nickname_history
    where nickname = p_nickname::extensions.citext
      and player_id is distinct from auth.uid()
  );
$$;

-- ---------------------------------------------------------------- troca
create or replace function public.mudar_nickname(p_novo text)
returns public.players
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid    uuid := auth.uid();
  v_atual  extensions.citext;
  v_row    public.players;
begin
  if v_uid is null then
    raise exception 'precisa estar logado' using errcode = '42501';
  end if;

  if p_novo !~ '^[a-z0-9][a-z0-9_-]{2,19}$' then
    raise exception 'apelido invalido: 3 a 20 caracteres, minusculas, numeros, - e _';
  end if;

  select nickname into v_atual from public.players where id = v_uid for update;
  if v_atual is null then raise exception 'jogador nao encontrado'; end if;
  if v_atual = p_novo::extensions.citext then
    raise exception 'esse ja e o seu apelido';
  end if;

  if exists (select 1 from public.players
             where nickname = p_novo::extensions.citext and id <> v_uid) then
    raise exception 'esse apelido ja esta em uso';
  end if;

  if exists (select 1 from public.nickname_history
             where nickname = p_novo::extensions.citext and player_id <> v_uid) then
    raise exception 'esse apelido ja foi de outra pessoa e nao pode ser reusado';
  end if;

  -- guarda o que estava em uso antes de sobrescrever
  insert into public.nickname_history (player_id, nickname)
  values (v_uid, v_atual)
  on conflict (nickname, player_id) do update set usado_ate = now();

  update public.players set nickname = p_novo::extensions.citext
  where id = v_uid
  returning * into v_row;

  -- o login e por <apelido>@belesma.local: sem isto o jogador nao entra mais
  update auth.users
  set email = p_novo || '@belesma.local',
      updated_at = now()
  where id = v_uid;

  return v_row;
exception
  when unique_violation then
    raise exception 'esse apelido ja esta em uso';
end;
$$;

revoke all on function public.mudar_nickname(text) from public, anon;
grant execute on function public.mudar_nickname(text) to authenticated;
alter function public.mudar_nickname(text) owner to postgres;
alter function public.nickname_disponivel(text) owner to postgres;
