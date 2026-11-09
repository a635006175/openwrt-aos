// SPDX-License-Identifier: Apache-2.0
import { ensure,refreshGuard,rollbackPolicy,initializeDatabase,startGeo } from 'console.security';
ensure();
if (ARGV[0]=='expire') rollbackPolicy(true);
else if (ARGV[0]=='init') { initializeDatabase(); rollbackPolicy(false); refreshGuard(); }
else if (ARGV[0]=='geo') startGeo();
