# Especificação — endpoint `/rui-monitor-gastos-real` (n8n)

Este documento é pra você (ou quem mexe no workflow do n8n) trocar a consulta que hoje
soma `ai_usage_log` + `twilio_usage_log` por uma que lê **só** as views/tabela abaixo,
que já existem no Supabase (projeto GWM):

- `v_custo_ia_mensal`
- `v_custo_ia_por_agente_mes`
- `v_custo_ia_diario`
- `v_custo_ia_por_lead_mes_atual`
- `v_custo_fixo_atual`
- `v_custo_twilio_mensal`
- `custos_fixos` (tabela, não view)

O front-end (`rui-monitor-dashboard.html`, aba **Gastos**) já foi atualizado pra
consumir o formato de resposta descrito aqui. Nada nele soma, estima ou arredonda
custo — ele só formata o que o endpoint devolver. Se um bloco vier com
`disponivel: false` (ou ausente), a tela mostra **"Dado indisponível"** — nunca zero.

## Regra de multi-tenant (obrigatória)

**Todas** as consultas abaixo devem filtrar por `concessionaria_slug`. O front-end
não manda esse slug — ele só manda a chave de acesso (header `x-adtsa-secret`).
É responsabilidade do workflow resolver **qual concessionária pertence a essa chave**
(ex.: uma tabela de mapeamento secret → slug) e usar esse slug em todo `WHERE`
das consultas abaixo. Nunca somar/misturar dado de outra concessionária.

Hoje o slug em uso é `adtsa` (GWM-PE / ADTSA).

## Mês de referência

Todas as consultas de "mês" (`v_custo_ia_mensal`, `v_custo_ia_por_agente_mes`,
`v_custo_ia_diario`, `v_custo_twilio_mensal`) devem usar o **mês corrente**
(`date_trunc('month', now())`), não um mês fixo.

## Formato de resposta esperado (JSON) — já implementado no front-end

```json
{
  "ia": {
    "disponivel": true,
    "chamadas": 1234,
    "leads_distintos": 210,
    "tokens_input_total": 456000,
    "tokens_output_total": 98000,
    "custo_usd": 12.3456,
    "custo_por_lead_usd": 0.0587,
    "por_agente": [
      { "agente": "rui", "custo_usd": 9.10 }
    ],
    "por_dia": [
      { "dia": "2026-08-01", "custo_usd": 0.41 }
    ],
    "por_concessionaria": [
      { "concessionaria_slug": "adtsa", "custo_usd": 12.3456 }
    ]
  },

  "whatsapp": {
    "disponivel": true,
    "custo_total": 45.20,
    "moeda": "BRL"
  },

  "custo_fixo": {
    "disponivel": true,
    "valor_brl_mes": 850.00,
    "itens": [
      { "item": "easypanel", "valor_mensal": 120.00, "moeda": "BRL", "vigencia_inicio": "2026-01-01", "vigencia_fim": null }
    ]
  }
}
```

### De onde vem cada bloco

| Campo na resposta | Fonte (Supabase) | Observação |
|---|---|---|
| `ia.chamadas`, `ia.leads_distintos`, `ia.tokens_input_total`, `ia.tokens_output_total`, `ia.custo_usd` | `v_custo_ia_mensal` | 1 linha filtrada por mês atual + slug. Se não existir linha, mande `ia.disponivel = false` (e omita/`null` o resto). |
| `ia.custo_por_lead_usd` | `v_custo_ia_por_lead_mes_atual.custo_ia_usd_por_lead` | Slug atual. |
| `ia.por_agente` | `v_custo_ia_por_agente_mes` | Todas as linhas do mês atual + slug. `[]` se não houver. |
| `ia.por_dia` | `v_custo_ia_diario` | Todas as linhas do mês atual + slug. |
| `ia.por_concessionaria` | opcional — só se o painel algum dia comparar concessionárias; hoje sempre 1 item (a própria) ou pode vir `[]` | |
| `whatsapp.custo_total`, `whatsapp.moeda` | `v_custo_twilio_mensal.custo_twilio_total` | Mês atual + slug. `whatsapp.disponivel = false` quando não houver linha — **isso é esperado pra dias 18–24/08/2026**, já que a ingestão de `twilio_usage_log` só foi corrigida em 25/08. A view não tem coluna de moeda: preencha `moeda` fixo no workflow conforme a cobrança real da conta Twilio. |
| `custo_fixo.valor_brl_mes` | `v_custo_fixo_atual.custo_fixo_brl_mes` | Slug atual. |
| `custo_fixo.itens` | `custos_fixos` | Itens **vigentes hoje** do slug atual: `vigencia_inicio <= current_date AND (vigencia_fim IS NULL OR vigencia_fim >= current_date)`. |

### Importante: nunca inventar número

- Se uma consulta falhar ou vier vazia, mande o bloco com `disponivel: false` — não mande `0`.
- HTTP 200 mesmo com blocos indisponíveis é esperado (dado parcial é normal, principalmente pro
  WhatsApp nos dias 18–24/08). Só devolva erro HTTP (4xx/5xx) se a chave de acesso for inválida ou
  o servidor falhar de verdade — nunca pra "sem dado".

## Escrita de `custos_fixos` — já implementada, sem depender do n8n

O painel tem uma seção **"Editar custos fixos"** (aba Gastos) que gera o SQL pronto
(`UPDATE` de fechamento do item anterior + `INSERT` do novo) pra colar no SQL Editor
do Supabase — mesmo padrão de segurança já usado nas abas Configuração e Suporte.
Não é preciso criar nenhum endpoint novo no n8n pra isso; nenhuma chave de escrita
fica exposta no navegador.
