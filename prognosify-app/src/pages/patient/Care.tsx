import { useState } from 'react';
import type { CSSProperties } from 'react';
import PortalNav from '../../components/PortalNav';
import { Busy, Pressable, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  getCareGoals,
  getCarePlanTasks,
  getMyMedications,
  getPortalIdentity,
  requestRefill,
  setTaskDone,
} from '../../lib/api';

const doneTile: CSSProperties = {
  width: 20, height: 20, borderRadius: 6, background: '#116B3F', color: '#fff',
  display: 'flex', alignItems: 'center', justifyContent: 'center',
  fontSize: 12, fontWeight: 700, flexShrink: 0,
};
const openTile: CSSProperties = {
  width: 20, height: 20, borderRadius: 6, border: '1.5px solid #C6CFDA', flexShrink: 0,
};

const goalColor = (pct: number): string => (pct >= 75 ? '#116B3F' : pct >= 40 ? '#B54708' : '#B42318');

export default function PatientCare() {
  const [busyTask, setBusyTask] = useState<string | null>(null);
  const [refillBusy, setRefillBusy] = useState<string | null>(null);

  const { data, error, loading, reload } = useAsync(async () => {
    const me = await getPortalIdentity();
    if (!me) return null;
    const [goals, tasks, meds] = await Promise.all([
      getCareGoals(me.patient_id),
      getCarePlanTasks(me.patient_id),
      getMyMedications(),
    ]);
    const isToday = (iso: string | null): boolean =>
      iso != null && new Date(iso).toDateString() === new Date().toDateString();
    return {
      fullName: me.full_name,
      goals,
      tasks,
      meds,
      doneCount: tasks.filter((t) => isToday(t.last_done_at)).length,
    };
  }, []);

  const toggleTask = async (taskId: string, done: boolean) => {
    setBusyTask(taskId);
    try {
      await setTaskDone(taskId, done);
      reload();
    } finally {
      setBusyTask(null);
    }
  };

  const refill = async (medicationId: string) => {
    setRefillBusy(medicationId);
    try {
      await requestRefill(medicationId);
      reload();
    } finally {
      setRefillBusy(null);
    }
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Care plan" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 860, display: 'flex', flexDirection: 'column', gap: 22, padding: '36px 0' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>My care plan</h1>
              <div style={{ fontSize: 14, color: '#5B6B7F' }}>
                {data?.fullName ? `Set up for ${data.fullName.split(' ')[0]} by your care team.` : ''}
              </div>
            </div>
          </div>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 12, padding: '14px 18px', fontSize: 13.5, color: '#B42318' }}>
              Could not load your care plan: {error}
            </div>
          )}
          {loading && (
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24 }}>
              <Busy label="Loading your care planâ€¦" fill={false} />
            </div>
          )}
          {!loading && !error && data && (
            <>
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <h2 style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>Today's checklist</h2>
                  <div role="status" style={{ fontSize: 12.5, color: '#116B3F', fontWeight: 600 }}>
                    {data.doneCount} of {data.tasks.length} done
                  </div>
                </div>
                {data.tasks.length === 0 && (
                  <div style={{ fontSize: 13.5, color: '#5B6B7F' }}>
                    Your care team hasn't added checklist items yet.
                  </div>
                )}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {data.tasks.map((t) => {
                    const isDone =
                      t.last_done_at != null &&
                      new Date(t.last_done_at).toDateString() === new Date().toDateString();
                    return (
                      <div key={t.id} style={{ display: 'flex', gap: 12, alignItems: 'center', border: `1px solid ${isDone ? '#EEF2F6' : '#DDE3EB'}`, borderRadius: 10, padding: '13px 16px' }}>
                        <button
                          type="button"
                          role="checkbox"
                          aria-checked={isDone}
                          aria-label={t.title}
                          disabled={busyTask === t.id}
                          onClick={() => void toggleTask(t.id, !isDone)}
                          style={{
                            ...pressableReset,
                            ...(isDone ? doneTile : openTile),
                            cursor: busyTask === t.id ? 'wait' : 'pointer',
                            opacity: busyTask === t.id ? 0.6 : 1,
                          }}
                        >
                          {isDone ? 'âœ“' : null}
                        </button>
                        <div style={{ flex: 1, fontSize: 13.5 }}>
                          <span style={{ fontWeight: 600 }}>{t.title}</span>
                          {t.schedule_text ? ` Â· ${t.schedule_text}` : t.detail ? ` Â· ${t.detail}` : ''}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 22, display: 'flex', flexDirection: 'column', gap: 12 }}>
                  <h2 style={{ fontSize: 14.5, fontWeight: 700, margin: 0 }}>Goals</h2>
                  {data.goals.length === 0 && (
                    <div style={{ fontSize: 13, color: '#5B6B7F' }}>No goals set yet.</div>
                  )}
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 13 }}>
                    {data.goals.map((g) => (
                      <div key={g.id} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                          <div style={{ fontWeight: 600 }}>{g.label}</div>
                          <div style={{ color: '#5B6B7F' }}>{g.target_label ?? `${g.progress_pct}%`}</div>
                        </div>
                        <div
                          role="progressbar"
                          aria-label={g.label}
                          aria-valuemin={0}
                          aria-valuemax={100}
                          aria-valuenow={g.progress_pct}
                          aria-valuetext={g.target_label ?? `${g.progress_pct}%`}
                          style={{ height: 7, borderRadius: 4, background: '#F4F6F9' }}
                        >
                          <div style={{ width: `${g.progress_pct}%`, height: 7, borderRadius: 4, background: goalColor(g.progress_pct) }} />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
                  <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 22, display: 'flex', flexDirection: 'column', gap: 10 }}>
                    <h2 style={{ fontSize: 14.5, fontWeight: 700, margin: 0 }}>My medications</h2>
                    {data.meds.length === 0 && (
                      <div style={{ fontSize: 13, color: '#5B6B7F' }}>No active prescriptions.</div>
                    )}
                    <div style={{ fontSize: 13.5, display: 'flex', flexDirection: 'column', gap: 8 }}>
                      {data.meds.map((m) => (
                        <div key={m.id} style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                            <div>{m.drug_name} {m.dose_text}</div>
                            <div style={{ color: '#5B6B7F' }}>{m.frequency_text}</div>
                          </div>
                          {m.refill_requested_at ? (
                            <span role="status" style={{ fontSize: 11.5, color: '#116B3F', fontWeight: 600 }}>Refill requested âœ“ â€” your care team will confirm</span>
                          ) : (
                            <Pressable
                              onClick={() => void refill(m.id)}
                              disabled={refillBusy === m.id}
                              title={`Asks your care team to authorise a refill of ${m.drug_name}.`}
                              style={{ fontSize: 11.5, color: '#1D4ED8', fontWeight: 600, width: 'fit-content' }}
                            >
                              {refillBusy === m.id ? 'Requestingâ€¦' : 'Request refill â†’'}
                            </Pressable>
                          )}
                        </div>
                      ))}
                    </div>
                  </div>
                  <div style={{ background: '#0F1C2E', borderRadius: 14, padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 6, color: '#fff' }}>
                    <h2 style={{ fontSize: 12.5, fontWeight: 600, color: '#8FB0FF', margin: 0 }}>WHY THIS PLAN</h2>
                    <div style={{ fontSize: 13, color: '#C7D2E4', lineHeight: 1.6 }}>
                      Your care team reviews this plan at every visit â€” tick items off as you go and they see your progress before your next appointment.
                    </div>
                  </div>
                </div>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
