-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- call.record and MCP snapshots read one call in message sequence order.
create index if not exists tincall_message_call on public.tincall_messages(call_id,sequence);
-- MCP reply ownership checks and completion update jobs by reply_id alone.
create index if not exists tincall_job_reply on public.tincall_jobs(reply_id);
-- workerOwners expires running leases; the pending-job index excludes these rows.
create index if not exists tincall_running_job_timeout on public.tincall_jobs(claimed_at) where status='running';
create index if not exists tincall_running_push_timeout on public.tincall_push_jobs(claimed_at) where status='running';
-- record.delete retires this owner's record.put receipts without changing retention.
create index if not exists tincall_request_action on public.tincall_requests(owner_id,action);
