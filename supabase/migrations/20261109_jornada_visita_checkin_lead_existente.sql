-- ============================================================================
-- [JORNADA_08_11] Correção: lead que já conversou pelo WhatsApp e depois faz
-- check-in na loja passa a ter a visita marcada no banco.
--
-- Por quê: o check-in grava com "upsert". Quando o lead já existe, o Postgres
-- transforma o INSERT num UPDATE, e o gatilho antigo só marcava visita em
-- INSERT de lead novo. Agora o UPDATE também marca quando o canal muda para
-- 'presencial'.
--
-- Seguro rodar mais de uma vez. Só troca a função do gatilho (o gatilho em si
-- continua o mesmo). Cole tudo no SQL Editor e execute.
-- ============================================================================

create or replace function public.ian_leads_jornada_auto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.canal = 'presencial' and new.visitou_loja_em is null then
      -- upsert de lead que já existe também passa por aqui; nesse caso quem
      -- marca a visita é o ramo UPDATE abaixo, então não faz nada aqui.
      if not exists (select 1 from leads where concessionaria_id is not distinct from new.concessionaria_id and sender_id = new.sender_id) then
        new.visitou_loja_em := coalesce(new.atendimento_em, new.criado_em, now());
        new.visita_origem   := 'checkin';
        new.visita_registrada_por := coalesce(new.visita_registrada_por, new.checkin_vendedor);
        insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
        values (new.concessionaria_id, new.sender_id, 'visitou', new.checkin_vendedor, 'checkin');
      end if;
    end if;
  elsif tg_op = 'UPDATE' then
    -- [NOVO 09/11] lead que já existia (ex.: veio do WhatsApp) e agora fez check-in
    if new.canal = 'presencial' and old.canal is distinct from 'presencial'
       and new.visitou_loja_em is null then
      new.visitou_loja_em := coalesce(new.atendimento_em, now());
      new.visita_origem   := 'checkin';
      new.visita_registrada_por := coalesce(new.visita_registrada_por, new.checkin_vendedor);
      insert into leads_jornada_eventos (concessionaria_id, sender_id, evento, vendedor, origem)
      values (new.concessionaria_id, new.sender_id, 'visitou', new.checkin_vendedor, 'checkin');
    -- test drive marcado como "compareceu" (igual antes)
    elsif new.test_drive_status = 'compareceu' and old.test_drive_status is distinct from 'compareceu'
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

-- Backfill: leads que hoje já estão como presencial e continuam sem visita
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

-- Verificação: deve voltar 0 (nenhum presencial sem visita)
select count(*) as presenciais_sem_visita from public.leads where canal = 'presencial' and visitou_loja_em is null;
