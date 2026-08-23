import { useId, useRef, type AriaAttributes, type CSSProperties, type KeyboardEvent, type MouseEvent, type ReactNode } from 'react';

/**
 * Shared interactive primitives.
 *
 * Every primitive renders a real, keyboard-focusable, screen-reader-sensible element whose
 * user-agent styling has been neutralised, so it renders exactly like the `<div>` it replaces.
 * The caller's `style` is always spread LAST — the design spec keeps pixel control.
 */

/** UA neutraliser for `<button>`. Exported for the rare raw-element case. */
export const pressableReset: CSSProperties = {
  appearance: 'none',
  WebkitAppearance: 'none',
  display: 'block',
  alignItems: 'normal',
  fontFamily: 'inherit',
  fontSize: 'inherit',
  fontWeight: 'inherit',
  fontStyle: 'inherit',
  lineHeight: 'inherit',
  letterSpacing: 'inherit',
  whiteSpace: 'inherit',
  textAlign: 'inherit',
  color: 'inherit',
  background: 'none',
  border: 0,
  borderRadius: 0,
  padding: 0,
  margin: 0,
  cursor: 'pointer',
  WebkitTapHighlightColor: 'transparent',
};

/** UA neutraliser for `<input>` / `<textarea>`. Exported for the rare raw-element case. */
export const fieldReset: CSSProperties = {
  appearance: 'none',
  WebkitAppearance: 'none',
  display: 'block',
  boxSizing: 'border-box',
  width: '100%',
  minWidth: 0,
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
};

/** Field styles may carry the placeholder-colour custom property. */
type FieldStyle = CSSProperties & { '--ui-placeholder'?: string };

const joinClass = (...parts: (string | undefined)[]) => parts.filter(Boolean).join(' ');

const fieldStyleFor = (style?: CSSProperties, placeholderColor?: string, extra?: CSSProperties): FieldStyle => {
  const merged: FieldStyle = { ...fieldReset, ...extra, ...style };
  if (placeholderColor) merged['--ui-placeholder'] = placeholderColor;
  return merged;
};

/* ------------------------------------------------------------------ Pressable */

export type PressableProps = {
  onClick?: (event: MouseEvent<HTMLButtonElement>) => void;
  style?: CSSProperties;
  children?: ReactNode;
  disabled?: boolean;
  ariaLabel?: string;
  ariaPressed?: AriaAttributes['aria-pressed'];
  ariaCurrent?: AriaAttributes['aria-current'];
  ariaExpanded?: boolean;
  className?: string;
  title?: string;
};

/** Drop-in replacement for `<div onClick>`. Base `display` is `block`; override it via `style`. */
export function Pressable({ onClick, style, children, disabled, ariaLabel, ariaPressed, ariaCurrent, ariaExpanded, className, title }: PressableProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={ariaLabel}
      aria-pressed={ariaPressed}
      aria-current={ariaCurrent}
      aria-expanded={ariaExpanded}
      className={className}
      title={title}
      style={{ ...pressableReset, ...style }}
    >
      {children}
    </button>
  );
}

/* ------------------------------------------------- TextField / TextArea */

export type FieldType = 'text' | 'email' | 'password' | 'search' | 'tel' | 'number' | 'date' | 'time';

type FieldLabelling =
  | { label: ReactNode; labelStyle?: CSSProperties; ariaLabel?: string }
  | { label?: undefined; labelStyle?: undefined; ariaLabel: string };

type FieldCommon = {
  value: string;
  onChange: (value: string) => void;
  placeholder?: string;
  /** Colour of the placeholder text. Defaults to the field's own `color`. */
  placeholderColor?: string;
  style?: CSSProperties;
  id?: string;
  name?: string;
  autoComplete?: string;
  disabled?: boolean;
  className?: string;
};

export type TextFieldProps = FieldCommon & FieldLabelling & {
  type?: FieldType;
  onKeyDown?: (event: KeyboardEvent<HTMLInputElement>) => void;
};

/**
 * Real `<input>`, UA-reset. When `label` is given it renders a `<label htmlFor>` sibling
 * (a fragment, so the caller's own wrapper/gap is untouched); otherwise `ariaLabel` is required.
 */
export function TextField({
  value, onChange, placeholder, placeholderColor, type = 'text', style,
  label, labelStyle, ariaLabel, id, name, autoComplete, disabled, className, onKeyDown,
}: TextFieldProps) {
  const fallbackId = useId();
  const fieldId = id ?? fallbackId;
  return (
    <>
      {label !== undefined && (
        <label htmlFor={fieldId} style={{ display: 'block', ...labelStyle }}>{label}</label>
      )}
      <input
        id={fieldId}
        type={type}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
        name={name}
        autoComplete={autoComplete}
        disabled={disabled}
        aria-label={label === undefined ? ariaLabel : undefined}
        className={joinClass('ui-field', className)}
        style={fieldStyleFor(style, placeholderColor)}
      />
    </>
  );
}

export type TextAreaProps = FieldCommon & FieldLabelling & {
  rows?: number;
  onKeyDown?: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
};

/** Same contract as TextField, but a `<textarea>` with `resize:none`. */
export function TextArea({
  value, onChange, placeholder, placeholderColor, rows = 2, style,
  label, labelStyle, ariaLabel, id, name, autoComplete, disabled, className, onKeyDown,
}: TextAreaProps) {
  const fallbackId = useId();
  const fieldId = id ?? fallbackId;
  return (
    <>
      {label !== undefined && (
        <label htmlFor={fieldId} style={{ display: 'block', ...labelStyle }}>{label}</label>
      )}
      <textarea
        id={fieldId}
        rows={rows}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
        name={name}
        autoComplete={autoComplete}
        disabled={disabled}
        aria-label={label === undefined ? ariaLabel : undefined}
        className={joinClass('ui-field', className)}
        style={fieldStyleFor(style, placeholderColor, { resize: 'none' })}
      />
    </>
  );
}

/* --------------------------------------------------------------------- Toggle */

export type ToggleProps = {
  checked: boolean;
  onChange: (checked: boolean) => void;
  ariaLabel: string;
  style?: CSSProperties;
  className?: string;
};

/** 38x22 pill switch with an 18px white knob that slides between the two ends. */
export function Toggle({ checked, onChange, ariaLabel, style, className }: ToggleProps) {
  const knob: CSSProperties = {
    position: 'absolute',
    top: 2,
    ...(checked ? { right: 2 } : { left: 2 }),
    width: 18,
    height: 18,
    borderRadius: '50%',
    background: '#ffffff',
  };
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      className={className}
      onClick={() => onChange(!checked)}
      style={{
        ...pressableReset,
        width: 38,
        height: 22,
        borderRadius: 11,
        background: checked ? '#1D4ED8' : '#CBD5E1',
        position: 'relative',
        ...style,
      }}
    >
      <span aria-hidden="true" style={knob} />
    </button>
  );
}

/* ------------------------------------------------------------------- Checkbox */

const checkMark =
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 18 18'%3E%3Cpath d='M4.3 9.2 7.2 12.1 13.6 5.7' fill='none' stroke='%23ffffff' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")`;

export type CheckboxProps = {
  checked: boolean;
  onChange: (checked: boolean) => void;
  ariaLabel: string;
  style?: CSSProperties;
  id?: string;
  disabled?: boolean;
  className?: string;
};

/**
 * Real `<input type="checkbox">` with `appearance:none`, painted as the spec's 18px box
 * (1.5px #1D4ED8, radius 5). Never hidden, so it stays focusable and Space-operable.
 */
export function Checkbox({ checked, onChange, ariaLabel, style, id, disabled, className }: CheckboxProps) {
  return (
    <input
      type="checkbox"
      id={id}
      checked={checked}
      onChange={(event) => onChange(event.target.checked)}
      aria-label={ariaLabel}
      disabled={disabled}
      className={className}
      style={{
        appearance: 'none',
        WebkitAppearance: 'none',
        display: 'block',
        boxSizing: 'border-box',
        width: 18,
        height: 18,
        borderRadius: 5,
        border: '1.5px solid #1D4ED8',
        background: checked ? `#1D4ED8 ${checkMark} center / 14px 14px no-repeat` : 'none',
        flexShrink: 0,
        padding: 0,
        margin: 0,
        cursor: 'pointer',
        ...style,
      }}
    />
  );
}

/* ----------------------------------------------------------------------- Chip */

export type ChipProps = {
  selected: boolean;
  onClick?: (event: MouseEvent<HTMLButtonElement>) => void;
  children?: ReactNode;
  style?: CSSProperties;
  ariaLabel?: string;
  className?: string;
  title?: string;
};

/** Filter chip: radius 16, padding 7px 14px, fontSize 12.5; selected is solid #1D4ED8. */
export function Chip({ selected, onClick, children, style, ariaLabel, className, title }: ChipProps) {
  const look: CSSProperties = selected
    ? { borderRadius: 16, padding: '7px 14px', fontSize: 12.5, background: '#1D4ED8', color: '#ffffff', fontWeight: 600 }
    : { borderRadius: 16, padding: '7px 14px', fontSize: 12.5, background: '#ffffff', border: '1px solid #DDE3EB', color: '#5B6B7F' };
  return (
    <Pressable
      onClick={onClick}
      ariaPressed={selected}
      ariaLabel={ariaLabel}
      className={className}
      title={title}
      style={{ ...look, ...style }}
    >
      {children}
    </Pressable>
  );
}

/* ----------------------------------------------------------------------- Busy */

export type BusyProps = {
  /** What is loading, e.g. "Loading patients…". Shown beside the spinner. */
  label?: string;
  /** Center in a full-height area (default) vs inline at the top of a card. */
  fill?: boolean;
  onDark?: boolean;
};

/**
 * The one loading affordance every data-backed screen uses: an animated ring plus the
 * operation being performed. A visible, honest cue so a not-yet-rendered table never reads
 * as "no data".
 */
export function Busy({ label = 'Loading…', fill = true, onDark }: BusyProps) {
  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 12,
        padding: fill ? '48px 0' : '12px 0',
        width: '100%',
        height: fill ? '100%' : undefined,
        color: onDark ? '#C7D2E4' : '#5B6B7F',
        fontSize: 13.5,
      }}
    >
      <span aria-hidden="true" className={`ui-spinner${onDark ? ' on-dark' : ''}`} />
      {label}
    </div>
  );
}

/* ------------------------------------------------------- SegmentedControl */

export type SegmentedControlProps = {
  options: readonly string[];
  value: string;
  onChange: (value: string) => void;
  /** Container style (the spec's wrapper: border, radius, overflow, gap…). */
  style?: CSSProperties;
  /** Applied to every segment. */
  itemStyle?: CSSProperties;
  /** Merged on top of `itemStyle` for the selected segment. */
  selectedItemStyle?: CSSProperties;
  ariaLabel?: string;
  className?: string;
};

/** Radiogroup of segments (Day/Week, 15/30/45 min): roving tabindex, arrow/Home/End navigable. */
export function SegmentedControl({
  options, value, onChange, style, itemStyle, selectedItemStyle, ariaLabel, className,
}: SegmentedControlProps) {
  const items = useRef<(HTMLButtonElement | null)[]>([]);
  const activeIndex = options.indexOf(value);
  const tabbableIndex = activeIndex === -1 ? 0 : activeIndex;

  const select = (index: number) => {
    const wrapped = (index + options.length) % options.length;
    onChange(options[wrapped]);
    items.current[wrapped]?.focus();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const key = event.key;
    let target: number | null = null;
    if (key === 'ArrowRight' || key === 'ArrowDown') target = index + 1;
    else if (key === 'ArrowLeft' || key === 'ArrowUp') target = index - 1;
    else if (key === 'Home') target = 0;
    else if (key === 'End') target = options.length - 1;
    if (target === null) return;
    event.preventDefault();
    select(target);
  };

  return (
    <div role="radiogroup" aria-label={ariaLabel} className={className} style={{ display: 'flex', ...style }}>
      {options.map((option, index) => {
        const selected = index === activeIndex;
        return (
          <button
            key={option}
            type="button"
            role="radio"
            aria-checked={selected}
            tabIndex={index === tabbableIndex ? 0 : -1}
            ref={(node) => { items.current[index] = node; }}
            onClick={() => onChange(option)}
            onKeyDown={(event) => handleKeyDown(event, index)}
            style={{ ...pressableReset, ...itemStyle, ...(selected ? selectedItemStyle : undefined) }}
          >
            {option}
          </button>
        );
      })}
    </div>
  );
}
