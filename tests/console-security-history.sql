-- SPDX-License-Identifier: Apache-2.0
-- Synthetic fixtures in /tmp ONLY; never use the live traffic database.
PRAGMA journal_mode=OFF;
CREATE TABLE samples(step INTEGER,ts INTEGER,device TEXT,up INTEGER,down INTEGER,tcpup INTEGER,tcpdown INTEGER,udpup INTEGER,udpdown INTEGER,otherup INTEGER,otherdown INTEGER,PRIMARY KEY(step,ts,device)) WITHOUT ROWID;
CREATE INDEX samples_device ON samples(device,step,ts);
BEGIN;
WITH RECURSIVE minutes(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM minutes WHERE n<1439), devices(id) AS (SELECT 0 UNION ALL SELECT id+1 FROM devices WHERE id<99)
INSERT INTO samples SELECT 60,(CAST(strftime('%s','now') AS INTEGER)/60)*60-n*60,printf('02:00:00:00:00:%02x',id),600,1200,500,1000,100,200,0,0 FROM minutes CROSS JOIN devices;
WITH RECURSIVE buckets(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM buckets WHERE n<1728), devices(id) AS (SELECT 0 UNION ALL SELECT id+1 FROM devices WHERE id<99)
INSERT INTO samples SELECT 300,(CAST(strftime('%s','now') AS INTEGER)/300)*300-86400-n*300,printf('02:00:00:00:00:%02x',id),3000,6000,2500,5000,500,1000,0,0 FROM buckets CROSS JOIN devices;
COMMIT;
