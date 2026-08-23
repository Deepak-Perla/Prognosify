import { useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import PortalNav from '../../components/PortalNav';
import { Busy, Pressable, TextField, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import { useAuth } from '../../lib/auth';
import {
  getCareTeamContacts,
  getPortalIdentity,
  getThread,
  sendPatientMessage,
  type MessageRow,
} from '../../lib/api';
import { timeLabel, dayKey, todayKey, shiftDay, shortDate } from '../../lib/format';

/** "9:02 AM" for today, "Yesterday", else the short date â€” the list's right column. */
function stamp(iso: string): string {
  const d = dayKey(iso);
  if (d === todayKey()) return timeLabel(iso);
  if (d === shiftDay(todayKey(), -1)) return `Yesterday ${timeLabel(iso)}`;
  return shortDate(iso);
}

const bubbleBase: CSSProperties = { maxWidth: 380, padding: '11px 14px', fontSize: 13.5, lineHeight: 1.5 };
const themBubble: CSSProperties = { ...bubbleBase, alignSelf: 'flex-start', background: '#F4F6F9', borderRadius: '12px 12px 12px 4px' };
const meBubble: CSSProperties = { ...bubbleBase, alignSelf: 'flex-end', background: '#1D4ED8', color: '#fff', borderRadius: '12px 12px 4px 12px' };

export default function PatientMessages() {
  const { membership } = useAuth();
  const [activeContactId, setActiveContactId] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const threadRef = useRef<HTMLDivElement | null>(null);

  // Identity resolves who is signed in; contacts are their real care team.
  const meState = useAsync(() => getPortalIdentity(), []);
  const contactsState = useAsync(() => getCareTeamContacts(), []);

  const patientId = meState.data?.patient_id ?? null;
  const contacts = contactsState.data ?? [];
  const contact =
    contacts.find((c) => c.member_id === activeContactId) ?? contacts[0] ?? null;

  // The thread refetches when it opens, when a message is sent, and every 20 seconds
  // afterwards â€” replies arrive without a page refresh.
  const threadState = useAsync(async () => {
    if (!patientId) return [] as MessageRow[];
    return getThread(patientId);
  }, [patientId]);

  useEffect(() => {
    if (!patientId || !contact) return;
    const timer = window.setInterval(() => threadState.reload(), 20000);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- poll only while a thread is open
  }, [patientId, contact?.member_id]);

  useEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [threadState.data?.length, activeContactId]);

  const send = async () => {
    if (!patientId || !membership || !draft.trim()) return;
    setSending(true);
    setSendError(null);
    try {
      await sendPatientMessage(patientId, membership.organizationId, draft);
      setDraft('');
      threadState.reload();
    } catch (err) {
      setSendError(err instanceof Error ? err.message : 'Could not send your message.');
    } finally {
      setSending(false);
    }
  };

  const loading = meState.loading || contactsState.loading;
  const error = meState.error ?? contactsState.error ?? threadState.error;
  const messages = threadState.data ?? [];

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Messages" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'hidden' }}>
        <div style={{ width: 960, display: 'flex', gap: 16, padding: '28px 0', height: '100%', boxSizing: 'border-box' }}>
          <div style={{ width: 300, flexShrink: 0, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
            <h1 style={{ padding: '16px 18px', borderBottom: '1px solid #EEF2F6', fontSize: 15, fontWeight: 700, margin: 0 }}>Messages</h1>
            {loading && <Busy label="Loading conversationsâ€¦" fill={false} />}
            {error && (
              <div role="alert" style={{ padding: '12px 18px', fontSize: 12.5, color: '#B42318' }}>
                Could not load messages: {error}
              </div>
            )}
            {!loading && contacts.length === 0 && (
              <div style={{ padding: 18, fontSize: 12.5, color: '#5B6B7F', lineHeight: 1.6 }}>
                No care-team members yet. Once a doctor takes over your care they appear here.
              </div>
            )}
            {contacts.map((c, i) => {
              const active = contact?.member_id === c.member_id;
              const initials = c.full_name.split(/\s+/).slice(0, 2).map((p) => p[0]?.toUpperCase()).join('');
              return (
                <Pressable
                  key={c.member_id}
                  onClick={() => setActiveContactId(c.member_id)}
                  ariaCurrent={active ? true : undefined}
                  style={{
                    padding: '14px 18px',
                    background: active ? '#EDF2FE' : undefined,
                    borderLeft: active ? '3px solid #1D4ED8' : undefined,
                    borderTop: !active && i > 0 ? '1px solid #EEF2F6' : undefined,
                    display: 'flex',
                    alignItems: 'center',
                    gap: 10,
                  }}
                >
                  <div aria-hidden="true" style={{ width: 34, height: 34, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600, flexShrink: 0 }}>
                    {initials}
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                    <div style={{ fontSize: 13.5, fontWeight: active ? 700 : 600 }}>{c.full_name}</div>
                    <div style={{ fontSize: 11.5, color: '#5B6B7F' }}>
                      {(c.role.charAt(0).toUpperCase() + c.role.slice(1)).replace('_', ' ')}
                      {c.specialty ? ` Â· ${c.specialty}` : ''}
                    </div>
                  </div>
                </Pressable>
              );
            })}
          </div>
          <div style={{ flex: 1, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            {contact ? (
              <>
                <div style={{ padding: '14px 20px', borderBottom: '1px solid #EEF2F6', display: 'flex', alignItems: 'center', gap: 10 }}>
                  <div aria-hidden="true" style={{ width: 34, height: 34, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600 }}>
                    {contact.full_name.split(/\s+/).slice(0, 2).map((p) => p[0]?.toUpperCase()).join('')}
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column' }}>
                    <h2 style={{ fontSize: 14, fontWeight: 700, margin: 0 }}>{contact.full_name}</h2>
                    <div style={{ fontSize: 11.5, color: '#116B3F' }}>Usually replies within 4 business hours</div>
                  </div>
                </div>
                <div ref={threadRef} role="log" aria-label={`Conversation with ${contact.full_name}`} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 14, padding: 20, overflow: 'auto' }}>
                  {threadState.loading && <Busy label="Loading messagesâ€¦" fill={false} />}
                  {messages.map((m) => (
                    <div key={m.id} title={stamp(m.created_at)} style={m.sent_by_patient ? meBubble : themBubble}>
                      {m.body}
                    </div>
                  ))}
                  {!threadState.loading && messages.length === 0 && (
                    <div style={{ color: '#8A97A8', fontSize: 13, textAlign: 'center', marginTop: 24 }}>
                      No messages yet â€” say hello.
                    </div>
                  )}
                </div>
                <div style={{ borderTop: '1px solid #EEF2F6', padding: '14px 20px', display: 'flex', gap: 10, alignItems: 'center' }}>
                  <TextField
                    value={draft}
                    onChange={setDraft}
                    placeholder={`Write to ${contact.full_name}â€¦`}
                    ariaLabel={`Write a message to ${contact.full_name}`}
                    onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); void send(); } }}
                    style={{ flex: 1, border: '1px solid #DDE3EB', borderRadius: 10, padding: '11px 14px', fontSize: 13.5, color: draft ? '#0F1C2E' : '#8A97A8' }}
                  />
                  <button
                    type="button"
                    onClick={() => void send()}
                    disabled={sending || !draft.trim()}
                    title="Sends your message to your care team."
                    style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 10, padding: '11px 18px', fontSize: 13.5, fontWeight: 600, opacity: sending || !draft.trim() ? 0.55 : 1, cursor: sending || !draft.trim() ? 'default' : 'pointer' }}
                  >
                    {sending ? 'Sendingâ€¦' : 'Send'}
                  </button>
                </div>
                {sendError && (
                  <div role="alert" style={{ padding: '0 20px 12px', fontSize: 12.5, color: '#B42318' }}>{sendError}</div>
                )}
              </>
            ) : (
              !loading && <div style={{ margin: 'auto', fontSize: 13.5, color: '#5B6B7F' }}>Select a conversation.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
