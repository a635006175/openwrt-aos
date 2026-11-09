#!/usr/bin/ucode
// SPDX-License-Identifier: Apache-2.0
import { run,worker } from 'console.mihomo-delay';
if(ARGV[0]=='run')run(ARGV[1]);
else if(ARGV[0]=='worker')worker(ARGV[1],ARGV[2]);
else die('Invalid background delay operation\n');
