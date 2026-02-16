#!/usr/bin/env node
// Load environment variables before other imports execute
import './load-env.js';
import ngrok from '@ngrok/ngrok';

const PORT = process.env.PORT || 3001;
const authtoken = process.env.NGROK_AUTHTOKEN;
const domain = process.env.NGROK_DOMAIN;

if (!authtoken || authtoken === 'your_authtoken_here') {
  console.error('Error: NGROK_AUTHTOKEN is not set.');
  console.error('Set it in your .env file or as an environment variable.');
  console.error('Get a free authtoken at https://dashboard.ngrok.com/signup');
  process.exit(1);
}

let listener;

async function start() {
  listener = await ngrok.forward({
    addr: parseInt(PORT, 10),
    authtoken,
    ...(domain && { domain })
  });

  console.log(`ngrok tunnel established: ${listener.url()} -> localhost:${PORT}`);

  // Keep the process alive while the tunnel is open
  setInterval(() => {}, 1 << 30);
}

async function shutdown() {
  if (listener) {
    console.log('\nClosing ngrok tunnel...');
    await listener.close();
  }
  process.exit(0);
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

start().catch(err => {
  console.error('Failed to start ngrok tunnel:', err.message);
  process.exit(1);
});
