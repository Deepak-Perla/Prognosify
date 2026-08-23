import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Minimal fetch-state hook for the screen queries in lib/api.
 *
 * Every portal page needs the same three states: loading (skeleton-free — the shell still
 * renders, the data area says it is loading), an error banner that names what failed, and a
 * way to re-run after a write. `deps` follows useEffect semantics; changing any entry refetches.
 */
export interface AsyncState<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
  reload: () => void;
}

export function useAsync<T>(fetch: () => Promise<T>, deps: unknown[]): AsyncState<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);

  // Keep the latest fn without making it a dependency: callers pass inline closures freely.
  const fetchRef = useRef(fetch);
  fetchRef.current = fetch;

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    fetchRef
      .current()
      .then((value) => {
        if (!cancelled) {
          setData(value);
          setLoading(false);
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Something went wrong.');
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- callers list their own deps; tick covers reload()
  }, [...deps, tick]);

  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { data, error, loading, reload };
}
