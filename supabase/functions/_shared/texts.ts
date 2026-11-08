// Тексты уведомлений pt-AO по типу (ТЗ раздел 9). Суммы - целые кванзы.

type Payload = Record<string, unknown>;
const kz = (n: unknown) => `${Number(n ?? 0).toLocaleString("pt-PT")} Kz`;

const texts: Record<string, (p: Payload) => { title: string; body: string }> = {
  payment_pending: (p) => ({ title: "Confirme o pagamento", body: `Confirme ${kz(p.amount_kz)} no Multicaixa Express em 15 minutos.` }),
  payment_failed: () => ({ title: "Pagamento não concluído", body: "O lugar foi libertado. Pode tentar de novo." }),
  booking_requested: (p) => ({ title: "Novo pedido pago", body: `${p.passenger_name ?? "Um passageiro"} pagou ${p.seats ?? 1} lugar(es). Responda em 24 h.` }),
  booking_confirmed: (p) => ({ title: "Lugar reservado", body: `${p.passenger_name ?? "Um passageiro"} reservou ${p.seats ?? 1} lugar(es). Pagamento confirmado.` }),
  booking_accepted: () => ({ title: "Reserva aceite", body: "O PIN e o telefone do condutor chegam 2 h antes da partida." }),
  booking_declined: (p) => ({ title: "Pedido não aceite", body: `${kz(p.refund_kz)} são devolvidos em 1 a 3 dias úteis.` }),
  booking_expired: (p) => ({ title: "Sem resposta do condutor", body: `${kz(p.refund_kz)} são devolvidos em 1 a 3 dias úteis.` }),
  booking_cancelled_by_passenger: () => ({ title: "Reserva cancelada", body: "O passageiro cancelou. O lugar voltou a estar livre." }),
  booking_cancelled_by_driver: (p) => ({ title: "Reserva cancelada pelo condutor", body: `Reembolso total de ${kz(p.refund_kz)}.` }),
  trip_cancelled: (p) => ({ title: "Viagem cancelada", body: p.refund_kz ? `Reembolso total de ${kz(p.refund_kz)}.` : "A viagem foi cancelada." }),
  refund_done: (p) => ({ title: "Reembolso efetuado", body: `${kz(p.refund_kz)} devolvidos.` }),
  new_message: (p) => ({ title: String(p.sender_name ?? "Nova mensagem"), body: String(p.preview ?? "") }),
  trip_reminder_24h: () => ({ title: "Viagem amanhã", body: "Confirme que vai viajar." }),
  trip_reminder_6h: () => ({ title: "Confirme a viagem", body: "Sem confirmação os passageiros podem cancelar gratuitamente." }),
  driver_unconfirmed: () => ({ title: "Condutor não confirmou", body: "Pode cancelar gratuitamente até à partida." }),
  pin_ready: (p) => ({ title: "O seu PIN", body: `PIN ${p.pin}. Telefone do condutor: ${p.driver_phone ?? ""}` }),
  trip_reminder_2h: () => ({ title: "Partida em 2 horas", body: "Veja os telefones dos passageiros na viagem." }),
  trip_completed_ask: () => ({ title: "Chegou bem?", body: "Confirme a viagem para o condutor receber o pagamento." }),
  payout_released: (p) => ({ title: "Saldo atualizado", body: `+${kz(p.amount_kz)} no seu saldo.` }),
  payout_requested: (p) => ({ title: "Pedido de levantamento", body: `${kz(p.amount_kz)} aguardam pagamento.` }),
  payout_paid: (p) => ({ title: "Levantamento pago", body: `${kz(p.amount_kz)} enviados.` }),
  payout_failed: (p) => ({ title: "Levantamento falhou", body: `${kz(p.amount_kz)} voltaram ao saldo. ${p.reason ?? ""}`.trim() }),
  verification_approved: () => ({ title: "Verificação aprovada", body: "Já tem o selo de condutor verificado." }),
  verification_rejected: (p) => ({ title: "Verificação recusada", body: String(p.reason ?? "") }),
  dispute_opened: () => ({ title: "Reclamação aberta", body: "A moderação vai analisar o chat e o PIN." }),
  dispute_resolved: (p) => ({ title: "Reclamação resolvida", body: `Decisão: ${p.outcome ?? ""}` }),
  booking_no_show: () => ({ title: "Marcado como ausente", body: "O condutor indicou que não apareceu. Reserva fechada sem reembolso." }),
  review_request: () => ({ title: "Como foi a viagem?", body: "Deixe a sua avaliação." }),
  reconciliation_alert: () => ({ title: "Alerta de conciliação", body: "Ledger e pagamentos não coincidem." }),
  refund_manual: (p) => ({ title: "Reembolso manual", body: `${kz(p.refund_kz)} falharam 3 vezes no gateway.` }),
};

export function textFor(type: string, payload: Payload): { title: string; body: string } {
  const f = texts[type];
  return f ? f(payload) : { title: "Boleia", body: type };
}
