import { useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import PortalNav from '../../components/PortalNav';
import { Pressable, TextField, pressableReset } from '../../components/ui';

type Bubble = { me: boolean; text: string };

type Conversation = {
  name: string;
  initials: string;
  time: string;
  preview: string;
  thread: Bubble[];
};

const conversations: Conversation[] = [
  {
    name: 'Nurse N. Adams',
    initials: 'NA',
    time: '9:02 AM',
    preview: 'How did the new dose feel this week?',
    thread: [
      { me: false, text: 'Hi Priya — checking in. How did the new metformin dose feel this week? Any stomach upset?' },
      { me: true, text: 'Much better than the first week. Mild nausea on day 1–2, gone since.' },
      { me: false, text: "That's normal and a good sign. Keep taking it with breakfast. Dr. Mehta will review your HbA1c with you Thursday." },
    ],
  },
  {
    name: 'Dr. Anita Mehta',
    initials: 'AM',
    time: 'Aug 12',
    preview: 'Your lab order is in for Friday.',
    thread: [{ me: false, text: 'Your lab order is in for Friday.' }],
  },
  {
    name: 'Billing office',
    initials: 'BO',
    time: 'Aug 5',
    preview: 'Receipt for your July visit.',
    thread: [{ me: false, text: 'Receipt for your July visit.' }],
  },
];

const bubbleBase: CSSProperties = { maxWidth: 380, padding: '11px 14px', fontSize: 13.5, lineHeight: 1.5 };
const themBubble: CSSProperties = { ...bubbleBase, alignSelf: 'flex-start', background: '#F4F6F9', borderRadius: '12px 12px 12px 4px' };
const meBubble: CSSProperties = { ...bubbleBase, alignSelf: 'flex-end', background: '#1D4ED8', color: '#fff', borderRadius: '12px 12px 4px 12px' };

export default function PatientMessages() {
  const [activeIndex, setActiveIndex] = useState(0);
  const [draft, setDraft] = useState('');
  // Messages typed in this session, per conversation. Local to this browser tab — there is no server.
  const [typed, setTyped] = useState<Record<number, string[]>>({});
  const threadRef = useRef<HTMLDivElement | null>(null);

  const current = conversations[activeIndex];
  const messages: Bubble[] = [
    ...current.thread,
    ...(typed[activeIndex] ?? []).map((text) => ({ me: true, text })),
  ];

  useEffect(() => {
    const el = threadRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [activeIndex, messages.length]);

  const send = () => {
    const text = draft.trim();
    if (!text) return;
    setTyped((prev) => ({ ...prev, [activeIndex]: [...(prev[activeIndex] ?? []), text] }));
    setDraft('');
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Messages" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'hidden' }}>
        <div style={{ width: 960, display: 'flex', gap: 16, padding: '28px 0', height: '100%', boxSizing: 'border-box' }}>
          <div style={{ width: 300, flexShrink: 0, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
            <h1 style={{ padding: '16px 18px', borderBottom: '1px solid #EEF2F6', fontSize: 15, fontWeight: 700, margin: 0 }}>Messages</h1>
            {conversations.map((c, i) => {
              const active = i === activeIndex;
              return (
                <Pressable
                  key={c.name}
                  onClick={() => setActiveIndex(i)}
                  ariaCurrent={active ? true : undefined}
                  style={{
                    padding: '14px 18px',
                    background: active ? '#EDF2FE' : undefined,
                    borderLeft: active ? '3px solid #1D4ED8' : undefined,
                    borderTop: !active && i > 0 ? '1px solid #EEF2F6' : undefined,
                    display: 'flex',
                    flexDirection: 'column',
                    gap: 3,
                  }}
                >
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                    <div style={{ fontSize: 13.5, fontWeight: active ? 700 : 600 }}>{c.name}</div>
                    <div style={{ fontSize: 11.5, color: '#5B6B7F' }}>{c.time}</div>
                  </div>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>{c.preview}</div>
                </Pressable>
              );
            })}
          </div>
          <div style={{ flex: 1, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
            <div style={{ padding: '14px 20px', borderBottom: '1px solid #EEF2F6', display: 'flex', alignItems: 'center', gap: 10 }}>
              <div aria-hidden="true" style={{ width: 34, height: 34, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600 }}>{current.initials}</div>
              <div style={{ display: 'flex', flexDirection: 'column' }}>
                <h2 style={{ fontSize: 14, fontWeight: 700, margin: 0 }}>{current.name}</h2>
                <div style={{ fontSize: 11.5, color: '#116B3F' }}>Usually replies within 4 business hours</div>
              </div>
            </div>
            <div ref={threadRef} style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 14, padding: 20, overflow: 'auto' }}>
              {messages.map((m, i) => (
                <div key={`${activeIndex}-${i}`} style={m.me ? meBubble : themBubble}>{m.text}</div>
              ))}
            </div>
            <div style={{ borderTop: '1px solid #EEF2F6', padding: '14px 20px', display: 'flex', gap: 10, alignItems: 'center' }}>
              <TextField
                value={draft}
                onChange={setDraft}
                placeholder="Write a message…"
                ariaLabel={`Write a message to ${current.name}`}
                onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); send(); } }}
                // Empty field renders the mockup's grey prompt colour exactly; typed text switches to
                // body ink so what you write stays readable.
                style={{ flex: 1, border: '1px solid #DDE3EB', borderRadius: 10, padding: '11px 14px', fontSize: 13.5, color: draft ? '#0F1C2E' : '#8A97A8' }}
              />
              <button
                type="button"
                onClick={send}
                aria-disabled={draft.trim() === '' || undefined}
                title="Adds your message to this thread in this browser only — the prototype has no server, so nothing is delivered."
                style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 10, padding: '11px 18px', fontSize: 13.5, fontWeight: 600 }}
              >
                Send
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
