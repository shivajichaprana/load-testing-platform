// A stand-in for the generator's HTTP client.
//
// It makes no request. What it does is record the arguments, because the
// arguments are the thing worth asserting on: the resolved URL (a scenario
// that resolves to a different origin measures a different site and reports it
// under this target's name), the request tags (an untagged request sits
// outside every phase-scoped threshold, and a threshold with no samples
// passes) and the response type (a body-reading check against a discarded body
// can never pass).

/** Every request, in order. */
export const requests = [];

/** The response the next call returns. Replace it from a test. */
let nextResponse = {
  status: 200,
  body: '{"items":[]}',
  headers: { 'Content-Type': 'application/json' },
  timings: { duration: 10 },
};

export function resetClient(response) {
  requests.length = 0;
  if (response !== undefined) nextResponse = response;
}

function respond(method, url, body, params) {
  requests.push({ method, url, body: body ?? null, params: params ?? {} });
  const response = { ...nextResponse };
  response.json = function json(path) {
    const parsed = JSON.parse(this.body);
    return path === undefined ? parsed : path.split('.').reduce((cursor, key) => cursor?.[key], parsed);
  };
  return response;
}

export const http = {
  get: (url, params) => respond('GET', url, null, params),
  post: (url, body, params) => respond('POST', url, body, params),
  put: (url, body, params) => respond('PUT', url, body, params),
  patch: (url, body, params) => respond('PATCH', url, body, params),
  del: (url, body, params) => respond('DELETE', url, body, params),
  request: (method, url, body, params) => respond(method, url, body, params),
};

export default http;
