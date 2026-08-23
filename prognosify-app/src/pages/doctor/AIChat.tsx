import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Pressable, TextField } from '../../components/ui';

interface Message {
  id: number;
  role: 'user' | 'assistant';
  content: ReactNode;
  /** The seeded first answer carries the two follow-up navigation chips. */
  actions?: boolean;
}

const seed: Message[] = [
  { id: 1, role: 'user', content: "Why did Rosa Delgado's sepsis risk jump overnight?" },
  {
    id: 2,
    role: 'assistant',
    actions: true,
    content: (
      <>
        Three signals moved together between 10 PM and 6 AM:<br /><br />
        <b>1. Lactate</b> rose from 2.2 to 3.1 mmol/L (+0.31 to risk score)<br />
        <b>2. Heart rate</b> trended from 88 to 104 bpm over 6 hours (+0.24)<br />
        <b>3. MAP</b> drifted down to 72 mmHg (+0.18)<br /><br />
        Individually each is borderline; the combination matches early sepsis trajectories in similar patients (71F, pneumonia, day 4). Antibiotic response partially offsets this (−0.09).
      </>
    ),
  },
  { id: 3, role: 'user', content: 'What should I do before rounds?' },
  {
    id: 4,
    role: 'assistant',
    content: (
      <>
        Suggested priorities: <b>(1)</b> repeat lactate for Delgado within 2h, <b>(2)</b> check Whitfield's overnight weight and diuretic adherence, <b>(3)</b> review Adeyemi's morning ABG — mild CO₂ retention. I've drafted orders for 1 and 3; they need your sign-off.
      </>
    ),
  },
];

const suggestions = [
  'Summarize my high-risk patients',
  'Draft discharge summary for Kovacs',
  "Compare Nair's HbA1c trend",
];

/**
 * No model is wired up in this prototype, so anything the user sends gets one honest canned
 * reply instead of an invented clinical answer.
 */
const CANNED_REPLY =
  'This is a prototype build with no model connected, so I cannot answer that. The two exchanges above are fixed sample content, and nothing you type here is saved or sent anywhere.';

const composerId = 'ai-composer';

const userBubble: CSSProperties = { alignSelf: 'flex-end', maxWidth: 520, background: '#1D4ED8', color: '#fff', borderRadius: '14px 14px 4px 14px', padding: '12px 16px', fontSize: 14, lineHeight: 1.5 };
const assistantBubble: CSSProperties = { background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: '14px 14px 14px 4px', padding: '16px 18px', fontSize: 14, lineHeight: 1.65 };
const actionChip: CSSProperties = { border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 16, padding: '7px 14px', fontSize: 12.5, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' };

export default function AIChat() {
  const navigate = useNavigate();
  const [messages, setMessages] = useState<Message[]>(seed);
  const [draft, setDraft] = useState('');
  const nextId = useRef(seed.length + 1);
  const timers = useRef<number[]>([]);
  const threadRef = useRef<HTMLDivElement | null>(null);
  const settled = useRef(false);

  useEffect(() => () => { timers.current.forEach((t) => window.clearTimeout(t)); }, []);

  // Keep the newest message in view — but never move the scroll position on first paint.
  useEffect(() => {
    if (!settled.current) { settled.current = true; return; }
    const thread = threadRef.current;
    if (thread) thread.scrollTop = thread.scrollHeight;
  }, [messages]);

  const send = (raw: string) => {
    const text = raw.trim();
    if (!text) return;
    const userId = nextId.current++;
    const replyId = nextId.current++;
    setMessages((prev) => [...prev, { id: userId, role: 'user', content: text }]);
    setDraft('');
    const timer = window.setTimeout(() => {
      setMessages((prev) => [...prev, { id: replyId, role: 'assistant', content: CANNED_REPLY }]);
    }, 600);
    timers.current.push(timer);
  };

  const reset = () => {
    timers.current.forEach((t) => window.clearTimeout(t));
    timers.current = [];
    setMessages(seed);
    setDraft('');
  };

  const fillComposer = (text: string) => {
    setDraft(text);
    document.getElementById(composerId)?.focus();
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="aiChat" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>AI assistant</h1>
            <span style={{ background: '#EDF2FE', color: '#1D4ED8', border: '1px solid #C9D8FA', borderRadius: 12, padding: '3px 10px', fontSize: 12, fontWeight: 600 }}>Context: your patient panel</span>
          </div>
          <Pressable onClick={reset} title="Clears anything you typed and restores this demo conversation to its starting messages. Nothing is stored." style={{ fontSize: 13, color: '#5B6B7F', cursor: 'pointer' }}>New conversation</Pressable>
        </div>
        <div ref={threadRef} style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
          <div role="log" aria-label="Conversation" style={{ width: 760, display: 'flex', flexDirection: 'column', gap: 18, padding: '28px 0' }}>
            {messages.map((m) => {
              if (m.role === 'user') {
                return <div key={m.id} style={userBubble}>{m.content}</div>;
              }
              if (m.actions) {
                return (
                  <div key={m.id} style={{ alignSelf: 'flex-start', maxWidth: 620, display: 'flex', flexDirection: 'column', gap: 10 }}>
                    <div style={assistantBubble}>{m.content}</div>
                    <div style={{ display: 'flex', gap: 8 }}>
                      <Pressable onClick={() => navigate('/doctor/patients/104-882/prognosis')} style={actionChip}>Open full report</Pressable>
                      <Pressable onClick={() => navigate('/doctor/patients/104-882')} style={actionChip}>View patient chart</Pressable>
                    </div>
                  </div>
                );
              }
              return <div key={m.id} style={{ alignSelf: 'flex-start', maxWidth: 620, ...assistantBubble }}>{m.content}</div>;
            })}
          </div>
        </div>
        <div style={{ borderTop: '1px solid #DDE3EB', background: '#ffffff', padding: '16px 0', display: 'flex', justifyContent: 'center', flexShrink: 0 }}>
          <div style={{ width: 760, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', gap: 8 }}>
              {suggestions.map((s) => (
                <Pressable key={s} onClick={() => fillComposer(s)} title="Puts this question in the composer so you can edit or send it." style={{ border: '1px solid #DDE3EB', borderRadius: 16, padding: '6px 12px', fontSize: 12, color: '#5B6B7F', cursor: 'pointer' }}>{s}</Pressable>
              ))}
            </div>
            <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <TextField
                id={composerId}
                value={draft}
                onChange={setDraft}
                ariaLabel="Ask about your patients, labs, or predictions"
                placeholder="Ask about your patients, labs, or predictions…"
                onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); send(draft); } }}
                style={{ flex: 1, border: '1px solid #DDE3EB', borderRadius: 10, padding: '12px 16px', fontSize: 14, color: '#5B6B7F' }}
              />
              <Pressable onClick={() => send(draft)} style={{ background: '#1D4ED8', color: '#fff', borderRadius: 10, padding: '12px 20px', fontSize: 14, fontWeight: 600, cursor: 'pointer' }}>Send</Pressable>
            </div>
            <div style={{ fontSize: 11.5, color: '#8A97A8' }}>Responses are AI-generated and may be incomplete. Verify against the chart before acting.</div>
          </div>
        </div>
      </div>
    </div>
  );
}
