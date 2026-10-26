// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';
import version from '../../supabase/functions/_shared/tincall/server-version.json' with {type:'json'};

test('capabilities advertise the deployment revision on manual and Supabase routes', async () => {
  const connector = createConnector({
    store: {
      async authenticate(token) { return token === 'phone-token' ? {owner_id:'synthetic-owner'} : null; },
      async mcpRoleCommand() { return {bindings:[]}; },
    },
    config: {bindings:[]},
  });
  assert.ok(Number.isSafeInteger(version.server_version) && version.server_version > 0);
  for (const prefix of ['', '/tincall', '/functions/v1/tincall']) {
    const response = await connector.handle(new Request(`https://example.invalid${prefix}/capabilities`, {
      headers: {Authorization:'Bearer phone-token'},
    }));
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    const capabilities = await response.json();
    assert.equal(capabilities.version, 1, 'the protocol version stays independent');
    assert.equal(capabilities.server_version, version.server_version);
    const unauthorized = await connector.handle(new Request(`https://example.invalid${prefix}/capabilities`));
    assert.equal(unauthorized.status, 401);
  }
});
