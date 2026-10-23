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
