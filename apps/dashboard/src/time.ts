// All times are shown in the clinic's own time zone, not the browser's.
export const fmtTime = (iso: string, tz: string) => new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: tz }).format(new Date(iso));
export const fmtDateTime = (iso: string, tz: string) =>
  new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: tz }).format(new Date(iso));
export const todayIn = (tz: string) => new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date());
