#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.js';
import { runMcpServer } from './mcp.js';
import { Runner } from './runner.js';
import { profilePresets, validateProfile } from './profiles.js';
import { startWebServer } from './web.js';
import { redact } from './util.js';

function usage() {
  return `image-studio ${loadConfig().version}

Usage:
  image-studio web [--port N] [--bind ADDR]   Start the web builder
  image-studio mcp                            Start the MCP stdio server
  image-studio doctor                         Show runtime capabilities
  image-studio profiles                       Print built-in presets
  image-studio validate <nixos|windows> FILE  Validate a profile JSON file

Environment:
  IMAGE_STUDIO_HOST          SSH target for libvirt/qemu-nbd/NixOS (empty = local)
  IMAGE_STUDIO_WIN_HOST      Windows guest SSH target
  IMAGE_STUDIO_DOMAIN        libvirt domain (default win11-stock)
  IMAGE_STUDIO_DISK          raw disk path
  IMAGE_STUDIO_NIXOS_REPO    host repo path (default /etc/nixos)
  IMAGE_STUDIO_DATA          controller data directory
  IMAGE_STUDIO_PORT          web port (default 8788)
  IMAGE_STUDIO_TOKEN         optional bearer token
  IMAGE_STUDIO_DRY_RUN=1     simulate host/guest commands
`;
}

function argValue(args, name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

export async function main(argv = process.argv.slice(2)) {
  const [command = 'help', ...rest] = argv;
  if (command === 'help' || command === '--help' || command === '-h') {
    process.stdout.write(usage());
    return 0;
  }
  if (command === '--version' || command === 'version') {
    process.stdout.write(`${loadConfig().version}\n`);
    return 0;
  }
  if (command === 'web') {
    const env = { ...process.env };
    if (argValue(rest, '--port')) env.IMAGE_STUDIO_PORT = argValue(rest, '--port');
    if (argValue(rest, '--bind')) env.IMAGE_STUDIO_BIND = argValue(rest, '--bind');
    const started = await startWebServer({ config: loadConfig(env) });
    process.stdout.write(`${started.url}\n`);
    return null; // keep the server handle alive
  }
  if (command === 'mcp') {
    await runMcpServer();
    return 0;
  }
  if (command === 'doctor') {
    const config = loadConfig();
    const capabilities = await new Runner(config).capabilities();
    process.stdout.write(`${JSON.stringify(redact({ config, capabilities }), null, 2)}\n`);
    return 0;
  }
  if (command === 'profiles') {
    process.stdout.write(`${JSON.stringify(profilePresets(), null, 2)}\n`);
    return 0;
  }
  if (command === 'validate') {
    const [kind, file] = rest;
    if (!kind || !file) throw new Error('usage: image-studio validate <nixos|windows> FILE');
    const profile = JSON.parse(await fs.readFile(file, 'utf8'));
    process.stdout.write(`${JSON.stringify(validateProfile(kind, profile), null, 2)}\n`);
    return 0;
  }
  throw new Error(`unknown command: ${command}\n\n${usage()}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main().then((code) => { if (code !== null) process.exit(code); }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  });
}