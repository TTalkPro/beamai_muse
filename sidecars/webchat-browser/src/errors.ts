export class WorkerError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(code: string, message: string, status = 400, cause?: unknown) {
    super(message);
    this.code = code;
    this.status = status;
    if (cause !== undefined) this.cause = cause;
  }
}
