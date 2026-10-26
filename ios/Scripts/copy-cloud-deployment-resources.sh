#!/bin/sh
set -eu
# Read the production sources on every build. Never maintain a second source copy.
task_root="$SRCROOT/.."
task_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/CloudDeployment"
for task_file in \
  supabase/migrations/202610110001_tincall_connector.sql \
  supabase/migrations/202610110002_tincall_cron.sql \
  supabase/migrations/202610140001_tincall_mcp_roles.sql \
  supabase/migrations/202610160001_tincall_voice_instructions.sql \
  supabase/migrations/202610180001_tincall_recent_calls.sql \
  supabase/migrations/202610190001_tincall_mcp_sse.sql \
  supabase/migrations/202610190002_tincall_mcp_tools.sql \
  supabase/migrations/202610200001_tincall_schedule_controls.sql \
  supabase/migrations/202610200002_tincall_incoming_events.sql \
  supabase/migrations/202610200003_tincall_mcp_oauth.sql \
  supabase/migrations/202610200004_tincall_call_presence.sql \
  supabase/migrations/202610200005_tincall_contact_mode.sql \
  supabase/migrations/202610200006_tincall_wake_bridge.sql \
  supabase/migrations/202610210001_tincall_mcp_voice_ack.sql \
  supabase/migrations/202610210002_tincall_mcp_conversation.sql \
  supabase/migrations/202610210003_tincall_message_images.sql \
  supabase/migrations/202610220001_tincall_service_safety.sql \
  supabase/migrations/202610220002_tincall_mcp_safety.sql \
  supabase/migrations/202610250001_tincall_mcp_wait_preferences.sql \
  supabase/functions/tincall/index.ts \
  supabase/functions/_shared/tincall/service.mjs \
  supabase/functions/_shared/tincall/server-version.json \
  supabase/functions/_shared/tincall/protocol.mjs \
  supabase/functions/_shared/tincall/supabase-store.mjs \
  supabase/functions/_shared/tincall/message-images.mjs \
  supabase/functions/_shared/tincall/call-commands.mjs \
  supabase/functions/_shared/tincall/call-jobs.mjs \
  supabase/functions/_shared/tincall/mcp.mjs \
  supabase/functions/_shared/tincall/oauth.mjs
do
  mkdir -p "$task_destination/$(dirname "$task_file")"
  cp "$task_root/$task_file" "$task_destination/$task_file"
done
