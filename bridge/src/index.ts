import { APNSProvider } from "./apns.ts";
import { AuthStore } from "./auth.ts";
import { loadConfig } from "./config.ts";
import { createBridgeServer } from "./server.ts";
import { AgentNotificationService } from "./notifications.ts";
import { BridgeStateEngine } from "./state-engine.ts";

const config = loadConfig();
const instance = { id: config.instanceID, name: config.instanceName, host: config.publicHost };
const state = new BridgeStateEngine(config, instance);
const auth = new AuthStore(config, instance);
const notifications = new AgentNotificationService(
  state,
  auth,
  config.apns ? new APNSProvider(config.apns) : null,
);
notifications.start();
await state.start();

const bridge = createBridgeServer(config, state, auth);

console.info(`[bridge] listening on http://${config.bindHost}:${bridge.server.port}`);
console.info(`[bridge] Tailscale Serve target: http://127.0.0.1:${bridge.server.port}`);
if (config.developmentMode) {
  console.warn("[bridge] DEVELOPMENT MODE: use Bearer development; never expose this mode beyond loopback");
}

let stopping = false;
const stop = () => {
  if (stopping) return;
  stopping = true;
  console.info("[bridge] stopping");
  notifications.stop();
  state.stop();
  bridge.stop();
  process.exit(0);
};

process.on("SIGINT", stop);
process.on("SIGTERM", stop);
