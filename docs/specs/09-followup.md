# 09 — Follow-up Plans (P0, basic)

**Source:** BR-06. Advanced analytics are Phase 2.

## User stories
- As a doctor, I set a follow-up date and ask the patient to report specific measurements.
- As a patient, I get reminded and submit values or photos easily.
- As a doctor, I review submissions against earlier values.

## Functional requirements
| ID | Requirement |
|----|-------------|
| F09-1 | Follow-up plan: next-visit date, instructions, requested measurements (name, unit, frequency, optional normal range), end date. |
| F09-2 | Patient submissions: numeric value + time, optional note and attachment. |
| F09-3 | Submissions carry `source = patient`; UI never labels them as verified findings (BR-06). |
| F09-4 | Doctor dashboard: list of patients with overdue/missed submissions; simple trend chart per measurement. |
| F09-5 | Doctor can close or edit a plan; edits keep history. |
| F09-6 | Reminders follow patient notification preferences and consent (spec 10). |

## Acceptance criteria
- A submission after plan end is rejected or flagged.
- Out-of-range values are highlighted for the doctor only as "patient-reported, outside expected range" — no automatic clinical conclusion.
