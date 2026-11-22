#!/usr/bin/env node
import { main } from '../src/cli.js';

main().then((code) => { if (code !== null) process.exit(code); }).catch((error) => {
  process.stderr.write(`image-studio: ${error.message}\n`);
  process.exit(1);
});