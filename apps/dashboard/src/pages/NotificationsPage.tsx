import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Link, NavLink } from 'react-router-dom';
import { api, type NotificationItem, type NotificationPage, type NotificationPreferences } from '../api';

/** Where a notification leads inside the dashboard (null = informational). */
const target = (n: NotificationItem): string | null => {
  if (n.type === 'grant_received' || n.type === 'grant_expiring' || n.type === 'access_request_approved') return '/shared';
  if (n.type.startsWith('security_')) return '/security';
  if (n.type === 'staff_joined') return '/team';
  return null;
};

const TYPE_LABELS: Record<string, string> = {
  appointment_reminder: 'Appointment reminders',
  appointment_rescheduled: 'Appointment changes',
  appointment_cancelled: 'Appointment cancellations',
  document_published: 'New documents',
  encounter_published: 'New visit summaries',
  followup_reminder: 'Follow-up reminders',
  staff_invited: 'Workspace invitations',
  staff_joined: 'Invitation accepted',
  access_request_received: 'Access requests received',
  access_request_approved: 'Access request approved',
  access_request_denied: 'Access request declined',
  grant_received: 'Records shared with my clinic',
  grant_expiring: 'Shared access ending soon',
  security_phone_changed: 'Phone number changed',
  security_mfa_enabled: 'Two-step verification enabled',
  security_mfa_disabled: 'Two-step verification disabled',
  security_new_login: 'Sign-in from a new device',
};

/** Header link with unread badge; polls lightly so the count stays fresh without push on the web. */
export function NotificationBell() {
  const count = useQuery({ queryKey: ['notifications', 'unread'], queryFn: () => api<{ count: number }>('/notifications/unread-count'), refetchInterval: 30_000 });
  const n = count.data?.count ?? 0;
  return (
    <NavLink to="/notifications" aria-label={n ? `Notifications, ${n} unread` : 'Notifications'} className="bell">
      🔔{n > 0 && <span className="badge">{n > 99 ? '99+' : n}</span>}
    </NavLink>
  );
}

export function NotificationsPage() {
  const qc = useQueryClient();
  const prefs = useQuery({ queryKey: ['notification-preferences'], queryFn: () => api<NotificationPreferences>('/notification-preferences') });
  const list = useInfiniteQuery({
    queryKey: ['notifications', 'list'],
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam }) => api<NotificationPage>(`/notifications?limit=20${pageParam ? `&cursor=${encodeURIComponent(pageParam)}` : ''}`),
    getNextPageParam: (p) => p.nextCursor ?? undefined,
  });
  const refresh = () => qc.invalidateQueries({ queryKey: ['notifications'] });
  const read = useMutation({ mutationFn: (id: string) => api(`/notifications/${id}/read`, { method: 'POST' }), onSuccess: refresh });
  const readAll = useMutation({ mutationFn: () => api('/notifications/read-all', { method: 'POST' }), onSuccess: refresh });
  const items = list.data?.pages.flatMap((p) => p.items) ?? [];
  const rtl = prefs.data?.locale === 'ar';

  return (
    <section>
      <div className="row">
        <h2>Notifications</h2>
        <span className="spacer" />
        <Link to="/notifications/preferences">Preferences</Link>
        <button onClick={() => readAll.mutate()} disabled={readAll.isPending || !items.some((i) => !i.read)}>Mark all as read</button>
      </div>
      {list.isLoading && <p className="muted">Loading…</p>}
      {!list.isLoading && items.length === 0 && <p className="muted">Nothing here yet.</p>}
      <ul className="notif-list" dir={rtl ? 'rtl' : 'ltr'}>
        {items.map((n) => {
          const to = target(n);
          return (
            <li key={n.id} className={n.read ? 'notif' : 'notif unread'}>
              <div className="grow">
                <strong>{n.title}</strong>
                <div>{n.body}</div>
                <div className="muted">{new Date(n.createdAt).toLocaleString()}</div>
              </div>
              {to && <Link to={to} onClick={() => !n.read && read.mutate(n.id)}>Open</Link>}
              {!n.read && <button onClick={() => read.mutate(n.id)}>Mark read</button>}
            </li>
          );
        })}
      </ul>
      {list.hasNextPage && <button onClick={() => list.fetchNextPage()} disabled={list.isFetchingNextPage}>Load more</button>}
    </section>
  );
}

export function NotificationPreferencesPage() {
  const qc = useQueryClient();
  const prefs = useQuery({ queryKey: ['notification-preferences'], queryFn: () => api<NotificationPreferences>('/notification-preferences') });
  const save = useMutation({
    mutationFn: (body: Record<string, unknown>) => api<NotificationPreferences>('/notification-preferences', { method: 'PUT', body }),
    onSuccess: (r) => qc.setQueryData(['notification-preferences'], r),
  });
  const p = prefs.data;
  const [quiet, setQuiet] = useState({ on: false, start: '22:00', end: '07:00' });
  useEffect(() => {
    if (p) setQuiet({ on: !!p.quietHours, start: p.quietHours?.start ?? '22:00', end: p.quietHours?.end ?? '07:00' });
  }, [p]);
  if (!p) return <p className="muted">Loading…</p>;

  const toggleType = (type: string, on: boolean) => save.mutate({ disabledTypes: on ? p.disabledTypes.filter((t) => t !== type) : [...p.disabledTypes, type] });
  const toggleChannel = (ch: 'push' | 'sms', on: boolean) => save.mutate({ channels: on ? [...p.channels, ch] : p.channels.filter((c) => c !== ch) });

  return (
    <section>
      <div className="row">
        <h2>Notification preferences</h2>
        <span className="spacer" />
        <Link to="/notifications">Back to inbox</Link>
      </div>

      <h3>Language</h3>
      <select value={p.locale} onChange={(e) => save.mutate({ locale: e.target.value })} style={{ maxWidth: 220 }}>
        <option value="en">English</option>
        <option value="ar">العربية</option>
      </select>

      <h3>Channels</h3>
      <p className="muted">The inbox is always on. Push and SMS messages never contain clinical details; open the app to read them.</p>
      {(['push', 'sms'] as const).map((ch) => (
        <label key={ch} className="check">
          <input type="checkbox" checked={p.channels.includes(ch)} onChange={(e) => toggleChannel(ch, e.target.checked)} />
          {ch === 'push' ? 'Push notifications (mobile app)' : 'SMS fallback for time-sensitive notices'}
        </label>
      ))}

      <h3>Quiet hours</h3>
      <form className="inline" onSubmit={(e) => (e.preventDefault(), save.mutate({ quietHours: quiet.on ? { start: quiet.start, end: quiet.end, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone } : null }))}>
        <label className="check"><input type="checkbox" checked={quiet.on} onChange={(e) => setQuiet({ ...quiet, on: e.target.checked })} />Hold push and SMS</label>
        <input type="time" value={quiet.start} disabled={!quiet.on} onChange={(e) => setQuiet({ ...quiet, start: e.target.value })} aria-label="Quiet hours start" />
        <span>to</span>
        <input type="time" value={quiet.end} disabled={!quiet.on} onChange={(e) => setQuiet({ ...quiet, end: e.target.value })} aria-label="Quiet hours end" />
        <button disabled={save.isPending}>Save</button>
      </form>
      {p.quietHours && <p className="muted">Currently {p.quietHours.start}–{p.quietHours.end} ({p.quietHours.timezone}). Security notices are never held.</p>}

      <h3>Notification types</h3>
      <table>
        <tbody>
          {p.types.map((t) => (
            <tr key={t.type}>
              <td>{TYPE_LABELS[t.type] ?? t.type}</td>
              <td>
                {t.mandatory ? (
                  <span className="muted" title="Security notices cannot be turned off">🔒 Always on</span>
                ) : (
                  <label className="check">
                    <input type="checkbox" checked={!p.disabledTypes.includes(t.type)} onChange={(e) => toggleType(t.type, e.target.checked)} />
                    On
                  </label>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {save.error && <p className="error">{(save.error as Error).message}</p>}
    </section>
  );
}
