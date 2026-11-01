import {
  CallableOptions,
  CallableRequest,
  HttpsError,
  onCall,
} from "firebase-functions/v2/https";

/**
 * Turns a thrown error into an HttpsError whose message reaches the
 * client. A raw Error is rewritten by the callable runtime as
 * `{message:"INTERNAL"}`, which hides the cause.
 * @param {unknown} error Whatever the handler threw.
 * @return {HttpsError} The error to rethrow.
 */
export const exposeCallableError = (error: unknown): HttpsError => {
  if (error instanceof HttpsError) {
    console.error(`[callable] ${error.code}: ${error.message}`);
    return error;
  }
  const message =
    error instanceof Error && error.message.trim() !== "" ?
      error.message :
      "Unknown error";
  console.error(`[callable] ${message}`, error);
  return new HttpsError("internal", message);
};

/**
 * `onCall` that logs the real failure and sends its message to the
 * client instead of a bare INTERNAL.
 * @param {CallableOptions} opts Callable options.
 * @param {Function} handler The callable body.
 * @return {Function} The wrapped callable.
 */
export const onCallSafe = (
  opts: CallableOptions,
  handler: (request: CallableRequest) => Promise<unknown>
) => {
  return onCall(opts, async (request) => {
    try {
      return await handler(request);
    } catch (error) {
      throw exposeCallableError(error);
    }
  });
};
