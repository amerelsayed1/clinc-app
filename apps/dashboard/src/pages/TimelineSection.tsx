import { useInfiniteQuery } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, type TimelineEntry, type TimelinePage } from '../api';
import { fmtDateTime } from '../time';
import { useSettings } from './AppointmentsPage';

const TYPES: { value: string; label: string; icon: string }[] = [
  { value: 'encounter', label: 'Consultations', icon: '🩺' },
  { value: 'prescription', label: 'Prescriptions', icon: '💊' },
  { value: 'document', label: 'Documents', icon: '📄' },
  { value: 'observation', label: 'Vitals', icon: '📈' },
  { value: 'followup', label: 'Follow-up', icon: '🔁' },
  { value: 'appointment', label: 'Appointments', icon: '📅' },
  { value: 'shared_notice', label: 'Sharing', icon: '🔗' },
];
const ICON = Object.fromEntries(TYPES.map((t) => [t.value, t.icon]));
const BADGE: Record<string, string> = { clinician_authored: 'Clinician-authored', patient_submitted: 'Patient-submitted', reviewed: 'Reviewed by clinician' };

function useDebounced<T>(value: T, ms = 300) {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

function EntryLink({ e, onOpenDocuments }: { e: TimelineEntry; onOpenDocuments: () => void }) {
  const grant = e.shared?.via === 'grant' ? e.shared.grantId : null;
  if (e.refType === 'encounter') {
    return e.shared ? (grant ? <Link to={`/shared/${grant}/encounters/${e.id}`}>Open</Link> : null) : <Link to={`/encounters/${e.id}`}>Open</Link>;
  }
  if (e.refType === 'document') {
    return grant ? <Link to={`/shared/${grant}/documents/${e.id}`}>Open</Link> : <button className="link" onClick={onOpenDocuments}>View in documents</button>;
  }
  return null;
}

export function TimelineSection({ patientId, onOpenDocuments }: { patientId: string; onOpenDocuments: () => void }) {
  const settings = useSettings();
  const tz = settings.data?.timezone ?? 'Africa/Cairo';
  const [types, setTypes] = useState<string[]>([]);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [source, setSource] = useState('');
  const [q, setQ] = useState('');
  const dq = useDebounced(q);

  const qs = (cursor?: string) => {
    const p = new URLSearchParams({ limit: '30' });
    if (types.length) p.set('type', types.join(','));
    if (from) p.set('from', from);
    if (to) p.set('to', to);
    if (source) p.set('source', source);
    if (dq.trim()) p.set('q', dq.trim());
    if (cursor) p.set('cursor', cursor);
    return p.toString();
  };
  const list = useInfiniteQuery({
    queryKey: ['timeline', patientId, types, from, to, source, dq],
    queryFn: ({ pageParam }) => api<TimelinePage>(`/patients/${patientId}/timeline?${qs(pageParam)}`),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last) => last.nextCursor ?? undefined,
  });
  const items = list.data?.pages.flatMap((p) => p.items) ?? [];
  const toggle = (t: string) => setTypes((cur) => (cur.includes(t) ? cur.filter((x) => x !== t) : [...cur, t]));

  return (
    <div className="timeline">
      <form className="inline" onSubmit={(e) => e.preventDefault()}>
        <input className="grow" placeholder="Search titles and notes" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search timeline" />
        <label className="check">From <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="check">To <input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></label>
        <select value={source} onChange={(e) => setSource(e.target.value)} aria-label="Source">
          <option value="">All sources</option>
          <option value="own">This clinic</option>
          <option value="shared">Shared with this clinic</option>
          <option value="patient">Added by patient</option>
        </select>
      </form>
      <div className="chips">
        {TYPES.map((t) => (
          <button key={t.value} type="button" className={`chip ${types.includes(t.value) ? 'on' : ''}`} onClick={() => toggle(t.value)}>
            {t.icon} {t.label}
          </button>
        ))}
        {(types.length > 0 || from || to || source || q) && (
          <button type="button" className="link" onClick={() => (setTypes([]), setFrom(''), setTo(''), setSource(''), setQ(''))}>Clear filters</button>
        )}
      </div>
      {list.isLoading && <p>Loading…</p>}
      {list.error && <p className="error">{(list.error as Error).message}</p>}
      {!list.isLoading && !items.length && <p className="muted">Nothing on the timeline matches.</p>}
      <ol className="tl-list">
        {items.map((e) => (
          <li key={`${e.type}:${e.id}`} className={`tl-item ${e.shared ? 'shared' : ''}`}>
            <span className="tl-icon" aria-hidden>{ICON[e.type] ?? '•'}</span>
            <div className="tl-body">
              <div className="row tl-head">
                <strong>{e.title}</strong>
                <span className="pill">{TYPES.find((t) => t.value === e.type)?.label ?? e.type}</span>
                <span className={`pill badge-${e.verificationBadge}`}>{BADGE[e.verificationBadge] ?? e.verificationBadge}</span>
                {e.amended && (
                  <span className="pill invited">
                    v{e.version} · amended {e.historyPath ? <Link to={`/encounters/${e.id}`}>history</Link> : null}
                  </span>
                )}
                {e.shared && <span className="flag">{e.shared.label}{e.shared.expiresAt ? ` · until ${new Date(e.shared.expiresAt).toLocaleDateString()}` : ''}</span>}
              </div>
              {e.summary && <div>{e.summary}</div>}
              <div className="muted">
                {fmtDateTime(e.date, tz)}
                {e.author ? ` · ${e.author.name}` : ''}
                {e.source.kind === 'clinic' ? ` · ${e.source.name}` : e.shared ? '' : ' · Patient'}
              </div>
              <EntryLink e={e} onOpenDocuments={onOpenDocuments} />
            </div>
          </li>
        ))}
      </ol>
      {list.hasNextPage && (
        <button type="button" disabled={list.isFetchingNextPage} onClick={() => list.fetchNextPage()}>
          {list.isFetchingNextPage ? 'Loading…' : 'Load more'}
        </button>
      )}
    </div>
  );
}
