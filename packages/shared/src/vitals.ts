// Plausibility bounds only catch typing mistakes (e.g. 700 kg). They are not clinical reference ranges.
export const VITAL_KINDS = {
  weight_kg: { label: 'Weight', unit: 'kg', min: 0.3, max: 500 },
  height_cm: { label: 'Height', unit: 'cm', min: 20, max: 260 },
  systolic_bp: { label: 'Systolic BP', unit: 'mmHg', min: 40, max: 300 },
  diastolic_bp: { label: 'Diastolic BP', unit: 'mmHg', min: 20, max: 200 },
  heart_rate: { label: 'Heart rate', unit: 'bpm', min: 20, max: 300 },
  resp_rate: { label: 'Respiratory rate', unit: '/min', min: 4, max: 80 },
  temperature_c: { label: 'Temperature', unit: '°C', min: 25, max: 45 },
  spo2: { label: 'SpO₂', unit: '%', min: 30, max: 100 },
  glucose_mg_dl: { label: 'Blood glucose', unit: 'mg/dL', min: 10, max: 1500 },
} as const;
export type VitalKind = keyof typeof VITAL_KINDS;
export const VITAL_KEYS = Object.keys(VITAL_KINDS) as [VitalKind, ...VitalKind[]];
