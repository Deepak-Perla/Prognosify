import { useState, type CSSProperties, type ReactNode } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import SideNav from '../../components/SideNav';
import { Checkbox, Pressable, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  getPatientChart,
  getPatientSummaryByMrn,
  RISK_TYPE_LABEL,
  type RiskFactorRow,
  type RiskScoreRow,
} from '../../lib/api';
import { horizonLabel, pct, shortDate, timeLabel } from '../../lib/format';

/**
 * "Export PDF" and "Add to chart" both need a server-side writer; rather than triggering a fake
 * download or pretending the report was filed, they stay focusable and marked aria-disabled with
 * an explanatory tooltip.
 */
const NO_BACKEND = 'Not available yet — report export and chart commitment are not built in this release.';

function NotImplemented({ style, children }: { style: CSSProperties; children: ReactNode }) {
  return (
    <button type="button" aria-disabled="true" title={NO_BACKEND} style={{ ...pressableReset, ...style }}>
      {children}
    </button>
  );
}

/** The accepted checklist lives only in this screen's state — review-state writes are a later milestone. */
const LOCAL_ONLY = 'Marks every recommendation as accepted in this view only. Review decisions are not written back yet.';

function factorColor(weight: number): string {
  if (weight < 0) return '#116B3F';
  return weight >= 0.2 ? '#B42318' : '#B54708';
}

function factorBar(f: RiskFactorRow): number {
  const magnitude = f.normalized_magnitude ?? Math.min(1, Math.abs(f.weight));
  return Math.round(magnitude * 100);
}

export default function Prognosis() {
  const navigate = useNavigate();
  const mrn = useParams<{ mrn: string }>().mrn ?? '';
  const [accepted, setAccepted] = useState<Record<string, boolean>>({});

  const { data, error, loading } = useAsync(async () => {
    const summary = await getPatientSummaryByMrn(mrn);
    if (!summary) return null;
    const chart = await getPatientChart(summary.patient_id);
    return { summary, chart };
  }, [mrn]);

  if (loading) {
    return (
      <div style={{ width: '100%', height: '100%', display: 'flex' }}>
        <SideNav role="doctor" active="patients" />
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }} role="status">
          <span style={{ fontSize: 13.5, color: '#5B6B7F' }}>Loading prognosis…</span>
        </div>
      </div>
    );
  }

  if (error || !data) {
    return (
      <div style={{ width: '100%', height: '100%', display: 'flex' }}>
        <SideNav role="doctor" active="patients" />
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 12 }}>
          <div role="alert" style={{ fontSize: 14, color: '#B42318' }}>{error ?? `No patient with MRN ${mrn} is visible to you.`}</div>
          <Pressable onClick={() => navigate('/doctor/patients')} style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 600 }}>← All patients</Pressable>
        </div>
      </div>
    );
  }

  const { summary, chart } = data;
  const probabilityScores = chart.riskScores.filter((s) => s.value_kind === 'probability');
  const rangeScore = chart.riskScores.find((s) => s.value_kind === 'range') ?? null;
  const leadScore = probabilityScores[0] ?? null;
  // Factor bars belong to whichever score they hang off; show all for the current run.
  const factors = chart.factors;

  const setOne = (id: string, value: boolean) =>
    setAccepted((prev) => ({ ...prev, [id]: value }));
  const allAccepted = (chart.findings.length ?? 0) > 0 && chart.findings.every((f) => accepted[f.id]);

  const scoreTone = (band: RiskScoreRow['band']): string =>
    band === 'high' || band === 'critical' ? '#B42318' : band === 'medium' ? '#B54708' : '#116B3F';

  interface Tile {
    label: string;
    value: string;
    barColor: string;
    change: string;
    changeColor: string;
    fill: string;
    accent: string;
  }

  const probabilityTile = (s: RiskScoreRow, accent: string): Tile => ({
    label: `${RISK_TYPE_LABEL[s.risk_type]}${s.horizon ? ` · ${horizonLabel(s.horizon)}` : ''}`,
    value: pct(s.probability),
    barColor: scoreTone(s.band),
    change:
      s.change_points != null
        ? `${Number(s.change_points) >= 0 ? '↑' : '↓'} ${Math.abs(Number(s.change_points))} pts${s.change_note ? ` ${s.change_note}` : ''}`
        : `Band: ${s.band}`,
    changeColor: scoreTone(s.band),
    fill: pct(s.probability),
    accent,
  });

  const emptyTile = (label: string): Tile => ({
    label,
    value: '—',
    barColor: '#C6CFDA',
    change: 'No score on file',
    changeColor: '#5B6B7F',
    fill: '0%',
    accent: '#DDE3EB',
  });

  const rangeTile = (s: RiskScoreRow): Tile => ({
    label: RISK_TYPE_LABEL[s.risk_type],
    value: `${Number(s.range_low)}–${Number(s.range_high)} ${s.unit ?? ''}`.trim(),
    barColor: scoreTone(s.band),
    change: s.baseline_label
      ? `vs. ${Number(s.baseline_low)}–${Number(s.baseline_high)} ${s.baseline_label}`
      : `Band: ${s.band}`,
    changeColor: '#5B6B7F',
    fill: '70%',
    accent: '#DDE3EB',
  });

  const tiles: Tile[] =
    probabilityScores.length === 0 && !rangeScore
      ? [emptyTile('Sepsis risk'), emptyTile('ICU transfer'), emptyTile('Est. length of stay')]
      : [
          probabilityScores[0] ? probabilityTile(probabilityScores[0], '#F1D3D0') : emptyTile('Risk score'),
          probabilityScores[1] ? probabilityTile(probabilityScores[1], '#F3E3C2') : null,
          rangeScore ? rangeTile(rangeScore) : null,
        ].filter((t): t is Tile => t !== null);

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="patients" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ background: '#ffffff', borderBottom: '1px solid #DDE3EB', padding: '16px 28px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <Pressable onClick={() => navigate(`/doctor/patients/${summary.mrn}`)} ariaLabel={`Back to ${summary.full_name}`} style={{ fontSize: 13, color: '#5B6B7F', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4 }}>
              <ArrowLeft size={14} /> {summary.full_name}
            </Pressable>
            <h1 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>AI prognosis report</h1>
            <span style={{ background: '#EDF2FE', color: '#1D4ED8', border: '1px solid #C9D8FA', borderRadius: 12, padding: '3px 10px', fontSize: 12, fontWeight: 600 }}>
              {chart.run ? `Model ${chart.run.model_version ?? '?'} · Generated ${shortDate(chart.run.created_at)} ${timeLabel(chart.run.created_at)}` : 'No model runs yet'}
            </span>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <NotImplemented style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 500, cursor: 'pointer' }}>Export PDF</NotImplemented>
            <NotImplemented style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>Add to chart</NotImplemented>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          <div style={{ flex: 1.4, display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 12 }}>
              {tiles.map((tile) => (
                <div key={tile.label} style={{ background: '#ffffff', border: `1px solid ${tile.accent}`, borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>{tile.label}</div>
                  <div style={{ fontSize: 28, fontWeight: 700 }}>{tile.value}</div>
                  <div aria-hidden="true" style={{ height: 6, borderRadius: 3, background: '#F4F6F9' }}><div style={{ width: tile.fill, height: 6, borderRadius: 3, background: tile.barColor }} /></div>
                  <div style={{ fontSize: 12, color: tile.changeColor, fontWeight: 500 }}>{tile.change}</div>
                </div>
              ))}
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Contributing factors</h2>
              {factors.length === 0 ? (
                <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F' }}>
                  No factor attribution stored for this run yet.
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                  {factors.map((f) => (
                    <div key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                      <div style={{ width: 180, fontSize: 13.5, fontWeight: 500 }}>{f.label}</div>
                      <div aria-hidden="true" style={{ flex: 1, height: 8, borderRadius: 4, background: '#F4F6F9' }}>
                        <div style={{ width: `${factorBar(f)}%`, height: 8, borderRadius: 4, background: factorColor(Number(f.weight)) }} />
                      </div>
                      <div style={{ width: 44, fontSize: 12.5, color: '#5B6B7F', textAlign: 'right' }}>
                        {Number(f.weight) >= 0 ? '+' : '−'}
                        {Math.abs(Number(f.weight)).toFixed(2)}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
            <div style={{ background: '#F8F9FB', border: '1px solid #DDE3EB', borderRadius: 12, padding: '16px 20px', fontSize: 12.5, color: '#5B6B7F', lineHeight: 1.6 }}>
              Prognosify predictions support, and never replace, clinical judgment.{' '}
              {chart.run?.model_version
                ? `This report was produced by model ${chart.run.model_version}.`
                : 'Once a model run is recorded, its version and provenance are shown here.'}{' '}
              Full factor attribution is kept with each score in the audit log.
            </div>
          </div>
          <div style={{ width: 380, flexShrink: 0, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Recommended actions</h2>
              {chart.findings.length === 0 ? (
                <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F' }}>
                  No recommended actions were produced by the latest run.
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {chart.findings.map((f) => (
                    <div key={f.id} style={{ display: 'flex', gap: 10, border: '1px solid #DDE3EB', borderRadius: 10, padding: '12px 14px', alignItems: 'flex-start' }}>
                      <Checkbox checked={Boolean(accepted[f.id])} onChange={(value) => setOne(f.id, value)} ariaLabel={`Accept: ${f.title}`} style={{ marginTop: 1 }} />
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                        <div style={{ fontSize: 13.5, fontWeight: 600 }}>{f.title}</div>
                        {f.detail && <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>{f.detail}</div>}
                        {f.confidence != null && (
                          <div style={{ fontSize: 11.5, color: '#8A97A8' }}>{pct(f.confidence)} conf.</div>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              )}
              <Pressable
                onClick={() => setAccepted(Object.fromEntries(chart.findings.map((f) => [f.id, true])))}
                title={LOCAL_ONLY}
                aria-disabled={allAccepted || undefined}
                style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '10px 0', textAlign: 'center', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}
              >
                Accept all &amp; add to plan
              </Pressable>
            </div>
            {leadScore && chart.trajectory.length > 1 && (
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12 }}>
                <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>{RISK_TYPE_LABEL[leadScore.risk_type]} · history</h2>
                <div
                  role="img"
                  aria-label={`${RISK_TYPE_LABEL[leadScore.risk_type]} over the last ${chart.trajectory.length} recorded runs: ${chart.trajectory.map((s) => pct(s.probability)).join(', ')}.`}
                  style={{ display: 'flex', alignItems: 'flex-end', gap: 6, height: 120 }}
                >
                  {chart.trajectory.map((s) => {
                    const v = pct(s.probability);
                    const tone =
                      s.band === 'high' || s.band === 'critical'
                        ? '#B42318'
                        : s.band === 'medium'
                          ? '#E38B80'
                          : '#C9D8FA';
                    return (
                      <div key={s.id} title={`${shortDate(s.as_of)} ${timeLabel(s.as_of)} — ${v}`} style={{ flex: 1, background: tone, borderRadius: '4px 4px 0 0', height: `${Math.max(4, Math.round((s.probability ?? 0) * 100))}%`, minHeight: 6 }} />
                    );
                  })}
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, color: '#5B6B7F' }}>
                  <div>{shortDate(chart.trajectory[0].as_of)}</div>
                  <div>Now</div>
                </div>
              </div>
            )}
            <Pressable onClick={() => navigate('/doctor/ai-assistant')} className="on-dark" style={{ background: '#0F1C2E', borderRadius: 12, padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 8, color: '#fff', cursor: 'pointer' }}>
              <div style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF' }}>ASK THE AI</div>
              <div style={{ fontSize: 13.5, color: '#C7D2E4', lineHeight: 1.5 }}>"Why did this risk move?" — ask follow-up questions about this prediction.</div>
            </Pressable>
          </div>
        </div>
      </div>
    </div>
  );
}
