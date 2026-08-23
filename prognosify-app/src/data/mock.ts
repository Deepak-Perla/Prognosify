import type { CSSProperties } from 'react';

/**
 * Shared status-chip styles.
 *
 * These started life inside a file of hardcoded demo rows; every row is gone now that all
 * screens read from Supabase, but the chip vocabulary survived because it is presentation,
 * not data: red = high/critical, amber = medium/abnormal, green = low/normal.
 */
export const chip = (bg: string, fg: string, bd: string): CSSProperties => ({
  background: bg,
  color: fg,
  border: `1px solid ${bd}`,
  borderRadius: 12,
  padding: '3px 10px',
  fontSize: 12,
  fontWeight: 600,
});

export const hiChip = chip('#FEF5F4', '#B42318', '#F1D3D0');
export const medChip = chip('#FEFAF0', '#B54708', '#F3E3C2');
export const lowChip = chip('#F0F7F2', '#116B3F', '#CFE6D8');
