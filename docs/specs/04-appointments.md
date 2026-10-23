# 04 — Appointments & Check-in (P0)

**Source:** BR-05.05, user journey (doctor & small team).

## User stories
- As a receptionist, I book, reschedule and cancel appointments and see today's waiting list.
- As a doctor, I see who is waiting and open the next patient in one tap.
- As a patient, I see upcoming appointments and get reminders.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F04-1 | Workspace working hours and slot length (default 15 min); optional walk-in queue mode. |
| F04-2 | Create / reschedule / cancel appointment with type (new, follow-up) and reason (free text, non-diagnostic). |
| F04-3 | Statuses: `scheduled → checked_in → in_consultation → completed`, plus `cancelled`, `no_show`. |
| F04-4 | Conflict detection for overlapping slots (overridable by doctor/receptionist with confirmation). |
| F04-5 | Today view (waiting list ordered by check-in time) for doctor and staff. |
| F04-6 | Starting a consultation from an appointment pre-creates a draft encounter (spec 05). |
| F04-7 | Reminder scheduling hands off to spec 10. |

## Acceptance criteria
- Receptionist can fully manage appointments without access to clinical notes.
- Cancelling within a configurable window notifies the patient.
- Times are stored in UTC and displayed in the workspace time zone (default Africa/Cairo).

## Audit events
appointment created/changed/cancelled, status transitions.

## Implementation notes
- **Settings:** time zone (default `Africa/Cairo`), slot length (5-120 min, default 15) and working hours per weekday live on the workspace. The default hours are an assumption (Saturday-Thursday 09:00-17:00, Friday closed) and are editable on the Settings page.
- **Time handling:** stored as UTC; the API accepts either an ISO `scheduledAt` or a clinic-local `localStart` ("2030-06-03T10:30"). The dashboard always shows clinic time, not browser time.
- **Conflicts and hours:** overlapping an active appointment (`scheduled`, `checked_in`, `in_consultation`) returns `409 slot_conflict` with the clashing appointments; booking outside working hours returns `409 outside_working_hours`. Both are cleared by resending with `override: true`. Past times are rejected (5-minute grace). Bookings are serialized per workspace with an advisory lock; a test fires 30 concurrent requests at one slot.
- **Status rules:** `scheduled -> checked_in -> in_consultation -> completed`; `scheduled|checked_in -> cancelled`; `scheduled -> no_show` (only after the appointment time). Check-in/cancel/no-show need `appointments.manage`; start/complete need `clinical.write`, so receptionists, nurses and unverified doctors cannot run consultations. Only `scheduled` appointments can be rescheduled.
- **Walk-ins:** `POST /appointments/walk-in` joins the waiting list at once and skips the slot check. The waiting list is ordered by check-in time.
- **Patients:** appointments can be booked for `active` and `invited` patients (a patient awaiting app confirmation can still be scheduled); never for `ended`. Ending a relationship, by the clinic or the patient, cancels its `scheduled` and `checked_in` appointments.
- **Audit:** records ids and status changes only, never the visit reason or cancel reason text.
- `nurse` gains `appointments.read` (view only), matching the permission matrix in spec 02.
