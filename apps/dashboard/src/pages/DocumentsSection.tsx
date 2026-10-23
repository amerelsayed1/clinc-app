import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useRef, useState } from 'react';
import { api, type Doc } from '../api';
import { fmtDateTime } from '../time';
import { useSettings } from './AppointmentsPage';

const CATEGORY: Record<string, string> = { prescription: 'Prescription', lab_result: 'Lab result', imaging: 'Imaging', report: 'Report', administrative: 'Administrative', other: 'Other' };
const CLINICAL = ['prescription', 'lab_result', 'imaging', 'report', 'other'];
const mb = (n: number) => (n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(n > 10 * 1024 * 1024 ? 0 : 1)} MB`);

/** Phone photos are huge; shrink them before upload (F06-1). Small files and PDFs pass through untouched. */
async function prepare(file: File): Promise<File> {
  if (!file.type.startsWith('image/') || file.size < 1_500_000) return file;
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 2200 / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext('2d')!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', 0.85));
    return blob && blob.size < file.size ? new File([blob], file.name.replace(/\.\w+$/, '') + '.jpg', { type: 'image/jpeg' }) : file;
  } catch {
    return file;
  }
}

export function DocumentsSection({ patientId, encounterId, can }: { patientId: string; encounterId?: string; can: (p: string) => boolean }) {
  const qc = useQueryClient();
  const tz = useSettings().data?.timezone ?? 'Africa/Cairo';
  const key = ['documents', patientId, encounterId ?? null];
  const list = useQuery({ queryKey: key, queryFn: () => api<Doc[]>(`/patients/${patientId}/documents${encounterId ? `?encounterId=${encounterId}` : ''}`) });
  const storage = useQuery({ queryKey: ['storage'], queryFn: () => api<{ usedBytes: number; quotaBytes: number }>('/workspace/storage'), enabled: can('documents.upload') });
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<string>();
  const reload = () => {
    qc.invalidateQueries({ queryKey: ['documents'] });
    qc.invalidateQueries({ queryKey: ['storage'] });
  };
  const act = useMutation({
    mutationFn: ({ id, action, body }: { id: string; action: string; body?: object }) => (action === 'delete' ? api(`/documents/${id}`, { method: 'DELETE', body }) : api(`/documents/${id}/${action}`, { method: 'POST', body: body ?? {} })),
    onSuccess: reload,
    onError: (e) => setError((e as Error).message),
  });

  const view = async (id: string, page: number) => {
    setError(undefined);
    const w = window.open('', '_blank');
    try {
      const { path } = await api<{ path: string }>(`/documents/${id}/pages/${page}/link`);
      if (w) w.location.href = `/api${path}`;
    } catch (e) {
      w?.close();
      setError((e as Error).message);
    }
  };

  return (
    <>
      <div className="row" style={{ marginTop: '1.25rem' }}>
        <h3 style={{ margin: 0 }}>Documents</h3>
        {storage.data && <span className="muted">{mb(storage.data.usedBytes)} of {mb(storage.data.quotaBytes)} used</span>}
        <span className="spacer" />
        {can('documents.upload') && <button onClick={() => setAdding((a) => !a)}>{adding ? 'Close' : 'Upload'}</button>}
      </div>
      {adding && <UploadForm patientId={patientId} encounterId={encounterId} can={can} onDone={() => (setAdding(false), reload())} />}
      {error && <p className="error">{error}</p>}
      <table>
        <tbody>
          {list.data?.map((d) => (
            <tr key={d.id}>
              <td>
                <strong>{d.title || <span className="muted">(untitled)</span>}</strong> <span className="pill">{CATEGORY[d.category] ?? d.category}</span>
                {d.provenance === 'patient_submitted_unverified' && (d.reviewed ? <span className="pill completed" style={{ marginLeft: 6 }}>Patient-submitted · reviewed ✓</span> : <span className="pill invited" style={{ marginLeft: 6 }}>Patient-submitted · unverified</span>)}
                {d.published && <span className="pill" style={{ marginLeft: 6 }}>Shown to patient</span>}
                <div className="muted">
                  {d.documentDate ?? fmtDateTime(d.createdAt, tz)} · {d.pages.length} {d.pages.length === 1 ? 'page' : 'pages'} · {mb(d.totalBytes)} · {d.uploaderName ?? 'Patient'} ({d.uploaderRole})
                  {d.notes && <> · {d.notes}</>}
                </div>
              </td>
              <td style={{ textAlign: 'right' }}>
                <span className="actions">
                  {d.pages.map((p) => <button key={p.page} onClick={() => view(d.id, p.page)}>{d.pages.length === 1 ? 'View' : `Page ${p.page}`}</button>)}
                  {d.source === 'patient' && !d.reviewed && can('clinical.write') && <button onClick={() => act.mutate({ id: d.id, action: 'review', body: { note: '' } })}>Mark reviewed</button>}
                  {d.source !== 'patient' && d.category !== 'administrative' && can('clinical.write') && (
                    <button onClick={() => act.mutate({ id: d.id, action: d.published ? 'unpublish' : 'publish' })}>{d.published ? 'Hide from patient' : 'Show to patient'}</button>
                  )}
                  {d.source !== 'patient' && can('documents.upload') && (
                    <button className="danger" onClick={() => { const reason = prompt('Why are you deleting this document?'); if (reason && reason.trim().length >= 3) act.mutate({ id: d.id, action: 'delete', body: { reason: reason.trim() } }); }}>Delete</button>
                  )}
                </span>
              </td>
            </tr>
          ))}
          {list.data?.length === 0 && <tr><td className="muted">No documents.</td></tr>}
        </tbody>
      </table>
    </>
  );
}

function UploadForm({ patientId, encounterId, can, onDone }: { patientId: string; encounterId?: string; can: (p: string) => boolean; onDone: () => void }) {
  const clinical = can('documents.upload_clinical');
  const [files, setFiles] = useState<File[]>([]);
  const [f, setF] = useState({ category: clinical ? 'lab_result' : 'administrative', title: '', notes: '', documentDate: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const pick = useRef<HTMLInputElement>(null);
  const cam = useRef<HTMLInputElement>(null);
  const hasPdf = files.some((x) => x.type === 'application/pdf');

  // FileList is live: copy it before the input is reset, or the state updater would see an empty list.
  const add = (list: FileList | null) => {
    const picked = list ? Array.from(list) : [];
    if (picked.length) setFiles((cur) => [...cur, ...picked]);
  };
  const submit = async () => {
    setBusy(true);
    setError(undefined);
    try {
      const fd = new FormData();
      Object.entries({ ...f, ...(encounterId && { encounterId }) }).forEach(([k, v]) => v && fd.append(k, v));
      for (const file of files) fd.append('file', await prepare(file));
      await api(`/patients/${patientId}/documents`, { method: 'POST', body: fd });
      onDone();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="card" onSubmit={(e) => (e.preventDefault(), files.length && submit())}>
      <div className="grid">
        <label>Type
          <select value={f.category} onChange={(e) => setF({ ...f, category: e.target.value })}>
            {(clinical ? CLINICAL : ['administrative']).map((c) => <option key={c} value={c}>{CATEGORY[c]}</option>)}
            {clinical && <option value="administrative">Administrative</option>}
          </select>
        </label>
        <label>Title<input value={f.title} maxLength={120} onChange={(e) => setF({ ...f, title: e.target.value })} placeholder="e.g. CBC, chest X-ray" /></label>
        <label>Document date<input type="date" value={f.documentDate} max={new Date().toISOString().slice(0, 10)} onChange={(e) => setF({ ...f, documentDate: e.target.value })} /></label>
        <label>Notes<input value={f.notes} maxLength={1000} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
      </div>
      <div className="row">
        <button type="button" onClick={() => cam.current?.click()} disabled={hasPdf}>Take photo</button>
        <button type="button" onClick={() => pick.current?.click()}>Choose files</button>
        <input ref={cam} type="file" accept="image/*" capture="environment" hidden onChange={(e) => (add(e.target.files), (e.target.value = ''))} />
        <input ref={pick} type="file" accept="image/jpeg,image/png,image/webp,application/pdf" multiple hidden onChange={(e) => (add(e.target.files), (e.target.value = ''))} />
        <span className="muted">JPEG, PNG, WebP or one PDF · up to 15 MB each · up to 20 pages</span>
      </div>
      {files.length > 0 && (
        <ol>
          {files.map((file, i) => (
            <li key={i}>{file.name} <span className="muted">({mb(file.size)})</span> <button type="button" className="link" style={{ display: 'inline' }} onClick={() => setFiles(files.filter((_, j) => j !== i))}>remove</button></li>
          ))}
        </ol>
      )}
      <button disabled={busy || files.length === 0}>{busy ? 'Uploading…' : `Upload ${files.length || ''} ${files.length === 1 ? 'page' : 'pages'}`}</button>
      {error && <p className="error">{error}</p>}
    </form>
  );
}
