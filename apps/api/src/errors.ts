export class AppError extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}
export const unauthorized = (m = 'Authentication required') => new AppError(401, 'unauthorized', m);
export const forbidden = (m = 'Not allowed') => new AppError(403, 'forbidden', m);
export const notFound = (m = 'Not found') => new AppError(404, 'not_found', m);
export const conflict = (code: string, m?: string) => new AppError(409, code, m);
export const badRequest = (code: string, m?: string) => new AppError(400, code, m);
