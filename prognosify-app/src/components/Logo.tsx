import type { CSSProperties } from 'react';
import glyphBlueSrc from '../assets/logo-glyph.png';
import glyphWhiteSrc from '../assets/logo-glyph-white.png';
import framedBlueSrc from '../assets/logo-framed.png';
import framedWhiteSrc from '../assets/logo-framed-white.png';

/**
 * Single owner of the Prognosify brand mark.
 *
 * The four assets are the supplied brand artwork with its flat background keyed
 * out (shapes untouched, background made transparent) — see the three source
 * files in /brand. Swapping in new artwork is a one-file change: repoint these
 * imports and every lockup in the app follows.
 *
 * The bare glyph is TALLER THAN WIDE (205x236, aspect 0.869), so `size` sets the
 * mark's HEIGHT and the width follows from the intrinsic aspect ratio. Forcing a
 * square box here would squash the mark.
 */
export const logoGlyphBlueSrc: string = glyphBlueSrc;
export const logoGlyphWhiteSrc: string = glyphWhiteSrc;
export const logoFramedBlueSrc: string = framedBlueSrc;
export const logoFramedWhiteSrc: string = framedWhiteSrc;

export const BRAND_BLUE = '#1D4ED8';

/** `white` picks the reversed artwork, for dark surfaces such as the #0F1C2E panel. */
export type LogoTone = 'blue' | 'white';

const srcFor = (tone: LogoTone, framed: boolean) =>
  framed
    ? tone === 'white'
      ? logoFramedWhiteSrc
      : logoFramedBlueSrc
    : tone === 'white'
      ? logoGlyphWhiteSrc
      : logoGlyphBlueSrc;

type LogoProps = {
  /** Height of the mark in px; width follows the artwork's aspect ratio. */
  size?: number;
  tone?: LogoTone;
  /** Use the rounded-square framed lockup instead of the bare glyph. */
  framed?: boolean;
  showWordmark?: boolean;
  wordmarkSize?: number;
  wordmarkWeight?: number;
  /** Omit to inherit the surrounding text colour. */
  wordmarkColor?: string;
  /** Space between mark and wordmark, in px. */
  gap?: number;
  /** Merged onto the lockup wrapper (e.g. padding). */
  style?: CSSProperties;
};

/** The mark on its own, no wordmark. */
export function LogoMark({
  size = 26,
  tone = 'blue',
  framed = false,
  alt = 'Prognosify',
  style,
}: {
  size?: number;
  tone?: LogoTone;
  framed?: boolean;
  alt?: string;
  style?: CSSProperties;
}) {
  return (
    <img
      src={srcFor(tone, framed)}
      alt={alt}
      style={{ display: 'block', height: size, width: 'auto', flexShrink: 0, ...style }}
    />
  );
}

export default function Logo({
  size = 26,
  tone = 'blue',
  framed = false,
  showWordmark = true,
  wordmarkSize = 15,
  wordmarkWeight = 600,
  wordmarkColor,
  gap = 8,
  style,
}: LogoProps) {
  if (!showWordmark) {
    return <LogoMark size={size} tone={tone} framed={framed} style={style} />;
  }
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap, ...style }}>
      {/* The wordmark names the lockup, so the mark itself is decorative here. */}
      <LogoMark size={size} tone={tone} framed={framed} alt="" />
      <div
        style={{
          fontSize: wordmarkSize,
          fontWeight: wordmarkWeight,
          ...(wordmarkColor ? { color: wordmarkColor } : null),
        }}
      >
        Prognosify
      </div>
    </div>
  );
}
