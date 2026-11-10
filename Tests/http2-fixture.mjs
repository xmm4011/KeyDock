// TLS HTTP/2 only. All keys and responses are synthetic loopback test data.
import http2 from 'node:http2';
import fs from 'node:fs';
const [directory] = process.argv.slice(2);
let sessions = 0, streams = 0;
const server = http2.createSecureServer({
  key: fs.readFileSync(`${directory}/key.pem`), cert: fs.readFileSync(`${directory}/cert.pem`),
  allowHTTP1: false, settings: { maxConcurrentStreams: 128 },
});
server.on('session', session => { sessions++; session.on('error', () => {}); });
server.on('stream', (stream, headers) => {
  streams++; stream.on('error', () => {});
  let body = '';
  stream.setEncoding('utf8'); stream.on('data', chunk => body += chunk);
  stream.on('end', () => {
    if (stream.destroyed) return;
    if (headers[':path'].endsWith('/stats')) {
      stream.respond({ ':status': 200, 'content-type': 'application/json' }); stream.end(JSON.stringify({ sessions, streams })); return;
    }
    const reply = JSON.stringify({ key: headers.authorization, body });
    stream.respond({ ':status': 200, 'content-type': 'text/event-stream' });
    stream.write(`data: ${reply}\n\n`);
    const timer = setTimeout(() => { if (!stream.destroyed) stream.end('data: [DONE]\n\n'); }, headers[':path'].includes('cancel') ? 4000 : 120);
    stream.on('close', () => clearTimeout(timer));
  });
});
server.on('tlsClientError', () => {});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(`${directory}/ready.json`, JSON.stringify({ port: server.address().port })));
process.on('SIGTERM', () => { server.close(); process.exit(0); });
