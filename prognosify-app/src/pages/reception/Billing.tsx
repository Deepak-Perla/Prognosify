import { useMemo, useState, type CSSProperties } from 'react';
import SideNav from '../../components/SideNav';
import { Chip } from '../../components/ui';
import { hiChip, medChip, lowChip } from '../../data/mock';
import { useAsync } from '../../lib/useAsync';
import {
  balanceMinor,
  getInvoices,
  paidMinor,
  type InvoiceRow,
} from '../../lib/api';
import { dayBounds, money, todayKey } from '../../lib/format';

type Bucket = 'pending' | 'denied' | 'paid';

const bucketOf = (inv: InvoiceRow): Bucket =>
  inv.status === 'auth_missing' ? 'denied' : inv.status === 'paid' ? 'paid' : 'pending';

const statusChip = (inv: InvoiceRow): { text: string; style: CSSProperties } => {
  switch (inv.status) {
    case 'auth_missing':
      return { text: 'Auth missing', style: hiChip };
    case 'overdue':
      return {
        text: inv.due_at
          ? `${Math.max(1, Math.floor((Date.now() - new Date(inv.due_at).getTime()) / 86400000))} days overdue`
          : 'Overdue',
        style: medChip,
      };
    case 'covered':
      return { text: 'Covered', style: lowChip };
    case 'written_off':
    case 'void':
      return { text: inv.status === 'void' ? 'Voided' : 'Written off', style: lowChip };
    default:
      return { text: 'Copay due', style: medChip };
  }
};

/** Row actions need a payments/payer integration that is not built yet; they stay honest. */
const cannot = (action: string): string => {
  switch (action) {
    case 'Collect':
      return 'Recording a payment needs the payments flow — not built in this release.';
    case 'Request auth':
      return 'Prior-authorisation requests need a payer connection — none exists yet.';
    case 'Details':
      return 'There is no invoice detail view in this release.';
    case 'Send reminder':
      return 'No messaging backend — no reminder can be sent yet.';
    default:
      return 'Not available in this release.';
  }
};

const TAB_PREFIXES: Record<Bucket, string> = { pending: 'Pending', denied: 'Denied claims', paid: 'Paid this week' };

export default function Billing() {
  const [tab, setTab] = useState<Bucket>('pending');
  const { data, error, loading } = useAsync(() => getInvoices(), []);

  const invoices = useMemo(() => data ?? [], [data]);
  const visible = invoices.filter((inv) => bucketOf(inv) === tab);

  const openInvoices = invoices.filter(
    (inv) => ['copay_due', 'overdue', 'auth_missing'].includes(inv.status) && balanceMinor(inv) > 0,
  );
  const outstanding = openInvoices.reduce((sum, inv) => sum + balanceMinor(inv), 0);
  const oldestDays = openInvoices.reduce((max, inv) => {
    if (!inv.due_at) return max;
    const days = Math.floor((Date.now() - new Date(inv.due_at).getTime()) / 86400000);
    return Math.max(max, days);
  }, 0);
  const denialRisk = invoices.filter((inv) => inv.denial_risk_flag && inv.status !== 'paid');

  const todayBounds = dayBounds(todayKey());
  const collectedToday = invoices
    .flatMap((inv) =>
      inv.payments.map((p) => ({
        ...p,
        amount: Number(p.amount_minor),
        today:
          p.received_at >= todayBounds.startISO && p.received_at < todayBounds.endISO,
      })),
    )
    .filter((p) => p.today);
  const collectedSum = collectedToday.reduce((sum, p) => sum + p.amount, 0);

  const counts = (b: Bucket): number => invoices.filter((inv) => bucketOf(inv) === b).length;

  const denialNote = denialRisk.find((inv) => inv.denial_risk_note)?.denial_risk_note ?? null;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="billing" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Billing &amp; insurance</h1>
          <div style={{ display: 'flex', gap: 8 }}>
            {(Object.keys(TAB_PREFIXES) as Bucket[]).map((b) => (
              <Chip
                key={b}
                selected={tab === b}
                onClick={() => setTab(b)}
                ariaLabel={`Show ${TAB_PREFIXES[b]}${b !== 'paid' ? ` (${counts(b)})` : ''}`}
              >
                {b === 'paid'
                  ? `${TAB_PREFIXES[b]} (${counts('paid')})`
                  : `${TAB_PREFIXES[b]} (${counts(b)})`}
              </Chip>
            ))}
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 16px', fontSize: 13, color: '#B42318' }}>
              Could not load invoices: {error}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 16 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Outstanding balance</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : money(outstanding)}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>
                {openInvoices.length} invoices{oldestDays > 0 ? ` · oldest ${oldestDays} days` : ''}
              </div>
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Claims at denial risk (AI)</div>
              <div style={{ fontSize: 26, fontWeight: 700, color: denialRisk.length > 0 ? '#B54708' : undefined }}>
                {loading ? '…' : denialRisk.length}
              </div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>Flagged on the invoice record itself</div>
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Collected today</div>
              <div style={{ fontSize: 26, fontWeight: 700, color: collectedSum > 0 ? '#116B3F' : undefined }}>
                {loading ? '…' : money(collectedSum)}
              </div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>{collectedToday.length} payments</div>
            </div>
          </div>
          <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, overflow: 'hidden' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1.4fr 1fr 1.2fr 1fr', padding: '12px 20px', borderBottom: '1px solid #DDE3EB', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
              <div>Patient</div><div>Invoice</div><div>Service</div><div>Amount</div><div>Status</div><div></div>
            </div>
            {!loading && !error && visible.map((inv, i) => {
              const chipInfo = statusChip(inv);
              const amount =
                tab === 'paid' ? money(paidMinor(inv), inv.currency) : money(balanceMinor(inv), inv.currency);
              // The spec paints these as inline <span>s; role="button" + tabindex keeps them
              // reachable without turning them into blocks.
              const actionLook: CSSProperties =
                tab === 'pending'
                  ? { background: '#1D4ED8', color: '#fff', borderRadius: 6, padding: '6px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' }
                  : { border: '1px solid #DDE3EB', color: '#1D4ED8', borderRadius: 6, padding: '6px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' };
              const action =
                inv.status === 'auth_missing' ? 'Request auth' : inv.status === 'paid' ? 'Details' : inv.status === 'overdue' ? 'Send reminder' : 'Collect';
              const service = inv.lines[0]?.description ?? '—';
              return (
                <div key={inv.id} style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1.4fr 1fr 1.2fr 1fr', padding: '14px 20px', borderBottom: i < visible.length - 1 ? '1px solid #EEF2F6' : undefined, fontSize: 13.5, alignItems: 'center' }}>
                  <div style={{ fontWeight: 600 }}>
                    {inv.patient ? `${inv.patient.first_name} ${inv.patient.last_name}` : '—'}
                    <span style={{ color: '#8A97A8', fontWeight: 500, fontSize: 11.5 }}> · {inv.patient?.mrn}</span>
                  </div>
                  <div style={{ color: '#5B6B7F' }}>{inv.number}</div>
                  <div style={{ color: '#5B6B7F' }}>
                    {service}
                    {inv.lines.length > 1 ? ` (+${inv.lines.length - 1} more)` : ''}
                  </div>
                  <div style={{ fontWeight: 600 }}>{amount}</div>
                  <div><span style={chipInfo.style}>{chipInfo.text}</span></div>
                  <div style={{ textAlign: 'right' }}>
                    <span role="button" tabIndex={0} aria-disabled="true" aria-label={`${action} — invoice ${inv.number}`} title={cannot(action)} style={actionLook}>
                      {action}
                    </span>
                  </div>
                </div>
              );
            })}
            {!loading && !error && visible.length === 0 && (
              <div role="status" style={{ padding: '14px 20px', fontSize: 13.5, color: '#5B6B7F' }}>No invoices in this view.</div>
            )}
          </div>
          {denialRisk.length > 0 && (
            <div style={{ background: '#F8F9FB', border: '1px dashed #C6CFDA', borderRadius: 12, padding: '14px 20px', fontSize: 13, color: '#5B6B7F' }}>
              AI flag: {denialRisk[0].patient?.first_name} {denialRisk[0].patient?.last_name} ({denialRisk[0].number})
              {denialNote ? ` — ${denialNote}` : ' is flagged for likely denial.'}
              {denialRisk.length > 1 ? ` ${denialRisk.length - 1} more flagged.` : ''}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
