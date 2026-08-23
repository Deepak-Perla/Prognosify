import { useState, type CSSProperties } from 'react';
import SideNav from '../../components/SideNav';
import { Chip, Pressable, pressableReset } from '../../components/ui';
import { hiChip, medChip, lowChip } from '../../data/mock';
import { useAsync } from '../../lib/useAsync';
import { useAuth } from '../../lib/auth';
import {
  balanceMinor,
  getInvoices,
  PAYMENT_METHODS,
  recordPayment,
  updateInvoice,
  paidMinor,
  type InvoiceRow,
} from '../../lib/api';
import { money, todayKey, dayBounds } from '../../lib/format';

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

const TAB_PREFIXES: Record<Bucket, string> = {
  pending: 'Pending',
  denied: 'Denied claims',
  paid: 'Paid this week',
};

type Editor =
  | { kind: 'collect'; invoiceId: string; amount: string; method: string }
  | { kind: 'auth'; invoiceId: string; ref: string };

const fieldStyle: CSSProperties = {
  border: '1px solid #DDE3EB',
  borderRadius: 6,
  padding: '7px 10px',
  fontSize: 12.5,
  color: '#0F1C2E',
};

export default function Billing() {
  const [tab, setTab] = useState<Bucket>('pending');
  const { membership } = useAuth();
  const { data, error, loading, reload } = useAsync(() => getInvoices(), []);

  const [editor, setEditor] = useState<Editor | null>(null);
  const [detailsId, setDetailsId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [flash, setFlash] = useState<string | null>(null);

  const invoices = data ?? [];
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
    .flatMap((inv) => inv.payments.map((p) => ({ ...p, amount: Number(p.amount_minor) })))
    .filter(
      (p) => p.received_at >= todayBounds.startISO && p.received_at < todayBounds.endISO,
    );
  const collectedSum = collectedToday.reduce((sum, p) => sum + p.amount, 0);

  const counts = (b: Bucket): number => invoices.filter((inv) => bucketOf(inv) === b).length;
  const denialNote = denialRisk.find((inv) => inv.denial_risk_note)?.denial_risk_note ?? null;

  const flashFor = (msg: string) => {
    setFlash(msg);
    window.setTimeout(() => setFlash(null), 4000);
  };

  const collect = async (invoiceId: string, amountMinor: number, method: string) => {
    if (!membership) return;
    setBusy(true);
    setActionError(null);
    try {
      await recordPayment({
        invoiceId,
        organizationId: membership.organizationId,
        amountMinor,
        method: method as never,
        receivedByMemberId: membership.memberId,
      });
      const inv = invoices.find((i) => i.id === invoiceId);
      if (inv && balanceMinor(inv) - amountMinor <= 0 && inv.status !== 'paid') {
        await updateInvoice(invoiceId, { status: 'paid' });
      }
      setEditor(null);
      reload();
      flashFor(`Payment recorded — ${money(amountMinor, inv?.currency)} by ${method}.`);
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Could not record the payment.');
    } finally {
      setBusy(false);
    }
  };

  const clearAuthHold = async (invoiceId: string, ref: string) => {
    setBusy(true);
    setActionError(null);
    try {
      await updateInvoice(invoiceId, { prior_auth_ref: ref.trim(), status: 'covered' });
      setEditor(null);
      reload();
      flashFor('Prior-auth reference saved — claim moved to Covered.');
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Could not save the reference.');
    } finally {
      setBusy(false);
    }
  };

  const copyPhone = async (inv: InvoiceRow) => {
    const phone = inv.patient?.phone ?? '';
    if (!phone) {
      flashFor('No phone number on file for this patient.');
      return;
    }
    try {
      await navigator.clipboard.writeText(phone);
      flashFor(`${phone} copied — send your reminder from your own phone.`);
    } catch {
      flashFor(phone);
    }
  };

  const actionFor = (inv: InvoiceRow): string =>
    inv.status === 'auth_missing'
      ? 'Request auth'
      : inv.status === 'paid'
        ? 'Details'
        : inv.status === 'overdue'
          ? 'Send reminder'
          : 'Collect';

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="billing" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Billing &amp; insurance</h1>
          <div style={{ display: 'flex', gap: 8 }}>
            {(Object.keys(TAB_PREFIXES) as Bucket[]).map((b) => (
              <Chip key={b} selected={tab === b} onClick={() => setTab(b)} ariaLabel={`Show ${TAB_PREFIXES[b]} (${counts(b)})`}>
                {`${TAB_PREFIXES[b]} (${counts(b)})`}
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
          {loading && (
            <div role="status" className="ui-spinner" aria-label="Loading invoices" />
          )}
          {!loading && !error && (
            <>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 16 }}>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Outstanding balance</div>
                  <div style={{ fontSize: 26, fontWeight: 700 }}>{money(outstanding)}</div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>
                    {openInvoices.length} invoices{oldestDays > 0 ? ` · oldest ${oldestDays} days` : ''}
                  </div>
                </div>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Claims at denial risk (AI)</div>
                  <div style={{ fontSize: 26, fontWeight: 700, color: denialRisk.length > 0 ? '#B54708' : undefined }}>
                    {denialRisk.length}
                  </div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>Flagged on the invoice record itself</div>
                </div>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Collected today</div>
                  <div style={{ fontSize: 26, fontWeight: 700, color: collectedSum > 0 ? '#116B3F' : undefined }}>
                    {money(collectedSum)}
                  </div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>{collectedToday.length} payments</div>
                </div>
              </div>
              {flash && (
                <div role="status" style={{ background: '#F0F7F2', border: '1px solid #CFE6D8', borderRadius: 10, padding: '10px 16px', fontSize: 13, color: '#116B3F' }}>
                  {flash}
                </div>
              )}
              {actionError && (
                <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '10px 16px', fontSize: 13, color: '#B42318' }}>
                  {actionError}
                </div>
              )}
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, overflow: 'hidden' }}>
                <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1.4fr 1fr 1.2fr 1.4fr', padding: '12px 20px', borderBottom: '1px solid #DDE3EB', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
                  <div>Patient</div><div>Invoice</div><div>Service</div><div>Amount</div><div>Status</div><div></div>
                </div>
                {visible.map((inv, i) => {
                  const chipInfo = statusChip(inv);
                  const amount = tab === 'paid' ? money(paidMinor(inv), inv.currency) : money(balanceMinor(inv), inv.currency);
                  const action = actionFor(inv);
                  const isEditorTarget = editor?.invoiceId === inv.id;
                  const expanded = detailsId === inv.id;
                  const buttonLook: CSSProperties = tab === 'pending'
                    ? { background: '#1D4ED8', color: '#fff' }
                    : { border: '1px solid #DDE3EB', color: '#1D4ED8' };
                  return (
                    <div
                      key={inv.id}
                      style={{
                        borderBottom: i < visible.length - 1 || expanded ? '1px solid #EEF2F6' : undefined,
                        fontSize: 13.5,
                      }}
                    >
                      <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1.4fr 1fr 1.2fr 1.4fr', padding: '14px 20px', alignItems: 'center' }}>
                        <div style={{ fontWeight: 600 }}>
                          {inv.patient ? `${inv.patient.first_name} ${inv.patient.last_name}` : '—'}
                          <span style={{ color: '#8A97A8', fontWeight: 500, fontSize: 11.5 }}> · {inv.patient?.mrn}</span>
                        </div>
                        <div style={{ color: '#5B6B7F' }}>{inv.number}</div>
                        <div style={{ color: '#5B6B7F' }}>
                          {inv.lines[0]?.description ?? '—'}
                          {inv.lines.length > 1 ? ` (+${inv.lines.length - 1} more)` : ''}
                        </div>
                        <div style={{ fontWeight: 600 }}>{amount}</div>
                        <div><span style={chipInfo.style}>{chipInfo.text}</span></div>
                        <div style={{ display: 'flex', gap: 6, justifyContent: 'flex-end', alignItems: 'center' }}>
                          <Pressable
                            onClick={() => { setDetailsId(expanded ? null : inv.id); setEditor(null); }}
                            ariaExpanded={expanded}
                            title="Show the bill's lines and payments"
                            style={{ border: '1px solid #DDE3EB', color: '#5B6B7F', borderRadius: 6, padding: '6px 10px', fontSize: 12, cursor: 'pointer' }}
                          >
                            {expanded ? 'Hide' : 'Details'}
                          </Pressable>
                          {inv.status === 'overdue' ? (
                            <Pressable
                              onClick={() => void copyPhone(inv)}
                              title="Copies the patient's phone number so you can call or message them."
                              style={{ ...pressableReset, ...buttonLook, borderRadius: 6, padding: '6px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}
                            >
                              Call patient
                            </Pressable>
                          ) : inv.status === 'auth_missing' ? (
                            <Pressable
                              onClick={() => setEditor(isEditorTarget && editor.kind === 'auth' ? null : { kind: 'auth', invoiceId: inv.id, ref: '' })}
                              ariaExpanded={isEditorTarget}
                              title="Paste the payer's prior-authorisation reference to clear the hold."
                              style={{ ...pressableReset, ...buttonLook, borderRadius: 6, padding: '6px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}
                            >
                              Enter auth
                            </Pressable>
                          ) : inv.status !== 'paid' ? (
                            <Pressable
                              onClick={() => setEditor(isEditorTarget && editor.kind === 'collect' ? null : { kind: 'collect', invoiceId: inv.id, amount: String(balanceMinor(inv) / 100), method: PAYMENT_METHODS[0] })}
                              ariaExpanded={isEditorTarget}
                              title="Records a real payment against this invoice."
                              style={{ ...pressableReset, ...buttonLook, borderRadius: 6, padding: '6px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}
                            >
                              Collect
                            </Pressable>
                          ) : null}
                        </div>
                      </div>
                      {editor && editor.invoiceId === inv.id && (
                        <div role="group" aria-label={`${action} — ${inv.number}`} style={{ margin: '0 20px 14px', border: '1px solid #C9D8FA', background: '#F8FAFF', borderRadius: 10, padding: 14, display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
                          {editor.kind === 'collect' ? (
                            <>
                              <label style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                                Amount (₹)
                                <input
                                  type="number"
                                  min={0}
                                  value={editor.amount}
                                  onChange={(e) => setEditor({ ...editor, amount: e.target.value })}
                                  style={{ ...fieldStyle, marginLeft: 6, width: 120 }}
                                />
                              </label>
                              <label style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                                Method
                                <select
                                  value={editor.method}
                                  onChange={(e) => setEditor({ ...editor, method: e.target.value })}
                                  style={{ ...fieldStyle, marginLeft: 6 }}
                                >
                                  {PAYMENT_METHODS.map((m) => (
                                    <option key={m} value={m}>{m.toUpperCase()}</option>
                                  ))}
                                </select>
                              </label>
                              <Pressable
                                onClick={() => void collect(inv.id, Math.round(parseFloat(editor.amount || '0') * 100), editor.method)}
                                disabled={busy}
                                title="Writes the payment and settles the invoice when fully covered."
                                style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 6, padding: '8px 16px', fontSize: 12.5, fontWeight: 600, cursor: busy ? 'default' : 'pointer', opacity: busy ? 0.6 : 1 }}
                              >
                                {busy ? 'Saving…' : 'Record payment'}
                              </Pressable>
                            </>
                          ) : (
                            <>
                              <label style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                                Prior-auth reference
                                <input
                                  type="text"
                                  value={editor.ref}
                                  onChange={(e) => setEditor({ ...editor, ref: e.target.value })}
                                  placeholder="e.g. PA-2026-118842"
                                  style={{ ...fieldStyle, marginLeft: 6, width: 200 }}
                                />
                              </label>
                              <Pressable
                                onClick={() => void clearAuthHold(inv.id, editor.ref)}
                                disabled={busy || !editor.ref.trim()}
                                title="Clears the auth_missing hold; the claim moves to Covered."
                                style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 6, padding: '8px 16px', fontSize: 12.5, fontWeight: 600, cursor: busy ? 'default' : 'pointer', opacity: busy || !editor.ref.trim() ? 0.55 : 1 }}
                              >
                                {busy ? 'Saving…' : 'Save & cover'}
                              </Pressable>
                            </>
                          )}
                        </div>
                      )}
                      {expanded && (
                        <div style={{ margin: '0 20px 14px', background: '#F8F9FB', borderRadius: 10, padding: 14, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, fontSize: 12.5 }}>
                          <div>
                            <div style={{ fontWeight: 600, marginBottom: 6 }}>Lines</div>
                            {inv.lines.map((l) => (
                              <div key={l.description} style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}>
                                <span>{l.description}</span><span>{money(Number(l.amount_minor), inv.currency)}</span>
                              </div>
                            ))}
                            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', borderTop: '1px solid #E5E9F0', marginTop: 4 }}>
                              <span>Total</span><span>{money(Number(inv.total_minor), inv.currency)}</span>
                            </div>
                          </div>
                          <div>
                            <div style={{ fontWeight: 600, marginBottom: 6 }}>Payments</div>
                            {inv.payments.length === 0 && <div style={{ color: '#8A97A8' }}>None yet.</div>}
                            {inv.payments.map((pay, k) => (
                              <div key={k} style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}>
                                <span>{new Date(pay.received_at).toLocaleString('en-IN')}</span>
                                <span>{money(Number(pay.amount_minor), inv.currency)}</span>
                              </div>
                            ))}
                            {inv.due_at && (
                              <div style={{ marginTop: 8, color: '#8A97A8' }}>
                                Due {new Date(inv.due_at).toLocaleDateString('en-IN')}
                              </div>
                            )}
                          </div>
                        </div>
                      )}
                    </div>
                  );
                })}
                {visible.length === 0 && (
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
            </>
          )}
        </div>
      </div>
    </div>
  );
}
