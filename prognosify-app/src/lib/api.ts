import type { PostgrestError } from '@supabase/supabase-js';
import { supabase } from './supabase';
import { dayBounds, todayKey, weekBounds } from './format';

/**
 * Typed queries over the Prognosify schema.
 *
 * Reads go through the read-surface views the migrations define for exactly these screens
 * (v_patient_summary, v_checkin_queue, v_lab_review_queue, v_patient_timeline) or straight
 * through the owning tables. Every query runs as the signed-in user, so Row Level Security
 * decides what comes back: these functions shape data, they never widen access.
 */

function unwrap<T>(data: unknown, error: PostgrestError | null): T[] {
  if (error) throw new Error(error.message);
  return (data ?? []) as T[];
}

async function one<T>(data: unknown, error: PostgrestError | null): Promise<T | null> {
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as T[];
  return rows[0] ?? null;
}

/* ------------------------------------------------------------------ shared row types ---- */

export type Band = 'low' | 'medium' | 'high' | 'critical';

export type RiskType =
  | 'sepsis'
  | 'icu_transfer'
  | 'length_of_stay'
  | 'readmission_30d'
  | 'post_op_infection'
  | 'glycemic_control';

export const RISK_TYPE_LABEL: Record<RiskType, string> = {
  sepsis: 'Sepsis risk',
  icu_transfer: 'ICU transfer',
  length_of_stay: 'Est. length of stay',
  readmission_30d: '30-day readmission risk',
  post_op_infection: 'Post-op infection risk',
  glycemic_control: 'Glycemic control',
};

const BAND_ORDER: Record<Band, number> = { critical: 3, high: 2, medium: 1, low: 0 };

export interface PatientSummaryRow {
  patient_id: string;
  organization_id: string;
  mrn: string;
  full_name: string;
  age_years: number;
  sex: 'male' | 'female' | 'other' | 'undisclosed';
  status: string;
  current_encounter_class: string | null;
  current_room: string | null;
  admitted_at: string | null;
  is_inpatient: boolean;
  primary_condition: string | null;
  last_visit_at: string | null;
}

export interface RiskScoreRow {
  id: string;
  run_id: string;
  patient_id: string;
  risk_type: RiskType;
  value_kind: 'probability' | 'range';
  horizon: string | null;
  probability: number | null;
  range_low: number | null;
  range_high: number | null;
  unit: string | null;
  band: Band;
  change_points: number | null;
  change_note: string | null;
  baseline_low: number | null;
  baseline_high: number | null;
  baseline_label: string | null;
  as_of: string;
}

export interface RiskFactorRow {
  id: string;
  risk_score_id: string;
  label: string;
  weight: number;
  normalized_magnitude: number | null;
  display_order: number;
}

export interface FindingRow {
  id: string;
  kind: string;
  severity: string;
  title: string;
  detail: string;
  confidence: number | null;
  review_state: 'pending' | 'accepted' | 'rejected' | 'amended';
  chart_committed_at: string | null;
}

export interface AppointmentRow {
  id: string;
  provider_member_id: string | null;
  scheduled_start: string;
  scheduled_end: string;
  duration_minutes: number;
  status: 'booked' | 'waiting' | 'in_room' | 'done' | 'cancelled' | 'no_show';
  origin: 'scheduled' | 'walk_in';
  modality: 'in_person' | 'video' | 'phone';
  room_label: string | null;
  block_title: string | null;
  chief_complaint: string | null;
  queue_ticket: number | null;
  checked_in_at: string | null;
  confirmed_at: string | null;
  patient: { id: string; mrn: string; first_name: string; last_name: string } | null;
  visit_type: { name: string } | null;
  department: { id: string; name: string; daily_slot_capacity: number | null } | null;
  provider: { app_user: { full_name: string } | null } | null;
}

/**
 * The embeds every schedule/queue listing shares.
 *
 * Every FK here is COMPOSITE ((fk_id, organization_id)), which PostgREST will not resolve from
 * the column-name hint alone, and appointment reaches organization_member through TWO foreign
 * keys (provider + created_by). So each embed names its constraint explicitly:
 *   alias:table!constraint_name ( columns )
 */
const APPOINTMENT_SELECT = `
  id, provider_member_id, scheduled_start, scheduled_end, duration_minutes, status, origin,
  modality, room_label, block_title, chief_complaint, queue_ticket, checked_in_at, confirmed_at,
  patient:patient!appointment_patient_fk ( id, mrn, first_name, last_name ),
  visit_type:visit_type!appointment_visit_type_fk ( name ),
  department:department!appointment_department_fk ( id, name, daily_slot_capacity ),
  provider:organization_member!appointment_provider_fk ( app_user!organization_member_app_user_id_fkey ( full_name ) )
`;

export function appointmentTitle(a: AppointmentRow): string {
  if (a.block_title) return a.block_title;
  const who = a.patient ? `${a.patient.first_name} ${a.patient.last_name}` : 'Patient';
  const what = a.visit_type?.name ?? (a.origin === 'walk_in' ? 'Walk-in' : 'Visit');
  return `${who} — ${what}`;
}

export function providerName(a: AppointmentRow): string {
  return a.provider?.app_user?.full_name ?? 'Unassigned';
}

/** The signed-in user's display name from app_user (for greetings and initials). */
export async function getMyFullName(): Promise<string | null> {
  const { data: userData } = await supabase.auth.getUser();
  const uid = userData.user?.id;
  if (!uid) return null;
  const { data } = await supabase
    .from('app_user')
    .select('full_name')
    .eq('auth_user_id', uid)
    .limit(1);
  return ((data ?? []) as { full_name: string | null }[])[0]?.full_name ?? null;
}

/** A patient's most recent appointments (front desk sees these org-wide; patients, their own). */
export async function getPatientRecentAppointments(patientId: string): Promise<AppointmentRow[]> {
  const { data, error } = await supabase
    .from('appointment')
    .select(APPOINTMENT_SELECT)
    .eq('patient_id', patientId)
    .neq('status', 'cancelled')
    .order('scheduled_start', { ascending: false })
    .limit(10);
  return unwrap<AppointmentRow>(data, error);
}

/* ------------------------------------------------------------------------ patients ------ */

export async function getPatientSummaries(): Promise<PatientSummaryRow[]> {
  const { data, error } = await supabase
    .from('v_patient_summary')
    .select('*')
    .order('full_name');
  return unwrap<PatientSummaryRow>(data, error);
}

export async function getPatientSummaryByMrn(mrn: string): Promise<PatientSummaryRow | null> {
  const { data, error } = await supabase
    .from('v_patient_summary')
    .select('*')
    .eq('mrn', mrn)
    .limit(1);
  return one<PatientSummaryRow>(data, error);
}

/** Latest score per patient, most recent assessment first. */
export async function getLatestRiskScores(): Promise<RiskScoreRow[]> {
  const { data, error } = await supabase
    .from('ai_risk_score')
    .select(
      'id, run_id, patient_id, risk_type, value_kind, horizon, probability, range_low, range_high,' +
        ' unit, band, change_points, change_note, baseline_low, baseline_high, baseline_label, as_of',
    )
    .order('as_of', { ascending: false });
  const all = unwrap<RiskScoreRow>(data, error);
  const latestPerType = new Map<string, Map<RiskType, RiskScoreRow>>();
  for (const row of all) {
    let perType = latestPerType.get(row.patient_id);
    if (!perType) latestPerType.set(row.patient_id, (perType = new Map()));
    if (!perType.has(row.risk_type)) perType.set(row.risk_type, row);
  }
  // One chip per patient: the most recent of their worst current scores.
  const out: RiskScoreRow[] = [];
  for (const perType of latestPerType.values()) {
    const worst = [...perType.values()].sort((a, b) => BAND_ORDER[b.band] - BAND_ORDER[a.band]);
    out.push(worst[0]);
  }
  return out.sort((a, b) => b.as_of.localeCompare(a.as_of));
}

/* ---------------------------------------------------------------------- scheduling ------ */

export async function getAppointmentsBetween(startISO: string, endISO: string): Promise<AppointmentRow[]> {
  const { data, error } = await supabase
    .from('appointment')
    .select(APPOINTMENT_SELECT)
    .gte('scheduled_start', startISO)
    .lt('scheduled_start', endISO)
    .neq('status', 'cancelled')
    .order('scheduled_start');
  return unwrap<AppointmentRow>(data, error);
}

export function todayAppointments(): Promise<AppointmentRow[]> {
  const { startISO, endISO } = dayBounds(todayKey());
  return getAppointmentsBetween(startISO, endISO);
}

export function weekAppointments(dayKeyStr?: string): Promise<AppointmentRow[]> {
  const { startISO, endISO } = weekBounds(dayKeyStr ?? todayKey());
  return getAppointmentsBetween(startISO, endISO);
}

export interface CheckinQueueRow {
  appointment_id: string;
  queue_date: string;
  queue_ticket: number | null;
  status: AppointmentRow['status'];
  scheduled_start: string;
  modality: string;
  origin: string;
  room_label: string | null;
  chief_complaint: string | null;
  patient_id: string | null;
  mrn: string | null;
  patient_name: string | null;
  provider_name: string | null;
  department_name: string | null;
  visit_type_name: string | null;
  checked_in_at: string | null;
  waiting_minutes: number | null;
}

export async function getCheckinQueue(dayKeyStr?: string): Promise<CheckinQueueRow[]> {
  const { startISO, endISO } = dayBounds(dayKeyStr ?? todayKey());
  const { data, error } = await supabase
    .from('v_checkin_queue')
    .select('*')
    .gte('scheduled_start', startISO)
    .lt('scheduled_start', endISO)
    .order('queue_ticket');
  return unwrap<CheckinQueueRow>(data, error);
}

/** Front-desk lifecycle writes. The DB trigger stamps checked_in_at / roomed_at itself. */
export async function setAppointmentStatus(id: string, status: 'waiting' | 'in_room'): Promise<void> {
  const { error } = await supabase.from('appointment').update({ status }).eq('id', id);
  if (error) throw new Error(error.message);
}

/** The portal Confirm button: patients may stamp confirmed_at on their own appointment only. */
export async function confirmMyAppointment(id: string): Promise<void> {
  const { error } = await supabase
    .from('appointment')
    .update({ confirmed_at: new Date().toISOString() })
    .eq('id', id);
  if (error) throw new Error(error.message);
}

export interface BookingProvider {
  member_id: string;
  specialty: string | null;
  default_room: string | null;
  department_name: string | null;
  full_name: string;
}

export async function getBookingProviders(): Promise<BookingProvider[]> {
  const { data, error } = await supabase
    .from('staff_profile')
    .select(
      'member_id, specialty, default_room,' +
        ' department:department!staff_profile_department_fk ( name ),' +
        ' member:organization_member!staff_profile_member_fk ( app_user!organization_member_app_user_id_fkey ( full_name ) )',
    )
    .eq('accepts_bookings', true);
  const rows = unwrap<{
    member_id: string;
    specialty: string | null;
    default_room: string | null;
    department: { name: string } | null;
    member: { app_user: { full_name: string } | null } | null;
  }>(data, error);
  return rows.map((r) => ({
    member_id: r.member_id,
    specialty: r.specialty,
    default_room: r.default_room,
    department_name: r.department?.name ?? null,
    full_name: r.member?.app_user?.full_name ?? 'Unknown provider',
  }));
}

export interface VisitTypeRow {
  id: string;
  name: string;
  default_duration_minutes: number;
  default_modality: 'in_person' | 'video' | 'phone';
}

export async function getVisitTypes(): Promise<VisitTypeRow[]> {
  const { data, error } = await supabase
    .from('visit_type')
    .select('id, name, default_duration_minutes, default_modality')
    .order('name');
  return unwrap<VisitTypeRow>(data, error);
}

export interface DepartmentRow {
  id: string;
  name: string;
  daily_slot_capacity: number | null;
}

export async function getDepartments(): Promise<DepartmentRow[]> {
  const { data, error } = await supabase
    .from('department')
    .select('id, name, daily_slot_capacity')
    .eq('is_active', true)
    .order('name');
  return unwrap<DepartmentRow>(data, error);
}

export interface NewAppointment {
  patientId: string;
  providerMemberId: string;
  departmentId?: string | null;
  visitTypeId?: string | null;
  startISO: string;
  endISO: string;
  roomLabel?: string | null;
  chiefComplaint?: string | null;
  modality?: 'in_person' | 'video' | 'phone';
}

/** Front-desk booking. The double-booking exclusion constraint rejects collisions server-side. */
export async function createAppointment(input: NewAppointment): Promise<string> {
  const ctx = await myStaffContext();
  if (!ctx) throw new Error('No active staff seat — sign in again.');
  const { data, error } = await supabase
    .from('appointment')
    .insert({
      organization_id: ctx.organizationId,
      created_by: ctx.memberId,
      patient_id: input.patientId,
      provider_member_id: input.providerMemberId,
      department_id: input.departmentId,
      visit_type_id: input.visitTypeId,
      modality: input.modality ?? 'in_person',
      origin: 'scheduled',
      status: 'booked',
      room_label: input.roomLabel ?? null,
      chief_complaint: input.chiefComplaint ?? null,
      scheduled_start: input.startISO,
      scheduled_end: input.endISO,
    })
    .select('id')
    .single();
  if (error) throw new Error(error.message);
  return (data as { id: string }).id;
}

export interface StaffContext {
  authUserId: string;
  organizationId: string;
  memberId: string;
}

/**
 * The signed-in user's seat: org + member id, resolved from app_user.active_organization_id and
 * the live membership — the same resolution the server-side helpers do from the JWT.
 */
export async function myStaffContext(): Promise<StaffContext | null> {
  const { data: userData } = await supabase.auth.getUser();
  const authUserId = userData.user?.id;
  if (!authUserId) return null;
  const { data, error } = await supabase
    .from('app_user')
    .select(
      'active_organization_id,' +
        // organization_member is reachable from app_user through THREE foreign keys
        // (app_user_id, the (app_user_id, auth_user_id) pair, and created_by) — name the one
        // that means "this person's seats".
        ' members:organization_member!organization_member_app_user_id_fkey ( id, status )',
    )
    .eq('auth_user_id', authUserId)
    .limit(1);
  if (error || !data?.length) return null;
  const row = data[0] as unknown as {
    active_organization_id: string | null;
    members: { id: string; status: string }[] | null;
  } | null;
  const organizationId = row?.active_organization_id ?? null;
  const member = (row?.members ?? []).find((m) => m.status === 'active') ?? null;
  if (!organizationId || !member) return null;
  return { authUserId, organizationId, memberId: member.id };
}

/* ------------------------------------------------------------------ front-desk register -- */

export interface FrontDeskPatient {
  patient_id: string;
  mrn: string;
  first_name: string;
  last_name: string;
  date_of_birth: string;
  age_years: number;
  sex: string;
  phone: string | null;
  email: string | null;
  status: string;
}

/** Real duplicate check: matching date of birth, or matching last+first spelling. */
export async function findPossibleDuplicates(lastName: string, dob: string): Promise<FrontDeskPatient[]> {
  const cols = 'patient_id, mrn, first_name, last_name, date_of_birth, age_years, sex, phone, email, status';
  const results = new Map<string, FrontDeskPatient>();
  const collect = (res: { data: unknown; error: PostgrestError | null }) => {
    for (const row of unwrap<FrontDeskPatient>(res.data, res.error)) {
      if (row.status !== 'merged') results.set(row.patient_id, row);
    }
  };

  const byLastName = lastName.trim()
    ? await supabase.from('v_front_desk_patient').select(cols).ilike('last_name', lastName.trim()).limit(4)
    : null;
  if (byLastName) collect(byLastName);

  if (isValidDob(dob)) {
    const byDob = await supabase
      .from('v_front_desk_patient')
      .select(cols)
      .eq('date_of_birth', dob.trim())
      .limit(4);
    collect(byDob);
  }

  return [...results.values()].slice(0, 3);
}

/** Booking/Register search over the administrative patient view. */
export async function searchFrontDeskPatients(query: string): Promise<FrontDeskPatient[]> {
  const needle = query.trim();
  if (!needle) return [];
  const cols = 'patient_id, mrn, first_name, last_name, date_of_birth, age_years, sex, phone, email, status';
  const { data, error } = await supabase
    .from('v_front_desk_patient')
    .select(cols)
    .or(`first_name.ilike.%${needle}%,last_name.ilike.%${needle}%,mrn.ilike.%${needle}%`)
    .limit(6);
  return unwrap<FrontDeskPatient>(data, error);
}

export function isValidDob(dob: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(dob.trim());
}

const SEX_TO_ENUM: Record<string, 'male' | 'female' | 'other' | 'undisclosed'> = {
  Male: 'male',
  Female: 'female',
  Other: 'other',
  'Prefer not to say': 'undisclosed',
};

export function toSexEnum(label: string): 'male' | 'female' | 'other' | 'undisclosed' {
  return SEX_TO_ENUM[label] ?? 'undisclosed';
}

/** MRNs are allocated by the app ("104-882" style), unique per tenant — retry on collision. */
export async function registerPatient(input: {
  firstName: string;
  lastName: string;
  dob: string;
  sex: 'male' | 'female' | 'other' | 'undisclosed';
  phone: string | null;
  email: string | null;
}): Promise<string> {
  const ctx = await myStaffContext();
  if (!ctx) throw new Error('No active staff seat — sign in again.');

  const { data: existing } = await supabase
    .from('patient')
    .select('mrn')
    .eq('organization_id', ctx.organizationId);
  const taken = new Set(((existing ?? []) as { mrn: string }[]).map((r) => r.mrn.toUpperCase()));

  for (let attempt = 0; attempt < 5; attempt++) {
    const mrn = `${String(100 + Math.floor(Math.random() * 900))}-${String(100 + Math.floor(Math.random() * 900))}`;
    if (taken.has(mrn)) continue;
    const { data, error } = await supabase
      .from('patient')
      .insert({
        organization_id: ctx.organizationId,
        mrn,
        first_name: input.firstName.trim(),
        last_name: input.lastName.trim(),
        date_of_birth: input.dob,
        sex: input.sex,
        phone: input.phone,
        email: input.email,
        status: 'active',
      })
      .select('mrn')
      .single();
    if (!error) return (data as { mrn: string }).mrn;
    if (!error.message.includes('duplicate key')) throw new Error(error.message);
  }
  throw new Error('Could not allocate an MRN — please retry.');
}

/* -------------------------------------------------------------------------- billing ----- */

export interface InvoiceRow {
  id: string;
  number: string;
  status:
    | 'copay_due'
    | 'auth_missing'
    | 'covered'
    | 'overdue'
    | 'draft'
    | 'paid'
    | 'written_off'
    | 'void';
  currency: string;
  total_minor: number;
  patient_due_minor: number;
  due_at: string | null;
  prior_auth_required: boolean;
  denial_risk_flag: boolean;
  denial_risk_note: string | null;
  patient: { mrn: string; first_name: string; last_name: string; phone: string | null } | null;
  lines: { description: string; amount_minor: number }[];
  payments: { amount_minor: number; received_at: string }[];
}

export async function getInvoices(): Promise<InvoiceRow[]> {
  const { data, error } = await supabase
    .from('invoice')
    .select(
      `id, number, status, currency, total_minor, patient_due_minor, due_at,
       prior_auth_required, denial_risk_flag, denial_risk_note,
       patient:patient!invoice_patient_fk ( mrn, first_name, last_name, phone ),
       lines:invoice_line!invoice_line_invoice_fk ( description, amount_minor ),
       payments:payment!payment_invoice_fk ( amount_minor, received_at )`,
    )
    .neq('status', 'draft')
    .order('due_at', { ascending: true });
  return unwrap<InvoiceRow>(data, error);
}

export const paidMinor = (inv: InvoiceRow): number =>
  inv.payments.reduce((sum, p) => sum + Number(p.amount_minor), 0);

export const balanceMinor = (inv: InvoiceRow): number =>
  inv.patient_due_minor - paidMinor(inv);

/* --------------------------------------------------------------------------- labs ------- */

export interface LabQueueRow {
  lab_result_id: string;
  patient_id: string;
  patient_name: string;
  panel_name: string;
  test_name: string;
  value_numeric: number | null;
  value_text: string | null;
  unit: string | null;
  reference_range: string;
  abnormal_flag: string;
  review_status: 'unreviewed' | 'acknowledged' | 'reviewed';
  resulted_at: string;
}

export async function getLabReviewQueue(): Promise<LabQueueRow[]> {
  const { data, error } = await supabase
    .from('v_lab_review_queue')
    .select('*')
    .order('resulted_at', { ascending: false })
    .limit(50);
  return unwrap<LabQueueRow>(data, error);
}

export interface ReleasedResultRow {
  id: string;
  value_numeric: number | null;
  value_text: string | null;
  unit: string | null;
  abnormal_flag: string;
  resulted_at: string;
  test: { name: string };
}

/** Patient portal results: RLS additionally requires released_to_patient_at to be set. */
export async function getReleasedResults(): Promise<ReleasedResultRow[]> {
  const { data, error } = await supabase
    .from('lab_result')
    .select(
      'id, value_numeric, value_text, unit, abnormal_flag, resulted_at,' +
        ' test:lab_test!lab_result_test_fk ( name )',
    )
    .not('released_to_patient_at', 'is', null)
    .order('resulted_at', { ascending: false });
  return unwrap<ReleasedResultRow & { test: { name: string } | null }>(data, error).map((r) => ({
    ...r,
    test: r.test ?? { name: 'Result' },
  }));
}

/** The signed-in patient's active prescriptions (RLS scopes this to their own chart). */
export async function getMyMedications(): Promise<MedicationRow[]> {
  const { data, error } = await supabase
    .from('medication_order')
    .select('id, drug_name, dose_text, frequency_text, status, refill_requested_at')
    .eq('status', 'active')
    .order('started_at', { ascending: false });
  return unwrap<MedicationRow>(data, error);
}

/** The signed-in patient's own upcoming appointments, soonest first. */
export async function getMyUpcomingAppointments(): Promise<AppointmentRow[]> {
  const { startISO, endISO } = weekBounds(todayKey());
  const endFar = new Date(new Date(endISO).getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await supabase
    .from('appointment')
    .select(APPOINTMENT_SELECT)
    .gte('scheduled_start', startISO)
    .lt('scheduled_start', endFar)
    .in('status', ['booked', 'waiting'])
    .order('scheduled_start')
    .limit(5);
  return unwrap<AppointmentRow>(data, error);
}

/* ------------------------------------------------------------------- patient chart ------ */

export interface VitalRow {
  measured_at: string;
  heart_rate_bpm: number | null;
  systolic_mmhg: number | null;
  diastolic_mmhg: number | null;
  temperature_c: number | null;
  spo2_percent: number | null;
  supplemental_o2: string | null;
}

export interface AllergyRow {
  id: string;
  substance: string;
  severity: string;
}

export interface MedicationRow {
  id: string;
  drug_name: string;
  dose_text: string;
  frequency_text: string;
  status: string;
  refill_requested_at: string | null;
}

export interface CareTeamRow {
  id: string;
  role: string;
  assignment_note: string | null;
  ended_at: string | null;
  member: { roles: string[]; app_user: { full_name: string } | null } | null;
}

export interface TimelineRow {
  occurred_at: string;
  entry_kind: string;
  entry_subtype: string;
  summary: string;
  source_table: string;
  source_id: string;
}

export interface AnalysisRunInfo {
  model_version: string | null;
  status: string;
  created_at: string;
}

export interface PatientChart {
  vitals: VitalRow | null;
  allergies: AllergyRow[];
  conditions: { id: string; name: string; clinical_status: string; is_primary: boolean }[];
  medications: MedicationRow[];
  careTeam: CareTeamRow[];
  timeline: TimelineRow[];
  recentLabs: LabQueueRow[];
  riskScores: RiskScoreRow[];
  findings: FindingRow[];
  factors: RiskFactorRow[];
  trajectory: RiskScoreRow[];
  run: AnalysisRunInfo | null;
}

export async function getPatientChart(patientId: string): Promise<PatientChart> {
  const [vitalsRes, allergyRes, condRes, medRes, teamRes, timelineRes, labsRes, scoreRes, findingRes] =
    await Promise.all([
      supabase
        .from('vital_sign')
        .select(
          'measured_at, heart_rate_bpm, systolic_mmhg, diastolic_mmhg, temperature_c, spo2_percent, supplemental_o2',
        )
        .eq('patient_id', patientId)
        .order('measured_at', { ascending: false })
        .limit(1),
      supabase
        .from('patient_allergy')
        .select('id, substance, severity')
        .eq('patient_id', patientId)
        .is('inactivated_at', null),
      supabase
        .from('patient_condition')
        .select('id, name, clinical_status, is_primary')
        .eq('patient_id', patientId)
        .eq('record_status', 'active'),
      supabase
        .from('medication_order')
        .select('id, drug_name, dose_text, frequency_text, status, refill_requested_at')
        .eq('patient_id', patientId)
        .eq('record_status', 'active')
        .neq('status', 'discontinued')
        .order('started_at', { ascending: false }),
      supabase
        .from('care_team_member')
        .select(
          'id, role, assignment_note, ended_at,' +
            ' member:organization_member!care_team_member_fk ( roles, app_user!organization_member_app_user_id_fkey ( full_name ) )',
        )
        .eq('patient_id', patientId)
        .is('ended_at', null),
      supabase
        .from('v_patient_timeline')
        .select('occurred_at, entry_kind, entry_subtype, summary, source_table, source_id')
        .eq('patient_id', patientId)
        .order('occurred_at', { ascending: false })
        .limit(8),
      supabase
        .from('v_lab_review_queue')
        .select('*')
        .eq('patient_id', patientId)
        .order('resulted_at', { ascending: false })
        .limit(6),
      supabase
        .from('ai_risk_score')
        .select(
          'id, run_id, patient_id, risk_type, value_kind, horizon, probability, range_low, range_high,' +
            ' unit, band, change_points, change_note, baseline_low, baseline_high, baseline_label, as_of',
        )
        .eq('patient_id', patientId)
        .order('as_of', { ascending: false }),
      supabase
        .from('ai_finding')
        .select('id, kind, severity, title, detail, confidence, review_state, chart_committed_at')
        .eq('patient_id', patientId)
        .order('display_order'),
    ]);

  const scores = unwrap<RiskScoreRow>(scoreRes.data, scoreRes.error);

  // Latest run wins: the report is what that run produced, not a mix of runs.
  const latestRun = scores[0]?.run_id ?? null;
  const current = scores.filter((s) => s.run_id === latestRun);
  const trajectoryType =
    current.find((c) => c.value_kind === 'probability')?.risk_type ?? null;

  const scoreIds = current.map((s) => s.id);
  let factors: RiskFactorRow[] = [];
  if (scoreIds.length > 0) {
    const { data: fData, error: fError } = await supabase
      .from('ai_risk_factor')
      .select('id, risk_score_id, label, weight, normalized_magnitude, display_order')
      .in('risk_score_id', scoreIds)
      .order('display_order');
    factors = unwrap<RiskFactorRow>(fData, fError);
  }

  const trajectory = trajectoryType
    ? scores
        .filter((s) => s.risk_type === trajectoryType && s.value_kind === 'probability')
        .sort((a, b) => a.as_of.localeCompare(b.as_of))
        .slice(-7)
    : [];

  let run: AnalysisRunInfo | null = null;
  if (latestRun) {
    const { data: rData, error: rError } = await supabase
      .from('ai_analysis_run')
      .select('model_version, status, created_at')
      .eq('id', latestRun)
      .limit(1);
    run = (unwrap<AnalysisRunInfo>(rData, rError)[0] as AnalysisRunInfo | undefined) ?? null;
  }

  return {
    vitals:
      (unwrap<VitalRow>(vitalsRes.data, vitalsRes.error)[0] as VitalRow | undefined) ?? null,
    allergies: unwrap<AllergyRow>(allergyRes.data, allergyRes.error),
    conditions: unwrap<{ id: string; name: string; clinical_status: string; is_primary: boolean }>(condRes.data, condRes.error),
    medications: unwrap<MedicationRow>(medRes.data, medRes.error),
    careTeam: unwrap<CareTeamRow>(teamRes.data, teamRes.error).map((r) => ({
      ...r,
      member: r.member ?? null,
    })),
    timeline: unwrap<TimelineRow>(timelineRes.data, timelineRes.error),
    recentLabs: unwrap<LabQueueRow>(labsRes.data, labsRes.error),
    riskScores: current,
    findings: unwrap<FindingRow>(findingRes.data, findingRes.error).filter(
      (f) => f.kind === 'recommended_action',
    ),
    factors,
    trajectory,
    run,
  };
}

/* ==================================================================== */
/*  Portal + write flows (060_portal_flows and the existing tables)     */
/* ==================================================================== */

// ---- doctor writes -------------------------------------------------------------

export async function addClinicalNote(input: {
  organizationId: string;
  patientId: string;
  authorMemberId: string;
  body: string;
}): Promise<void> {
  const now = new Date().toISOString();
  const { error } = await supabase.from('clinical_note').insert({
    organization_id: input.organizationId,
    patient_id: input.patientId,
    author_member_id: input.authorMemberId,
    note_type: 'progress',
    body: input.body.trim(),
    occurred_at: now,
    signed_at: now,
  });
  if (error) throw new Error(error.message);
}

export interface LabPanelRow {
  id: string;
  name: string;
}

export async function getLabPanels(): Promise<LabPanelRow[]> {
  const { data, error } = await supabase
    .from('lab_panel')
    .select('id, name')
    .order('name');
  return unwrap<LabPanelRow>(data, error);
}

export async function orderLab(input: {
  organizationId: string;
  patientId: string;
  panelId: string;
  orderedByMemberId: string;
  priority: 'routine' | 'urgent' | 'stat';
}): Promise<void> {
  const { error } = await supabase.from('lab_order').insert({
    organization_id: input.organizationId,
    patient_id: input.patientId,
    panel_id: input.panelId,
    ordered_by: input.orderedByMemberId,
    priority: input.priority,
    status: 'ordered',
  });
  if (error) throw new Error(error.message);
}

export async function acceptFinding(
  findingId: string,
  organizationId: string,
  memberId: string,
): Promise<void> {
  const { error } = await supabase
    .from('ai_finding')
    .update({
      review_state: 'accepted',
      reviewed_by_member_id: memberId,
      reviewed_at: new Date().toISOString(),
    })
    .eq('id', findingId)
    .eq('organization_id', organizationId)
    .eq('review_state', 'pending');
  // .eq on review_state makes the accept idempotent; a second click is a no-op.
  if (error && !error.message.includes('0 rows')) throw new Error(error.message);
}

export async function commitFindingToChart(
  findingId: string,
  organizationId: string,
  memberId: string,
): Promise<void> {
  const now = new Date().toISOString();
  const { error } = await supabase
    .from('ai_finding')
    .update({ chart_committed_at: now, chart_committed_by_member_id: memberId })
    .eq('id', findingId)
    .eq('organization_id', organizationId)
    .is('chart_committed_at', null);
  if (error && !error.message.includes('0 rows')) throw new Error(error.message);
}

// ---- reception billing writes ---------------------------------------------------

export const PAYMENT_METHODS = ['cash', 'card', 'upi', 'netbanking', 'cheque'] as const;
export type PaymentMethod = (typeof PAYMENT_METHODS)[number];

export async function recordPayment(input: {
  invoiceId: string;
  organizationId: string;
  amountMinor: number;
  method: PaymentMethod;
  receivedByMemberId: string;
}): Promise<void> {
  const { error } = await supabase.from('payment').insert({
    organization_id: input.organizationId,
    invoice_id: input.invoiceId,
    amount_minor: input.amountMinor,
    method: input.method,
    received_by: input.receivedByMemberId,
    received_at: new Date().toISOString(),
  });
  if (error) throw new Error(error.message);
}

/** Front-desk invoice updates: settle to paid, or clear an auth hold with the payer's ref. */
export async function updateInvoice(
  invoiceId: string,
  patch: { status?: InvoiceRow['status']; prior_auth_ref?: string | null },
): Promise<void> {
  const { error } = await supabase
    .from('invoice')
    .update(patch)
    .eq('id', invoiceId);
  if (error) throw new Error(error.message);
}

// ---- settings -------------------------------------------------------------------

export interface OrgSettingRow {
  key: string;
  value: unknown;
}

export async function getMySettings(memberId: string): Promise<Record<string, unknown>> {
  const { data, error } = await supabase
    .from('org_setting')
    .select('key, value')
    .eq('member_id', memberId);
  const rows = unwrap<OrgSettingRow>(data, error);
  return Object.fromEntries(rows.map((r) => [r.key, r.value]));
}

export async function saveMySetting(
  organizationId: string,
  memberId: string,
  key: string,
  value: unknown,
): Promise<void> {
  // org_setting keys its rows by uuid, not by (member, key), so resolve first.
  const existing = await supabase
    .from('org_setting')
    .select('id')
    .eq('member_id', memberId)
    .eq('key', key)
    .limit(1);
  if (existing.error) throw new Error(existing.error.message);
  const current = (existing.data ?? []) as { id: string }[];
  if (current.length > 0) {
    const { error } = await supabase
      .from('org_setting')
      .update({ value: value as never, updated_by: memberId })
      .eq('id', current[0].id);
    if (error) throw new Error(error.message);
  } else {
    const { error } = await supabase.from('org_setting').insert({
      organization_id: organizationId,
      member_id: memberId,
      key,
      value: value as never,
      updated_by: memberId,
    });
    if (error) throw new Error(error.message);
  }
}

// ---- patient portal: identity, care team, messages, care plan, booking ----------

export interface PortalMe {
  patient_id: string;
  mrn: string;
  full_name: string;
}

/** The signed-in patient's own chart identity (RLS-resolved server side). */
export async function getPortalIdentity(): Promise<PortalMe | null> {
  const { data, error } = await supabase.from('v_portal_me').select('*').limit(1);
  return one<PortalMe>(data, error);
}

export interface CareContact {
  member_id: string;
  full_name: string;
  role: string;
  assignment_note: string | null;
  specialty: string | null;
}

export async function getCareTeamContacts(): Promise<CareContact[]> {
  const { data, error } = await supabase
    .from('v_portal_care_team')
    .select('*')
    .order('full_name');
  return unwrap<CareContact>(data, error);
}

export interface MessageRow {
  id: string;
  sender_member_id: string | null;
  sent_by_patient: boolean;
  body: string;
  created_at: string;
}

export async function getThread(patientId: string): Promise<MessageRow[]> {
  const { data, error } = await supabase
    .from('message')
    .select('id, sender_member_id, sent_by_patient, body, created_at')
    .eq('patient_id', patientId)
    .order('created_at');
  return unwrap<MessageRow>(data, error);
}

export async function sendPatientMessage(patientId: string, organizationId: string, body: string): Promise<void> {
  const { error } = await supabase.from('message').insert({
    organization_id: organizationId,
    patient_id: patientId,
    sent_by_patient: true,
    body: body.trim(),
  });
  if (error) throw new Error(error.message);
}

export interface CareGoalRow {
  id: string;
  label: string;
  target_label: string | null;
  progress_pct: number;
}

export async function getCareGoals(patientId: string): Promise<CareGoalRow[]> {
  const { data, error } = await supabase
    .from('care_goal')
    .select('id, label, target_label, progress_pct')
    .eq('patient_id', patientId)
    .order('created_at');
  return unwrap<CareGoalRow>(data, error);
}

export interface CareTaskRow {
  id: string;
  title: string;
  detail: string | null;
  schedule_text: string | null;
  last_done_at: string | null;
}

export async function getCarePlanTasks(patientId: string): Promise<CareTaskRow[]> {
  const { data, error } = await supabase
    .from('care_plan_task')
    .select('id, title, detail, schedule_text, last_done_at')
    .eq('patient_id', patientId)
    .order('sort_order');
  return unwrap<CareTaskRow>(data, error);
}

export async function setTaskDone(taskId: string, done: boolean): Promise<void> {
  const { error } = await supabase
    .from('care_plan_task')
    .update({ last_done_at: done ? new Date().toISOString() : null })
    .eq('id', taskId);
  if (error) throw new Error(error.message);
}

/** The one column a patient may write on their prescriptions (trigger-enforced). */
export async function requestRefill(medicationId: string): Promise<void> {
  const { error } = await supabase
    .from('medication_order')
    .update({ refill_requested_at: new Date().toISOString() })
    .eq('id', medicationId);
  if (error) throw new Error(error.message);
}

// ---- portal booking ---------------------------------------------------------------

export interface SlotRow {
  slot_start: string;
  slot_end: string;
}

export async function getPortalSlots(providerMemberId: string): Promise<SlotRow[]> {
  const { data, error } = await supabase
    .rpc('portal_available_slots', { p_provider: providerMemberId });
  if (error) throw new Error(error.message);
  return (data ?? []) as SlotRow[];
}

export async function bookPortalSlot(
  providerMemberId: string,
  visitTypeId: string,
  startISO: string,
): Promise<string> {
  const { data, error } = await supabase.rpc('portal_book_appointment', {
    p_provider: providerMemberId,
    p_visit_type: visitTypeId,
    p_start: startISO,
  });
  if (error) throw new Error(error.message);
  return data as string;
}
