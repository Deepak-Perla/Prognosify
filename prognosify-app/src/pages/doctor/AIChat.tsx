import { useEffect, useRef, useState } from 'react';
import type { CSSProperties } from 'react';
import SideNav from '../../components/SideNav';
import { Pressable, TextField } from '../../components/ui';

interface Message {
  id: number;
  role: 'user' | 'assistant';
  content: string;
}

/**
 * The clinic's operational assistant.
 *
 * It drafts and summarises — schedules, reminders, follow-ups — the moment an AI provider key
 * is connected to the assistant service. Until then it says so honestly: no model is wired up,
 * nothing typed here is stored, and nothing pretends to be intelligent.
 *
 * Deliberately NOT a clinical tool: it will not offer diagnoses, risk scores or treatment
 * advice. Clinical decision support is a regulated, validation-heavy product tier that lives
 * behind its own plan entitlement — not a chat window.
 */
const INTRO =
  'Hi! I\'m the clinic assistant. Once your AI key is connected I can draft no-show follow-ups, ' +
  'summarise the day\'s schedule, write payment reminders and answer questions about your ' +
  'calendar. I keep to operations — for anything clinical, the chart and your own judgment lead.';

const suggestions = [
  'Draft a no-show follow-up message',
  'Summarize today\'s schedule',
  'Write a polite payment reminder',
  'What should I prepare for tomorrow?',
];

const CANNED_REPLY =
  'Your AI key isn\'t connected yet, so I can\'t draft that. Everything else in the clinic — ' +
  'queue, bookings, billing, messages — runs live; this assistant switches on the moment the ' +
  'key is added on the server.';

const composerId = 'ai-composer';

const userBubble: CSSProperties = { alignSelf: 'flex-end', maxWidth: 520, background: '#1D4ED8', color: '#fff', borderRadius: '14px 14px 4px 14px', padding: '12px 16px', fontSize: 14, lineHeight: 1.5 };
const assistantBubble: CSSProperties = { background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: '14px 14px 14px 4px', padding: '16px 18px', fontSize: 14, lineHeight: 1.65, whiteSpace: 'pre-wrap' };
const actionChip: CSSProperties = { border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 16, padding: '7px 14px', fontSize: 12.5, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' };

export default function AIChat() {
  const [messages, setMessages] = useState<Message[]>([
    { id: 1, role: 'assistant', content: INTRO },
  ]);
  const [draft, setDraft] = useState('');
  const nextId = useRef(2);
  const timers = useRef<number[]>([]);
  const threadRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => () => { timers.current.forEach((t) => window.clearTimeout(t)); }, []);

  // Keep the newest message in view — but never move the scroll position on first paint.
  const settled = useRef(false);
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
    }, 500);
    timers.current.push(timer);
  };

  const reset = () => {
    timers.current.forEach((t) => window.clearTimeout(t));
    timers.current = [];
    setMessages([{ id: nextId.current++, role: 'assistant', content: INTRO }]);
    setDraft('');
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="aiChat" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>AI assistant</h1>
            <span style={{ background: '#FEFAF0', color: '#B54708', border: '1px solid #F3E3C2', borderRadius: 12, padding: '3px 10px', fontSize: 12, fontWeight: 600 }}>
              Awaiting AI key
            </span>
          </div>
          <Pressable onClick={reset} title="Clears the conversation and restores the starting state. Nothing is stored." style={{ fontSize: 13, color: '#5B6B7F', cursor: 'pointer' }}>
            New conversation
          </Pressable>
        </div>
        <div ref={threadRef} style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
          <div role="log" aria-label="Conversation" style={{ width: 760, display: 'flex', flexDirection: 'column', gap: 18, padding: '28px 0' }}>
            {messages.map((m) =>
              m.role === 'user' ? (
                <div key={m.id} style={userBubble}>{m.content}</div>
              ) : (
                <div key={m.id} style={{ alignSelf: 'flex-start', maxWidth: 620, ...assistantBubble }}>{m.content}</div>
              ),
            )}
          </div>
        </div>
        <div style={{ borderTop: '1px solid #DDE3EB', background: '#ffffff', padding: '16px 0', display: 'flex', justifyContent: 'center', flexShrink: 0 }}>
          <div style={{ width: 760, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {suggestions.map((s) => (
                <Pressable key={s} onClick={() => { setDraft(s); document.getElementById(composerId)?.focus(); }} title="Puts this request in the composer so you can edit or send it." style={actionChip}>
                  {s}
                </Pressable>
              ))}
            </div>
            <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <TextField
                id={composerId}
                value={draft}
                onChange={setDraft}
                ariaLabel="Ask the clinic assistant"
                placeholder="Ask about schedules, reminders, follow-ups…"
                onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); send(draft); } }}
                style={{ flex: 1, border: '1px solid #DDE3EB', borderRadius: 10, padding: '12px 16px', fontSize: 14, color: '#0F1C2E' }}
              />
              <Pressable onClick={() => send(draft)} style={{ background: '#1D4ED8', color: '#fff', borderRadius: 10, padding: '12px 20px', fontSize: 14, fontWeight: 600, cursor: 'pointer' }}>
                Send
              </Pressable>
            </div>
            <div style={{ fontSize: 11.5, color: '#8A97A8' }}>
              Operations only — the assistant never offers diagnoses or treatment advice. Clinical judgment stays with you.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
