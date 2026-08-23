import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import PortalNav from '../../components/PortalNav';
import { Busy, Pressable, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  appointmentTitle,
  confirmMyAppointment,
  getMyFullName,
  getMyMedications,
  getMyUpcomingAppointments,
  getReleasedResults,
  providerName,
} from '../../lib/api';
import { dayLabel, shortDate, timeLabel, visitStamp } from '../../lib/format';

export default function PatientHome() {
  const navigate = useNavigate();
  const [confirming, setConfirming] = useState(false);
  const [confirmError, setConfirmError] = useState<string | null>(null);

  const { data, error, loading, reload } = useAsync(async () => {
    const [appointments, results, medications, fullName] = await Promise.all([
      getMyUpcomingAppointments(),
      getReleasedResults(),
      getMyMedications(),
      getMyFullName(),
    ]);
    return {
      next: appointments[0] ?? null,
      results,
      latest: results[0] ?? null,
      medications: medications.slice(0, 3),
      fullName,
    };
  }, []);

  const confirm = async () => {
    if (!data?.next) return;
    setConfirming(true);
    setConfirmError(null);
    try {
      await confirmMyAppointment(data.next.id);
      reload();
    } catch (err) {
      setConfirmError(err instanceof Error ? err.message : 'Could not send the confirmation.');
    } finally {
      setConfirming(false);
    }
  };

  const confirmed = Boolean(data?.next?.confirmed_at);
  const firstName = (data?.fullName ?? '').split(/\s+/)[0] || '';

  // The featured result card: the most recent released result.
  const latest = data?.latest ?? null;
  const abnormal = latest ? latest.abnormal_flag !== 'normal' : false;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Home" homeVariant />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 960, display: 'flex', flexDirection: 'column', gap: 24, padding: '36px 0' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>
              {firstName ? `Hello, ${firstName}` : 'Your care'}
            </h1>
            <div style={{ fontSize: 14, color: '#5B6B7F' }}>Here's what's coming up in your care.</div>
          </div>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 12, padding: '14px 18px', fontSize: 13.5, color: '#B42318' }}>
              Could not load your portal: {error}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 16 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.05em' }}>NEXT APPOINTMENT</div>
              {loading && <div role="status" style={{ fontSize: 14, color: '#5B6B7F' }}><Busy label="Loading" fill={false} /></div>}
              {!loading && !error && !data?.next && (
                <div style={{ fontSize: 14, color: '#5B6B7F', lineHeight: 1.6 }}>
                  Nothing booked right now. Book a visit below and it will appear here.
                </div>
              )}
              {data?.next && (
                <>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
                    <div style={{ width: 56, height: 56, borderRadius: 12, background: '#EDF2FE', color: '#1D4ED8', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', fontWeight: 700 }}>
                      <div style={{ fontSize: 11 }}>{dayLabel(data.next.scheduled_start).split(',')[0].toUpperCase()}</div>
                      <div style={{ fontSize: 20 }}>{shortDate(data.next.scheduled_start).split(' ')[1]}</div>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                      <div style={{ fontSize: 16, fontWeight: 600 }}>{appointmentTitle(data.next)}</div>
                      <div style={{ fontSize: 13.5, color: '#5B6B7F' }}>
                        {[dayLabel(data.next.scheduled_start), timeLabel(data.next.scheduled_start), data.next.room_label ?? data.next.department?.name ?? null]
                          .filter(Boolean)
                          .join(' Â· ')}
                      </div>
                    </div>
                  </div>
                  <div style={{ display: 'flex', gap: 10 }}>
                    {/* A real write: patients may stamp confirmed_at on their OWN appointment
                        (enforced server-side), so this button actually reaches the clinic. */}
                    <button
                      type="button"
                      onClick={() => void confirm()}
                      disabled={confirmed || confirming}
                      aria-disabled={confirmed || undefined}
                      title={confirmed
                        ? `Confirmed ${visitStamp(data.next.confirmed_at)} â€” the clinic can see this.`
                        : 'Sends your confirmation to the clinic.'}
                      style={{
                        ...pressableReset,
                        opacity: confirming ? 0.7 : 1,
                        background: confirmed ? '#116B3F' : '#1D4ED8',
                        color: '#fff',
                        borderRadius: 8,
                        padding: '9px 18px',
                        fontSize: 13,
                        fontWeight: 600,
                        cursor: confirmed ? 'default' : 'pointer',
                      }}
                    >
                      {confirming ? 'Sendingâ€¦' : confirmed ? 'Confirmed âœ“' : 'Confirm'}
                    </button>
                    <Pressable onClick={() => navigate('/patient/book')} style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '9px 18px', fontSize: 13, fontWeight: 500 }}>Reschedule</Pressable>
                  </div>
                  {confirmError && (
                    <div role="alert" style={{ fontSize: 12.5, color: '#B42318' }}>{confirmError}</div>
                  )}
                </>
              )}
            </div>
            <Pressable className="hover-border-accent" onClick={() => navigate('/patient/results')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.05em' }}>NEW RESULT</div>
                {abnormal && (
                  <span style={{ background: '#FEFAF0', color: '#B54708', border: '1px solid #F3E3C2', borderRadius: 12, padding: '2px 9px', fontSize: 11.5, fontWeight: 600 }}>Needs attention</span>
                )}
              </div>
              {loading && <div role="status" style={{ fontSize: 14, color: '#5B6B7F' }}><Busy label="Loading" fill={false} /></div>}
              {!loading && latest ? (
                <>
                  <div style={{ fontSize: 16, fontWeight: 600 }}>
                    {latest.test.name} â€” {latest.value_numeric != null ? `${latest.value_numeric}${latest.unit ? ` ${latest.unit}` : ''}` : latest.value_text}
                  </div>
                  <div style={{ fontSize: 13, color: '#5B6B7F', lineHeight: 1.5 }}>
                    Resulted {visitStamp(latest.resulted_at)}. Your care team sees everything here too.
                  </div>
                </>
              ) : (
                !loading && (
                  <div style={{ fontSize: 13, color: '#5B6B7F', lineHeight: 1.5 }}>
                    No results have been shared with you yet. They appear here as soon as your care team releases them.
                  </div>
                )
              )}
              <div style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 600 }}>View result â†’</div>
            </Pressable>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 16 }}>
            <Pressable className="hover-border-accent" onClick={() => navigate('/patient/care-plan')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 20, display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>Today's care plan</div>
              <div style={{ fontSize: 13, color: '#5B6B7F', lineHeight: 1.6 }}>
                {(data?.medications.length ?? 0) > 0
                  ? data!.medications.map((m) => `${m.drug_name} ${m.dose_text} Â· ${m.frequency_text}`).join('\n')
                  : 'Your care team has not set up plan items yet.'}
              </div>
            </Pressable>
            <Pressable className="hover-border-accent" onClick={() => navigate('/patient/messages')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 20, display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <div style={{ fontSize: 14, fontWeight: 600 }}>Messages</div>
              </div>
              <div style={{ fontSize: 13, color: '#5B6B7F', lineHeight: 1.6 }}>Secure messaging arrives in an upcoming release of the portal.</div>
            </Pressable>
            <Pressable className="hover-border-accent" onClick={() => navigate('/patient/book')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 20, display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>Need to be seen?</div>
              <div style={{ fontSize: 13, color: '#5B6B7F', lineHeight: 1.6 }}>Book a visit with your care team or a video consult.</div>
              <div style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 600 }}>Book a visit â†’</div>
            </Pressable>
          </div>
          <Pressable
            className="on-dark"
            onClick={() => navigate('/patient/results')}
            title="View your results"
            style={{ background: '#0F1C2E', borderRadius: 14, padding: '20px 24px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', color: '#fff' }}
          >
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF' }}>YOUR RESULTS</div>
              <div style={{ fontSize: 13.5, color: '#C7D2E4' }}>
                {data && data.results.length > 0
                  ? `${data.results.length} result${data.results.length > 1 ? 's' : ''} shared by your care team â€” the newest from ${visitStamp(data.results[0].resulted_at)}${data.next ? `. Next visit: ${visitStamp(data.next.scheduled_start)} with ${providerName(data.next)}.` : '.'}`
                  : 'When your care team shares a result, it lands here first.'}
              </div>
            </div>
          </Pressable>
        </div>
      </div>
    </div>
  );
}
