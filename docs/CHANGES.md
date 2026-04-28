# Changes

A chronological log of what was built and why. Newest entries first.

## 2026-04-27 — Hadoop+HBase image

- Added `docker/hadoop-hbase/Dockerfile` (Temurin 11 JDK base, Hadoop 3.3.6,
  HBase 2.5.8, OTel agent 2.10.0).
- Role-based `entrypoint.sh` supports `namenode`, `datanode`, `hmaster`,
  `regionserver`, `shell`. Auto-formats the NameNode on first start; HBase
  Master and RegionServer wait for their dependencies to come up.
- Site XMLs in `docker/hadoop-hbase/conf/`:
  - `core-site.xml`: `fs.defaultFS=hdfs://namenode:8020`.
  - `hdfs-site.xml`: replication=1, use-hostname mode, permission checks off.
  - `h