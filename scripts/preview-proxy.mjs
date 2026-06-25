// Proxy Preview per UNVRS Hub (ispirato a unvrs-code/preview-proxy.mjs).
// Inoltra tutto al dev server locale togliendo gli header che bloccano
// l'embedding in WKWebView (X-Frame-Options / CSP) e inoltrando il WebSocket (HMR).
// Uso: node preview-proxy.mjs <proxyPort> <devPort>
import http from 'node:http';

const PROXY = Number(process.argv[2]);
const DEV = Number(process.argv[3]);
if (!PROXY || !DEV) { console.error('uso: preview-proxy.mjs <proxyPort> <devPort>'); process.exit(1); }

const server = http.createServer((req, res) => {
  const opts = {
    host: '127.0.0.1', port: DEV, method: req.method, path: req.url,
    headers: { ...req.headers, host: '127.0.0.1:' + DEV },
  };
  const p = http.request(opts, (pr) => {
    const h = { ...pr.headers };
    delete h['x-frame-options']; delete h['X-Frame-Options'];
    delete h['content-security-policy']; delete h['content-security-policy-report-only'];
    res.writeHead(pr.statusCode || 502, h);
    pr.pipe(res);
  });
  p.on('error', () => { if (!res.headersSent) { res.writeHead(502); res.end('dev server non raggiungibile'); } });
  req.pipe(p);
});

// WebSocket (HMR di Vite/Next) -> inoltra l'upgrade
server.on('upgrade', (req, socket) => {
  const p = http.request({ host: '127.0.0.1', port: DEV, path: req.url, headers: req.headers });
  p.on('upgrade', (pr, psock) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\n' +
      Object.entries(pr.headers).map(([k, v]) => k + ': ' + v).join('\r\n') + '\r\n\r\n');
    psock.pipe(socket); socket.pipe(psock);
  });
  p.on('error', () => socket.destroy());
  p.end();
});

server.listen(PROXY, '127.0.0.1', () => console.log(`preview proxy ${PROXY} -> ${DEV}`));
