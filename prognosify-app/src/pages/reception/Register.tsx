import { useEffect, useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Pressable, TextArea, TextField } from '../../components/ui';
import {
  findPossibleDuplicates,
  isValidDob,
  registerPatient,
  toSexEnum,
  type FrontDeskPatient,
} from '../../lib/api';

/** UA neutraliser for a real <select>: no appearance, no chrome, inherits the spec's type. */
const selectReset: CSSProperties = {
  appearance: 'none',
  WebkitAppearance: 'none',
  fontFamily: 'inherit',
  fontSize: 'inherit',
  fontWeight: 'inherit',
  fontStyle: 'inherit',
  lineHeight: 'inherit',
  letterSpacing: 'inherit',
  textAlign: 'inherit',
  color: 'inherit',
  background: 'none',
  border: 0,
  borderRadius: 0,
  padding: 0,
  margin: 0,
  height: 'auto',
  maxWidth: '100%',
  cursor: 'pointer',
};

const fieldBox: CSSProperties = { border: '1px solid #DDE3EB', borderRadius: 8, padding: '10px 13px', fontSize: 14 };
const fieldLabel: CSSProperties = { fontSize: 13, fontWeight: 500 };
const column: CSSProperties = { display: 'flex', flexDirection: 'column', gap: 6 };

const sexOptions = ['Male', 'Female', 'Other', 'Prefer not to say'];

export default function Register() {
  const navigate = useNavigate();
  const [firstName, setFirstName] = useState('');
  const [lastName, setLastName] = useState('');
  const [dob, setDob] = useState('');
  const [sex, setSex] = useState(sexOptions[0]);
  const [phone, setPhone] = useState('');
  const [email, setEmail] = useState('');
  const [complaint, setComplaint] = useState('');

  const [duplicates, setDuplicates] = useState<FrontDeskPatient[]>([]);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedMrn, setSavedMrn] = useState<string | null>(null);

  // Real duplicate check against the hospital's own records as the desk types.
  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      if (!lastName.trim() && !isValidDob(dob)) {
        setDuplicates([]);
        return;
      }
      findPossibleDuplicates(lastName, dob)
        .then((rows) => !cancelled && setDuplicates(rows))
        .catch(() => !cancelled && setDuplicates([]));
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [firstName, lastName, dob]);

  const canSave =
    firstName.trim() !== '' && lastName.trim() !== '' && isValidDob(dob) && !saving && savedMrn === null;

  const save = async () => {
    if (!canSave) return;
    setSaving(true);
    setSaveError(null);
    try {
      const mrn = await registerPatient({
        firstName,
        lastName,
        dob: dob.trim(),
        sex: toSexEnum(sex),
        phone: phone.trim() || null,
        email: email.trim() || null,
      });
      setSavedMrn(mrn);
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Could not save the patient.');
    } finally {
      setSaving(false);
    }
  };

  const resetForAnother = () => {
    setFirstName('');
    setLastName('');
    setDob('');
    setSex(sexOptions[0]);
    setPhone('');
    setEmail('');
    setComplaint('');
    setSavedMrn(null);
    setSaveError(null);
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="register" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Register new patient</h1>
          <div role="group" aria-label="Registration progress: step 1 of 3, Identity" style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, color: '#5B6B7F' }}>
            <div style={{ color: '#1D4ED8', fontWeight: 600 }}>1 Identity</div><div>·</div><div>2 Insurance</div><div>·</div><div>3 Consent</div>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', justifyContent: 'center', padding: 28, overflow: 'auto' }}>
          <div style={{ width: 720, display: 'flex', flexDirection: 'column', gap: 20 }}>
            {savedMrn ? (
              <div role="status" style={{ background: '#ffffff', border: '1px solid #CFE6D8', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 12 }}>
                <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0, color: '#116B3F' }}>Registered ✓</h2>
                <div style={{ fontSize: 14, color: '#3A4A5E' }}>
                  {firstName} {lastName} saved with MRN <strong>{savedMrn}</strong>. The chart is now searchable everywhere in this hospital.
                </div>
                <div style={{ display: 'flex', gap: 10 }}>
                  <Pressable onClick={() => navigate('/reception/check-in')} style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '10px 18px', fontSize: 13.5, fontWeight: 600, cursor: 'pointer' }}>Back to queue</Pressable>
                  <Pressable onClick={resetForAnother} style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '10px 18px', fontSize: 13.5, fontWeight: 500, cursor: 'pointer' }}>Register another</Pressable>
                </div>
              </div>
            ) : (
              <>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
                  <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Identity</h2>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                    <div style={column}>
                      <TextField label="First name" labelStyle={fieldLabel} value={firstName} onChange={setFirstName} autoComplete="given-name" placeholder="Required" placeholderColor="#8A97A8" style={fieldBox} />
                    </div>
                    <div style={column}>
                      <TextField label="Last name" labelStyle={fieldLabel} value={lastName} onChange={setLastName} autoComplete="family-name" placeholder="Required" placeholderColor="#8A97A8" style={fieldBox} />
                    </div>
                    <div style={column}>
                      <TextField label="Date of birth" labelStyle={fieldLabel} type="date" value={dob} onChange={setDob} autoComplete="bday" style={fieldBox} />
                    </div>
                    <div style={column}>
                      <label htmlFor="register-sex" style={fieldLabel}>Sex</label>
                      <div style={{ ...fieldBox, display: 'flex', justifyContent: 'space-between' }}>
                        <select id="register-sex" value={sex} onChange={(e) => setSex(e.target.value)} style={selectReset}>
                          {sexOptions.map((o) => <option key={o} value={o}>{o}</option>)}
                        </select>
                        <span aria-hidden="true" style={{ color: '#5B6B7F' }}>▾</span>
                      </div>
                    </div>
                    <div style={column}>
                      <TextField label="Phone" labelStyle={fieldLabel} type="tel" value={phone} onChange={setPhone} autoComplete="tel" placeholder="Optional" placeholderColor="#8A97A8" style={fieldBox} />
                    </div>
                    <div style={column}>
                      <TextField label="Email" labelStyle={fieldLabel} type="email" value={email} onChange={setEmail} autoComplete="email" placeholder="optional" placeholderColor="#8A97A8" style={fieldBox} />
                    </div>
                  </div>
                  {duplicates.length > 0 && (
                    <div style={{ background: '#FEFAF0', border: '1px solid #F3E3C2', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#7A5A0B', lineHeight: 1.6 }}>
                      <span style={{ fontWeight: 600 }}>Possible duplicate{duplicates.length > 1 ? 's' : ''}:</span>{' '}
                      {duplicates.map((p) => (
                        <span key={p.patient_id}>
                          {p.first_name} {p.last_name}, DOB {p.date_of_birth}, MRN {p.mrn}.{' '}
                        </span>
                      ))}
                      Check these records before saving — a merged duplicate is much harder to undo later.
                    </div>
                  )}
                </div>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
                  <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Visit reason</h2>
                  <div style={column}>
                    <TextArea
                      label="Chief complaint"
                      labelStyle={fieldLabel}
                      rows={1}
                      value={complaint}
                      onChange={setComplaint}
                      placeholder="Why is the patient here today? (stored with their first booking)"
                      placeholderColor="#8A97A8"
                      style={{ ...fieldBox, minHeight: 56 }}
                    />
                  </div>
                </div>
                {saveError && (
                  <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 16px', fontSize: 13, color: '#B42318' }}>
                    Could not save: {saveError}
                  </div>
                )}
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <Pressable onClick={() => navigate('/reception/check-in')} title="Discards this form and returns to the check-in queue." style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '11px 20px', fontSize: 14, fontWeight: 500, cursor: 'pointer' }}>Cancel</Pressable>
                  <Pressable
                    onClick={() => void save()}
                    disabled={!canSave}
                    aria-disabled={!canSave || undefined}
                    title={
                      !isValidDob(dob)
                        ? 'Enter a date of birth (YYYY-MM-DD).'
                        : firstName.trim() === '' || lastName.trim() === ''
                          ? 'First and last name are required.'
                          : undefined
                    }
                    style={{
                      background: '#1D4ED8',
                      color: '#fff',
                      opacity: canSave ? 1 : 0.55,
                      borderRadius: 8,
                      padding: '11px 22px',
                      fontSize: 14,
                      fontWeight: 600,
                      cursor: canSave ? 'pointer' : 'not-allowed',
                    }}
                  >
                    {saving ? 'Saving…' : 'Save registration'}
                  </Pressable>
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
