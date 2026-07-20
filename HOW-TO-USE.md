# Azure DocumentDB Migration Platform — How to Use

This guide walks through using the Migration Engine web UI to create and run a
migration, tune its configuration while it runs, and complete the cutover.

Before starting, deploy the platform using the steps in [README.md](README.md)
and open the web UI at the address exposed by the `migration-engine-web`
service (the Load Balancer IP/DNS printed at the end of the deploy script).

## Overview

A migration runs in two main stages:

1. **Bulk copy** — the source data is partitioned and copied into the target in
   parallel.
2. **Change Data Capture (CDC)** — for a **Live** migration, the engine tails the
   source change stream and replays new writes into the target until you cut
   over.

The typical flow is:

```
[New Migration] --> [Configure & Submit] --> [Bulk copy] --> [CDC / change stream] --> [Ready for cutover] --> [Cutover triggered] --> [Completed]
```

## 1. Create a migration

1. On the **Dashboard**, click **New Migration** (top right).
2. The **Start new migration** form opens with a pre-generated **Migration ID**.

The Dashboard shows summary tiles (Total / Completed / Paused migrations) and a
searchable list of recent migrations. Use **Refresh** or **Auto-refresh** to keep
it current.

## 2. Provide migration details and configuration

Fill in the **Migration setup** form:

| Field | Description |
| ----- | ----------- |
| **Migration ID** | Auto-generated identifier (read-only). |
| **Migration name** | Friendly name shown throughout the UI. |
| **Migration type** | **Live** (bulk copy + ongoing CDC) or **Snapshot** (one-time bulk copy only). |
| **Partition size (MB)** | Size of each data partition for the bulk copy. |
| **Parallel copy threads** | Number of threads used for the bulk copy phase. |
| **Number of batches** | Batches used to divide the change stream work. |
| **CPU cores** | CPU allocated to the migration pod. |
| **Memory** | Memory allocated to the migration pod (e.g. `10Gi`). |
| **Source connection string** | Connection string of the source database. |
| **Target connection string** | Connection string of the target (Azure DocumentDB / Cosmos DB). |
| **Collections JSON** | The collections to migrate. |

### Collections JSON

Provide the collections to migrate either by uploading a JSON file (recommended)
or by pasting JSON directly. Format:

```json
[{ "databaseName": "database_name", "collectionName": "collection_name" }]
```

Naming conventions:

- Use `"*"` to match **all** collections.
- Use `"coll*"` for names **starting with** `coll`.
- Use `"*coll"` for names **ending with** `coll`.

Optional per-collection defaults: `overwriteIfExists=false`,
`migrateIndexes=true`, `copyShardKey=false`.

When the JSON is valid, the form confirms.

Click **Submit** to start the migration.

## 3. Migration phases (bulk copy → CDC)

Open the migration to see **Migration details**. The **Run summary** shows the
current type, completed phase, pod status, and live throughput tiles: bulk
documents copied, data copy time, insertion rate, CDC events, and CDC event
rate.

The engine progresses through phases automatically:

1. **DataPartitioning** — the source data set is split into partitions.
2. **Bulk copy** — documents are copied in parallel; the **Insertion rate** tile
   shows docs/sec and **Bulk documents** shows progress (e.g. `1,470,768 /
   4,221,011`).
3. **Schema phases** (`SchemaNonUniqueIndexes`, etc.) — indexes and schema are
   applied.
4. **CDC / change stream** — for a **Live** migration, the engine watches the
   source change stream and replays events; the **CDC events** and **CDC event
   rate** tiles become active.

The **Collections** table shows per-collection data-copy progress, CDC events,
and last CDC run. Use **Details** for a single collection. The **Logs** panel
streams pod logs with level and line-count filters and a **Download Logs**
option.

## 4. Update configuration during a migration

From **Migration details**, click **Config** to open **Update migration config**.
You can adjust runtime resources and settings:

- Partition size (MB)
- Parallel copy threads
- Parallel partitioning threads
- Number of batches
- CPU cores
- Memory
- Log level
- Source / Target connection strings

Some changes apply **live**, while others require the migration pod to
**restart** to take effect:

| Change | Effect |
| ------ | ------ |
| Log level, parallel partitioning threads, and similar runtime knobs | Applied **immediately** (live update). |
| **Source / Target connection string** | Requires a **pod restart**. |
| **Parallel copy (bulk) threads** — while bulk copy is already running | Requires a **pod restart**. |
| **Number of batches** | Batches for change stream. If change stream has already started changing this fields will have corrupt the job |

Click **Submit** to apply the changes.

## 5. Updating change stream batches

The **Number of batches** for the change stream can only be changed **before**
the migration reaches the change stream (CDC) phase. Once the engine has moved
into the CDC phase, the batch count is fixed for that run and should no longer be
updated.

## 6. Cutover and completion

During the CDC phase, when **no records migrate for 2 cycles** (the change
stream has caught up), the migration becomes **Ready for Cutover** — a **Cut
Over** button appears in **Migration details**.

1. Click **Cut Over**. The status changes to **Cutover Triggered**.
2. The engine drains any remaining incoming events and then completes the
   cutover automatically based on the incoming event flow.

When complete, the **Run summary** shows **Completed**, the pod reports
**Succeeded**, and the logs confirm all phases finished (e.g. `Migration ...
completed all phases` / `Updated migration ... status to Completed`). At this
point the **Config** / **Stop** actions are replaced by a **Delete** option.

### Other actions on the details page

| Action | Purpose |
| ------ | ------- |
| **Refresh** / **Auto-refresh** | Update the view manually or continuously. |
| **Config** | Open the update-config form (section 4). |
| **Stop** | Stop the running migration pod. |
| **Reset CDC Checkpoints** | Restart change-stream tracking from the current point. This is helpful when change stream batches are updated. |
| **Cut Over** | Trigger cutover once ready (section 6). |
| **Delete** | Remove a completed migration. |
