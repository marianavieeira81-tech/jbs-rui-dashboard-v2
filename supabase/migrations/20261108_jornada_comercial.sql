-- ============================================================================
-- [JORNADA_08_11] Jornada Comercial do lead
-- Recebido -> Qualificado -> Com vendedor -> Visitou a loja -> Vendeu / Não vendeu
--
-- Tudo ADITIVO e IDEMPOTENTE: pode rodar mais de uma vez. Nada é apagado ou
-- renomeado (a única troca é a função ian_vendedor_acao, recriada com um
-- parâmetro a mais e com TODO o comportamento antigo preservado).
--
-- Como rodar: cole o arquivo inteiro no SQL Editor do Supabase e execute.
-- Ordem de implantação: (1) este SQL -> (2) n8n -> (3) painel.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. PRÉ-CHECAGEM — permissões atuais da função (anote o resultado).
--    Lido em 08/11: postgres, anon, authenticated, service_role = EXECUTE.
--    O bloco 1.4 reaplica exatamente essas 4.
-- ----------------------------------------------------------------------------
select grantee, privilege_type
  from information_schema.routine_privileges
 where routine_schema = 'public' and routine_name = 'ian_vendedor_acao'
 order by grantee;


-- ----------------------------------------------------------------------------
-- 1.1 Colunas novas em leads
-- (obs.: já existem leads.origem_visita e leads.total_visitas, de outro uso —
--  não são tocadas; a jornada usa as colunas novas abaixo)
-- ----------------------------------------------------------------------------
alter table public.leads add column if not exists visitou_loja_em       timestamptz;
alter table public.leads add column if not exists visita_registrada_por text;
alter table public.leads add column if not exists visita_origem         text;
alter table public.leads add column if not exists venda_motivo_perda    text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'leads_visita_origem_chk') then
    alter table public.leads add constraint leads_visita_origem_chk
      check (visita_origem is null or visita_origem in ('vendedor','checkin','test_drive'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'leads_venda_motivo_perda_chk') then
    alter table public.leads add constraint leads_venda_motivo_perda_chk
      check (venda_motivo_perda is null or venda_motivo_perda in
        ('preco_condicao','financiamento_negado','avaliacao_troca','comprou_concorrente','vai_pensar','desistiu','outro'));
  end if;
end $$;

-- 1.2 Coluna nova em atendimentos_vendedor
alter table public.atendimentos_vendedor add column if not exists visitou_loja_em timestamptz;


-- ----------------------------------------------------------------------------
-- 1.3 Tabela de eventos da jornada (histórico de cada clique/automação)
-- ----------------------------------------------------------------------------
create table if not exists public.leads_jornada_eventos (
  id                bigserial primary key,
  concessionaria_id uuid,
  sender_id         text,
  evento            text not null,
  vendedor          text,
  motivo            text,
  origem            text,
  criado_em         timestamptz not null default now(),
  constraint leads_jornada_eventos_evento_chk
    check (evento in ('assumiu','visitou','desfez_visita','vendeu','nao_vendeu','desfez_venda')),
  constraint leads_jornada_eventos_origem_chk
    check (origem is null or origem in ('painel','checkin','test_drive','backfill'))
);
create index if not exists leads_jornada_eventos_loja_data_idx on public.leads_jornada_eventos (concessionaria_id, criado_em);
create index if not exists leads_jornada_eventos_sender_idx    on public.leads_jornada_eventos (sender_id);
-- RLS ligado e SEM policies: ninguém lê/grava direto pela API; só as funções SECURITY DEFINER abaixo.
alter table public.leads_jornada_eventos enable row level security;


-- ----------------------------------------------------------------------------
-- 1.4 Função ian_vendedor_acao — recriada com p_motivo (último parâmetro, opcional).
--     Chamadas antigas (6 parâmetros) continuam funcionando, porque p_motivo tem DEFAULT.
--     Tudo numa transação: se algo falhar, a função antiga continua no ar.
-- ----------------------------------------------------------------------------
begin;

drop function if exists public.ian_vendedor_acao(uuid, text, text, text, text, text);

create or replace function public.ian_vendedor_acao(
  p_token    uuid,
  p_acao     text,
  p_sender   text DEFAULT NULL::text,
  p_vendedor text DEFAULT NULL::text,
  p_status   text DEFAULT NULL::text,
  p_mes      text DEFAULT NULL::text,
  p_motivo   text DEFAULT NULL::text            -- [JORNADA_08_11] motivo do "não vendeu"
)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_loja uuid; v_painel jsonb; v_nome text; v_tel text; v_atual text; v_ultimo timestamptz;
  v_mes text; v_ini timestamptz; v_fim timestamptz; v_res json; v_vend text;
  v_visita timestamptz; v_venda text; v_motivo text;           -- [JORNADA_08_11]
begin
  -- [AGENDA_TD_31_10] agenda de test drive
  if p_acao in ('agenda_status', 'agenda_salvar') then
    return ian_agenda_acao(p_token, p_acao, p_sender, p_vendedor, p_status, p_mes);
  end if;
  select c.id, coalesce(c.vendedores_painel, '[]'::jsonb) into v_loja, v_painel
    from sessoes_dashboard s join concessionarias c on c.id = s.concessionaria_id
   where s.token = p_token and s.expira_em > now() and c.ativo = true limit 1;
  if v_loja is null then return json_build_object('ok', false, 'motivo', 'sessao'); end if;
  v_vend := nullif(left(trim(coalesce(p_vendedor, '')), 80), '');

  if p_acao = 'assumir' then
    if v_vend is null or coalesce(p_sender, '') = '' then return json_build_object('ok', false, 'motivo', 'dados'); end if;
    select max(atendido_em) into v_ultimo from atendimentos_vendedor
     where concessionaria_id = v_loja and lower(vendedor) = lower(v_vend) and canal = 'whatsapp';
    if v_ultimo is not null and v_ultimo > now() - interval '15 minutes' then
      return json_build_object('ok', false, 'motivo', 'cooldown',
        'minutos', ceil(extract(epoch from (v_ultimo + interval '15 minutes' - now())) / 60));
    end if;
    update leads set vendedor_responsavel = v_vend, vendedor_assumiu_em = now(), venda_status = null, venda_marcada_em = null
     where concessionaria_id = v_loja and sender_id = p_sender and vendedor_responsavel is null
     returning nome, telefone into v_nome, v_tel;
    if not found then
      select vendedor_responsavel into v_atual from leads where concessionaria_id = v_loja and sender_id = p_sender;
      if not found then return json_build_object('ok', false, 'motivo', 'lead_nao_encontrado'); end if;
      return json_build_object('ok', false, 'motivo', 'ja_assumido', 'vendedor', v_atual);
    end if;
    insert into atendimentos_vendedor (vendedor, canal, lead_nome, lead_telefone, lead_sender_id, convertido, atendido_em, concessionaria_id)
    values (v_vend, 'whatsapp', v_nome, coalesce(v_tel, p_sender), p_sender, null, now(), v_loja);
    -- [JORNADA_08_11]
    insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
    values (v_loja, p_sender, 'assumiu', v_vend, 'painel');
    return json_build_object('ok', true, 'vendedor', v_vend);

  -- [JORNADA_08_11] vendedor marca que o lead foi à loja
  elsif p_acao = 'visita' then
    if coalesce(p_sender, '') = '' then return json_build_object('ok', false, 'motivo', 'dados'); end if;
    select vendedor_responsavel, visitou_loja_em into v_atual, v_visita
      from leads where concessionaria_id = v_loja and sender_id = p_sender;
    if not found then return json_build_object('ok', false, 'motivo', 'lead_nao_encontrado'); end if;
    if v_atual is null then return json_build_object('ok', false, 'motivo', 'sem_vendedor'); end if;
    if v_visita is not null then   -- já registrada: não altera nada
      return json_build_object('ok', true, 'vendedor', v_atual, 'visitou_loja_em', v_visita, 'ja_registrada', true);
    end if;
    update leads set visitou_loja_em = now(), visita_registrada_por = vendedor_responsavel, visita_origem = 'vendedor'
     where concessionaria_id = v_loja and sender_id = p_sender
     returning visitou_loja_em into v_visita;
    update atendimentos_vendedor set visitou_loja_em = v_visita
     where id = (select id from atendimentos_vendedor where concessionaria_id = v_loja and lead_sender_id = p_sender order by atendido_em desc limit 1);
    insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
    values (v_loja, p_sender, 'visitou', v_atual, 'painel');
    return json_build_object('ok', true, 'vendedor', v_atual, 'visitou_loja_em', v_visita);

  -- [JORNADA_08_11] desfaz a visita (só se ainda não tem venda marcada)
  elsif p_acao = 'desfazer_visita' then
    if coalesce(p_sender, '') = '' then return json_build_object('ok', false, 'motivo', 'dados'); end if;
    select vendedor_responsavel, venda_status into v_atual, v_venda
      from leads where concessionaria_id = v_loja and sender_id = p_sender;
    if not found then return json_build_object('ok', false, 'motivo', 'lead_nao_encontrado'); end if;
    if v_venda is not null then return json_build_object('ok', false, 'motivo', 'tem_venda'); end if;
    update leads set visitou_loja_em = null, visita_registrada_por = null, visita_origem = null
     where concessionaria_id = v_loja and sender_id = p_sender;
    update atendimentos_vendedor set visitou_loja_em = null
     where id = (select id from atendimentos_vendedor where concessionaria_id = v_loja and lead_sender_id = p_sender order by atendido_em desc limit 1);
    insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
    values (v_loja, p_sender, 'desfez_visita', v_atual, 'painel');
    return json_build_object('ok', true, 'vendedor', v_atual);

  elsif p_acao = 'venda' then
    if p_status not in ('vendeu', 'nao_vendeu') or coalesce(p_sender, '') = '' then
      return json_build_object('ok', false, 'motivo', 'dados');
    end if;
    -- [JORNADA_08_11] venda só depois da visita registrada
    select vendedor_responsavel, visitou_loja_em into v_atual, v_visita
      from leads where concessionaria_id = v_loja and sender_id = p_sender;
    if found and v_atual is not null and v_visita is null then
      return json_build_object('ok', false, 'motivo', 'sem_visita');
    end if;
    v_motivo := case when p_status = 'nao_vendeu' and nullif(trim(coalesce(p_motivo, '')), '') is not null then
                  case when p_motivo in ('preco_condicao','financiamento_negado','avaliacao_troca','comprou_concorrente','vai_pensar','desistiu','outro')
                       then p_motivo else 'outro' end
                end;
    update leads set
        virou_cliente = case when p_status = 'vendeu' then true when venda_status = 'vendeu' then false else virou_cliente end,
        venda_status = p_status, venda_marcada_em = now(),
        venda_motivo_perda = v_motivo                                         -- [JORNADA_08_11] null quando 'vendeu'
     where concessionaria_id = v_loja and sender_id = p_sender and vendedor_responsavel is not null
     returning vendedor_responsavel into v_atual;
    if not found then return json_build_object('ok', false, 'motivo', 'sem_vendedor'); end if;
    update atendimentos_vendedor set convertido = (p_status = 'vendeu'), venda_status = p_status, venda_marcada_em = now()
     where id = (select id from atendimentos_vendedor where concessionaria_id = v_loja and lead_sender_id = p_sender order by atendido_em desc limit 1);
    insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, motivo, origem)
    values (v_loja, p_sender, p_status, v_atual, v_motivo, 'painel');
    return json_build_object('ok', true, 'vendedor', v_atual, 'status', p_status, 'motivo_perda', v_motivo);

  -- [JORNADA_08_11] desfaz a venda / não venda ("corrigir")
  elsif p_acao = 'desfazer_venda' then
    if coalesce(p_sender, '') = '' then return json_build_object('ok', false, 'motivo', 'dados'); end if;
    update leads set
        virou_cliente = case when venda_status = 'vendeu' then false else virou_cliente end,
        venda_status = null, venda_marcada_em = null, venda_motivo_perda = null
     where concessionaria_id = v_loja and sender_id = p_sender and vendedor_responsavel is not null
     returning vendedor_responsavel into v_atual;
    if not found then return json_build_object('ok', false, 'motivo', 'sem_vendedor'); end if;
    update atendimentos_vendedor set convertido = null, venda_status = null, venda_marcada_em = null
     where id = (select id from atendimentos_vendedor where concessionaria_id = v_loja and lead_sender_id = p_sender order by atendido_em desc limit 1);
    insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
    values (v_loja, p_sender, 'desfez_venda', v_atual, 'painel');
    return json_build_object('ok', true, 'vendedor', v_atual);

  elsif p_acao = 'relatorio' then
    v_mes := coalesce(nullif(p_mes, ''), to_char(now() at time zone 'America/Recife', 'YYYY-MM'));
    if v_mes !~ '^\d{4}-(0[1-9]|1[0-2])$' then return json_build_object('ok', false, 'motivo', 'dados'); end if;
    v_ini := (v_mes || '-01')::timestamp at time zone 'America/Recife';
    v_fim := ((v_mes || '-01')::timestamp + interval '1 month') at time zone 'America/Recife';
    with base as (
      select a.vendedor, a.canal, a.lead_nome, a.lead_telefone, a.lead_sender_id, a.atendido_em,
             case when a.venda_status is not null then a.venda_status when a.convertido is true then 'vendeu' when a.convertido is false then 'nao_vendeu' end as situacao,
             (a.visitou_loja_em is not null) as visitou,               -- [JORNADA_08_11]
             ld.venda_motivo_perda as motivo                           -- [JORNADA_08_11]
        from atendimentos_vendedor a
        left join leads ld on ld.concessionaria_id = a.concessionaria_id and ld.sender_id = a.lead_sender_id
       where a.concessionaria_id = v_loja and a.atendido_em >= v_ini and a.atendido_em < v_fim
    ), nomes as (
      select vendedor from base union select jsonb_array_elements_text(v_painel)
    ), linhas as (
      select n.vendedor, count(b.*) as assumidos,
             count(b.*) filter (where b.situacao = 'vendeu') as vendas,
             count(b.*) filter (where b.situacao = 'nao_vendeu') as nao_vendeu,
             count(b.*) filter (where b.situacao is null and b.atendido_em is not null) as aguardando,
             count(b.*) filter (where b.visitou) as visitas,           -- [JORNADA_08_11]
             coalesce(json_agg(json_build_object('nome', b.lead_nome, 'telefone', b.lead_telefone, 'sender_id', b.lead_sender_id,
                        'canal', b.canal, 'em', b.atendido_em, 'situacao', b.situacao,
                        'visitou', coalesce(b.visitou, false), 'motivo', b.motivo) order by b.atendido_em desc)
                      filter (where b.atendido_em is not null), '[]'::json) as leads
        from nomes n left join base b on lower(b.vendedor) = lower(n.vendedor) group by n.vendedor
    )
    select json_build_object('ok', true, 'mes', v_mes,
             'vendedores', coalesce(json_agg(l order by l.vendas desc, l.assumidos desc, l.vendedor), '[]'::json)) into v_res from linhas l;
    return v_res;
  end if;
  return json_build_object('ok', false, 'motivo', 'acao');
end;
$function$;

-- mesmas permissões de antes (ver pré-checagem no topo)
revoke all on function public.ian_vendedor_acao(uuid, text, text, text, text, text, text) from public;
grant execute on function public.ian_vendedor_acao(uuid, text, text, text, text, text, text) to postgres, anon, authenticated, service_role;

commit;


-- ----------------------------------------------------------------------------
-- 1.5 Gatilho: visita automática por check-in presencial e por test drive "compareceu"
--     Só age na CHEGADA do lead presencial e na TRANSIÇÃO do test drive para
--     'compareceu'. Updates comuns (o n8n faz upsert a cada mensagem) não
--     mexem na visita — então um "desfazer visita" não é revertido sozinho.
-- ----------------------------------------------------------------------------
create or replace function public.ian_leads_jornada_auto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.canal = 'presencial' and new.visitou_loja_em is null then
      -- upsert (INSERT ... ON CONFLICT) de um lead que já existe também passa por aqui:
      -- nesse caso não é uma chegada nova, então não mexe nem registra evento.
      if not exists (select 1 from leads where concessionaria_id is not distinct from new.concessionaria_id and sender_id = new.sender_id) then
        new.visitou_loja_em := coalesce(new.atendimento_em, new.criado_em, now());
        new.visita_origem   := 'checkin';
        new.visita_registrada_por := coalesce(new.visita_registrada_por, new.checkin_vendedor);
        insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
        values (new.concessionaria_id, new.sender_id, 'visitou', new.checkin_vendedor, 'checkin');
      end if;
    end if;
  elsif tg_op = 'UPDATE' then
    if new.test_drive_status = 'compareceu' and old.test_drive_status is distinct from 'compareceu'
       and new.visitou_loja_em is null then
      new.visitou_loja_em := now();
      new.visita_origem   := 'test_drive';
      new.visita_registrada_por := coalesce(new.visita_registrada_por, new.test_drive_atualizado_por, new.vendedor_responsavel);
      insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
      values (new.concessionaria_id, new.sender_id, 'visitou', new.vendedor_responsavel, 'test_drive');
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists ian_leads_jornada_auto_trg on public.leads;
create trigger ian_leads_jornada_auto_trg
  before insert or update on public.leads
  for each row execute function public.ian_leads_jornada_auto();


-- ----------------------------------------------------------------------------
-- 1.6 Backfill (uma vez; rodar de novo não duplica nada)
-- ----------------------------------------------------------------------------
with alvo as (
  update public.leads
     set visitou_loja_em = coalesce(atendimento_em, criado_em, now()),
         visita_origem   = 'checkin',
         visita_registrada_por = checkin_vendedor
   where canal = 'presencial' and visitou_loja_em is null
  returning concessionaria_id, sender_id, checkin_vendedor
)
insert into public.leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
select concessionaria_id, sender_id, 'visitou', checkin_vendedor, 'backfill' from alvo;

with alvo as (
  update public.leads
     set visitou_loja_em = coalesce((test_drive_data + time '12:00') at time zone 'America/Recife', atualizado_em, now()),
         visita_origem   = 'test_drive',
         visita_registrada_por = coalesce(test_drive_atualizado_por, vendedor_responsavel)
   where test_drive_status = 'compareceu' and visitou_loja_em is null
  returning concessionaria_id, sender_id, vendedor_responsavel
)
insert into public.leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
select concessionaria_id, sender_id, 'visitou', vendedor_responsavel, 'backfill' from alvo;


-- ----------------------------------------------------------------------------
-- 1.7 View para insights futuros (tempo entre as etapas, em horas)
-- ----------------------------------------------------------------------------
create or replace view public.v_jornada_leads as
select l.concessionaria_id, l.sender_id, l.nome, l.canal, l.setor, l.condicao_veiculo,
       l.criado_em, l.transferido_em,
       l.vendedor_responsavel, l.vendedor_assumiu_em,
       l.visitou_loja_em, l.visita_origem,
       l.venda_status, l.venda_marcada_em, l.venda_motivo_perda,
       round((extract(epoch from (l.vendedor_assumiu_em - l.criado_em))         / 3600)::numeric, 1) as horas_criado_ate_assumiu,
       round((extract(epoch from (l.visitou_loja_em     - l.vendedor_assumiu_em)) / 3600)::numeric, 1) as horas_assumiu_ate_visitou,
       round((extract(epoch from (l.venda_marcada_em    - l.visitou_loja_em))     / 3600)::numeric, 1) as horas_visitou_ate_venda
  from public.leads l;
-- a view não fica exposta na API pública (só leitura interna / SQL Editor)
revoke all on public.v_jornada_leads from anon, authenticated;


-- ----------------------------------------------------------------------------
-- 1.8 Verificação — rode e confira
-- ----------------------------------------------------------------------------
-- colunas novas (esperado: 5 linhas)
select table_name, column_name from information_schema.columns
 where table_schema = 'public'
   and ((table_name = 'leads' and column_name in ('visitou_loja_em','visita_registrada_por','visita_origem','venda_motivo_perda'))
     or (table_name = 'atendimentos_vendedor' and column_name = 'visitou_loja_em'));

-- função recriada com 7 parâmetros (esperado: 1 linha terminando em "text,text,text,text,text,text)")
select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'ian_vendedor_acao';

-- permissões (esperado: anon, authenticated, postgres, service_role)
select grantee, privilege_type from information_schema.routine_privileges
 where routine_schema = 'public' and routine_name = 'ian_vendedor_acao' order by grantee;

-- gatilho ativo (esperado: ian_leads_jornada_auto_trg, tgenabled = 'O')
select tgname, tgenabled from pg_trigger where tgrelid = 'public.leads'::regclass and tgname = 'ian_leads_jornada_auto_trg';

-- backfill (em 08/11 havia 2 leads presenciais e 0 test drives "compareceu")
select visita_origem, count(*) from public.leads where visitou_loja_em is not null group by visita_origem;
select evento, origem, count(*) from public.leads_jornada_eventos group by evento, origem order by 1, 2;
